#!/usr/bin/env bash
#
# Family Archive 복원 스크립트
#   백업이 실제로 살아있는지 확인하는 용도로도 사용 (월 1회 권장)
#
# 사용법:
#   ./restore.sh list                    원격 덤프 목록 보기
#   ./restore.sh db <파일명>              DB 복원 (주의: 기존 데이터 덮어씀)
#   ./restore.sh media <대상경로>         원본 미디어 복원
#   ./restore.sh verify                  복원 테스트 (임시 DB에 덤프 적용만)
#
set -euo pipefail

REMOTE="${REMOTE:-gdrive-crypt}"
REMOTE_BASE="${REMOTE_BASE:-family-archive}"
WORK_DIR="${WORK_DIR:-/tmp/archive-restore}"
PG_CONTAINER="${PG_CONTAINER:-family-archive-db}"
PG_USER="${PG_USER:-archive}"
PG_DB="${PG_DB:-family_archive}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "❌ $*" >&2; exit 1; }

mkdir -p "$WORK_DIR"

list_dumps() {
  log "원격 DB 덤프 목록:"
  rclone lsl "${REMOTE}:${REMOTE_BASE}/db/" | sort -k4 | tail -20
}

restore_db() {
  local name="${1:?덤프 파일명을 지정하세요 (list로 확인)}"
  log "⚠️  기존 데이터베이스를 덮어씁니다. 5초 내 Ctrl+C로 취소 가능."
  sleep 5
  rclone copy "${REMOTE}:${REMOTE_BASE}/db/${name}" "$WORK_DIR/" || die "다운로드 실패"
  gunzip -c "$WORK_DIR/$name" | docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" \
    || die "복원 실패"
  log "✅ DB 복원 완료"
}

restore_media() {
  local dest="${1:?복원할 경로를 지정하세요}"
  mkdir -p "$dest"
  rclone copy "${REMOTE}:${REMOTE_BASE}/raw_archives/" "$dest" --progress || die "복원 실패"
  log "✅ 미디어 복원 완료: $dest"
}

# 실제 운영 DB를 건드리지 않고 백업 유효성만 검증
verify() {
  local latest tmpdb="verify_$(date +%s)"
  latest=$(rclone lsf "${REMOTE}:${REMOTE_BASE}/db/" | sort | tail -1)
  [ -n "$latest" ] || die "원격에 덤프가 없습니다"
  log "최신 덤프: $latest"

  rclone copy "${REMOTE}:${REMOTE_BASE}/db/${latest}" "$WORK_DIR/" || die "다운로드 실패"
  gunzip -t "$WORK_DIR/$latest" || die "압축 파일이 손상되었습니다"
  log "  압축 무결성 OK"

  docker exec "$PG_CONTAINER" createdb -U "$PG_USER" "$tmpdb" || die "임시 DB 생성 실패"
  if gunzip -c "$WORK_DIR/$latest" | docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$tmpdb" -q; then
    local n
    n=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$tmpdb" -tAc \
        "SELECT count(*) FROM archive_items" 2>/dev/null || echo "?")
    log "  복원 성공. archive_items 행 수: $n"
    docker exec "$PG_CONTAINER" dropdb -U "$PG_USER" "$tmpdb"
    log "✅ 백업 검증 통과"
  else
    docker exec "$PG_CONTAINER" dropdb -U "$PG_USER" "$tmpdb" || true
    die "덤프 적용 실패 — 백업이 손상되었을 수 있습니다"
  fi
  rm -f "$WORK_DIR/$latest"
}

case "${1:-}" in
  list)   list_dumps ;;
  db)     restore_db "${2:-}" ;;
  media)  restore_media "${2:-}" ;;
  verify) verify ;;
  *)      echo "사용법: $0 {list|db <파일명>|media <경로>|verify}"; exit 1 ;;
esac
