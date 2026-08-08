#!/usr/bin/env bash
#
# Family Archive 백업 스크립트
#   - PostgreSQL 덤프 + 원본 미디어를 Google Drive(rclone crypt)로 백업
#   - cron에서 호출. 자세한 설정은 docs/백업_설정.md 참조
#
# 사용법:
#   ./backup.sh db      DB 덤프만 (하루 여러 번)
#   ./backup.sh media   원본 미디어 동기화 (야간 1회)
#   ./backup.sh full    둘 다 + 오래된 덤프 정리
#
set -euo pipefail

# ─────────────────────────────────────────────
# 설정 (환경에 맞게 수정)
# ─────────────────────────────────────────────
DATA_DIR="${DATA_DIR:-/data}"                    # USB 저장장치 마운트 지점
REMOTE="${REMOTE:-gdrive-crypt}"                 # rclone crypt 리모트 이름
REMOTE_BASE="${REMOTE_BASE:-family-archive}"     # 리모트 내 기준 경로
STAGING="${STAGING:-$DATA_DIR/.backup_staging}"  # 덤프 임시 저장
LOG_FILE="${LOG_FILE:-$DATA_DIR/logs/backup.log}"
LOCK_FILE="/tmp/family-archive-backup.lock"

# PostgreSQL (Docker 컨테이너)
PG_CONTAINER="${PG_CONTAINER:-family-archive-db}"
PG_USER="${PG_USER:-archive}"
PG_DB="${PG_DB:-family_archive}"

# 보존 정책
KEEP_DAILY_DUMPS=30      # 로컬 스테이징에 보관할 덤프 개수
RCLONE_OPTS=(--transfers 4 --checkers 8 --retries 3 --low-level-retries 10 --stats-one-line)

# ─────────────────────────────────────────────
# 유틸
# ─────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")" "$STAGING"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die() { log "❌ 오류: $*"; exit 1; }

# 중복 실행 방지
exec 200>"$LOCK_FILE"
flock -n 200 || { log "⏭  이미 실행 중이므로 건너뜀"; exit 0; }

require() { command -v "$1" >/dev/null 2>&1 || die "$1 이(가) 설치되어 있지 않습니다"; }
require rclone
require docker

# 리모트 접근 확인 (토큰 만료 조기 감지)
check_remote() {
  rclone lsd "${REMOTE}:" >/dev/null 2>&1 \
    || die "리모트 '${REMOTE}' 접근 실패. rclone 인증(토큰)을 확인하세요."
}

# ─────────────────────────────────────────────
# 1. DB 덤프
# ─────────────────────────────────────────────
backup_db() {
  local ts dump
  ts="$(date '+%Y%m%d_%H%M')"
  dump="$STAGING/db_${ts}.sql.gz"

  log "▶ DB 덤프 시작"
  docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" --clean --if-exists \
    | gzip -6 > "$dump" \
    || die "pg_dump 실패"

  # 빈 파일 방어
  [ -s "$dump" ] || die "덤프 파일이 비어 있습니다"
  log "  덤프 생성: $(basename "$dump") ($(du -h "$dump" | cut -f1))"

  rclone copy "$dump" "${REMOTE}:${REMOTE_BASE}/db/" "${RCLONE_OPTS[@]}" \
    || die "DB 덤프 업로드 실패"
  log "✅ DB 백업 완료"
}

# ─────────────────────────────────────────────
# 2. 원본 미디어 동기화
#    - raw_archives 만 대상 (derived/, exports/ 는 재생성 가능하므로 제외)
#    - sync가 아닌 copy 사용: 로컬 삭제가 원격에 전파되지 않도록 (실수 방어)
# ─────────────────────────────────────────────
backup_media() {
  local src="$DATA_DIR/raw_archives"
  [ -d "$src" ] || die "원본 디렉토리가 없습니다: $src"

  log "▶ 원본 미디어 백업 시작"
  rclone copy "$src" "${REMOTE}:${REMOTE_BASE}/raw_archives/" \
    "${RCLONE_OPTS[@]}" \
    --exclude ".*" --exclude "*.tmp" --exclude "*.part" \
    --log-file "$LOG_FILE" --log-level INFO \
    || die "미디어 업로드 실패"
  log "✅ 미디어 백업 완료"
}

# ─────────────────────────────────────────────
# 3. 오래된 로컬 덤프 정리 (원격 덤프는 유지)
# ─────────────────────────────────────────────
prune_local() {
  log "▶ 로컬 덤프 정리 (최근 ${KEEP_DAILY_DUMPS}개 유지)"
  local count
  count=$(find "$STAGING" -name 'db_*.sql.gz' | wc -l)
  if [ "$count" -gt "$KEEP_DAILY_DUMPS" ]; then
    find "$STAGING" -name 'db_*.sql.gz' -printf '%T@ %p\n' \
      | sort -n | head -n -"$KEEP_DAILY_DUMPS" | cut -d' ' -f2- \
      | xargs -r rm -f
    log "  $((count - KEEP_DAILY_DUMPS))개 삭제"
  else
    log "  정리 대상 없음"
  fi
}

# ─────────────────────────────────────────────
# 4. 요약 리포트
# ─────────────────────────────────────────────
report() {
  local used
  used=$(rclone size "${REMOTE}:${REMOTE_BASE}" --json 2>/dev/null | grep -o '"bytes":[0-9]*' | cut -d: -f2 || echo 0)
  log "📊 원격 사용량: $(numfmt --to=iec-i --suffix=B "${used:-0}" 2>/dev/null || echo "${used}B")"
}

# ─────────────────────────────────────────────
main() {
  local mode="${1:-full}"
  log "═══ 백업 시작 (모드: $mode) ═══"
  check_remote
  case "$mode" in
    db)    backup_db ;;
    media) backup_media ;;
    full)  backup_db; backup_media; prune_local; report ;;
    *)     die "알 수 없는 모드: $mode (db|media|full)" ;;
  esac
  log "═══ 백업 종료 ═══"
}

main "$@"
