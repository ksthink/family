# 🏠 Family Archive — 라즈베리파이 5 기반 AI-Ready 가족 아카이브 시스템

라즈베리파이 5를 저전력 24시간 **수집·정제 서버**로 활용하고, 수집된 데이터를 클라우드 GPU에서 AI 페르소나(LLM, Voice Cloning, Avatar)로 즉시 학습시킬 수 있도록 설계된 시스템입니다.

> **핵심 원칙**
> 1. 라즈베리파이는 "수집과 전처리"만 담당한다. 학습은 클라우드 GPU가 담당한다.
> 2. PostgreSQL이 유일한 원본(Source of Truth)이다. CSV/JSONL은 Export 시점에 생성한다.
> 3. 무압축 원본을 마스터로 보존한다. 모델별 포맷은 Export 시 프리셋으로 변환한다.
> 4. 데이터는 대체 불가능하다. 백업은 기능이 아니라 전제 조건이다.

---

## 1. 시스템 아키텍처

```
[사용자 (가족)]
       │ (스마트폰/PC 웹 접속)
       ▼
[Caddy / Tailscale (보안 라우팅)]
       │
       ▼
[Next.js 프론트엔드] ───► [FastAPI 백엔드]
                              │
               ┌──────────────┼────────────────────┐
               ▼              ▼                    ▼
       [PostgreSQL+pgvector] [Storage (NVMe)]  [전처리 엔진]
        (메타데이터/임베딩)   (원본/정제 미디어)   ├─ Groq STT API (기본)
                                               ├─ whisper.cpp (폴백)
                                               └─ ffmpeg / Silero VAD
```

### 하드웨어 / 소프트웨어 구성

| 구분 | 요소 | 구성 상세 | 비고 |
| --- | --- | --- | --- |
| 하드웨어 | 보드 | Raspberry Pi 5 (4GB, 신규 구매 시 8GB 권장) | 메인 서버 |
| | 저장장치 | M.2 NVMe SSD (1TB+) + PCIe HAT | MicroSD 사용 불가 |
| | 백업장치 | Google Drive (rclone+crypt) / 추후 외장 HDD 추가 | **필수** |
| | 냉각 | 정품 액티브 쿨러 | 24/7 운용 |
| | 전원 | 소형 UPS (권장) | 정전 시 DB 손상 방지 |
| 소프트웨어 | OS | Ubuntu Server 24.04 LTS (64-bit, 헤드리스) | snapd 제거로 RAM 확보 |
| | 인프라 | Docker & Docker Compose | 앱 격리 및 백업 편의 |
| | 네트워크 | Tailscale 또는 Cloudflare Tunnel | 공인 IP 불필요 |

### 4GB RAM 운용 지침

- `sudo apt purge snapd` 로 snapd 제거 (수백 MB RAM 확보)
- Celery/Redis 미사용 → FastAPI BackgroundTasks + 단순 작업 잠금(lock)
- PostgreSQL `shared_buffers` 256MB 제한
- Next.js standalone 빌드
- 로컬 STT(폴백) 실행 중에는 다른 무거운 작업 차단

---

## 2. 저장 구조 (NVMe SSD)

```
/mnt/nvme/data/
├── raw_archives/                  # 무압축 원본 = 유일한 마스터
│   ├── audio/                     #   (44.1/48kHz 원본 그대로)
│   ├── images/
│   └── text/
├── ai_processed/                  # Export 결과물 캐시 (DB에서 생성)
│   ├── voice_dataset/
│   │   ├── preset_gptsovits/      # 32kHz — GPT-SoVITS용
│   │   ├── preset_xtts/           # 24kHz — XTTS용
│   │   └── metadata.csv           # [파일명|대본|화자ID|감정태그]
│   ├── llm_dataset/
│   │   ├── train_{speaker}.jsonl  # 파인튜닝용 대화 데이터
│   │   └── memory_rag.json        # RAG용 벡터 원본
│   └── lora_dataset/              # 이미지 + .txt 캡션 쌍
└── trained_models/                # 학습 완료된 모델 가중치 (백업 1순위)
    └── {speaker_id}/
        └── v{YYYY}Q{n}_{model}/
            ├── model_weights/
            ├── training_manifest.json
            └── samples/
```

- PostgreSQL 데이터는 Docker 볼륨으로 관리하고 `pg_dump`로 백업한다 (단일 파일 아님).
- `ai_processed/`는 언제든 DB + 원본에서 재생성 가능한 캐시로 취급한다.

---

## 3. 데이터베이스 설계 (PostgreSQL + pgvector)

```sql
-- 1. 화자 (가족 구성원)
CREATE TABLE speakers (
    speaker_id  VARCHAR(30) PRIMARY KEY,   -- ex: 'father_01'
    name        VARCHAR(50) NOT NULL,
    relation    VARCHAR(30),               -- ex: '아빠', '엄마', '할머니'
    traits      JSONB,                     -- 말투 특성, 자주 쓰는 단어, 성격 요약
    consent_at  TIMESTAMP                  -- AI 학습 동의 시각 (필수)
);

-- 2. 통합 아카이브
CREATE TABLE archive_items (
    id             BIGSERIAL PRIMARY KEY,
    speaker_id     VARCHAR(30) REFERENCES speakers(speaker_id),
    media_type     VARCHAR(10) NOT NULL,   -- 'audio' | 'text' | 'image' | 'video'
    file_path      TEXT NOT NULL,
    raw_content    TEXT,                   -- 원문 또는 STT 대본

    -- AI 데이터 생성용 태그
    emotion        VARCHAR(20),            -- 'joy' | 'sadness' | 'calm' | 'serious'
    target_person  VARCHAR(30),            -- 대화 상대 (ex: '딸에게')
    speech_style   VARCHAR(30),            -- 'casual' | 'formal' | 'dialect'

    -- STT 처리 이력
    stt_engine     VARCHAR(40),            -- 'groq-whisper-large-v3' | 'whispercpp-small'
    stt_confidence REAL,                   -- 저품질 대본 선별 재처리용
    local_only     BOOLEAN DEFAULT FALSE,  -- TRUE: 외부 API 전송 금지 (민감 데이터)

    -- RAG용 벡터 (임베딩 모델 확정 후 차원 결정: OpenAI 1536 / BGE-M3 1024)
    embedding      vector(1536),

    recorded_at    TIMESTAMP,              -- 실제 기록된 과거 날짜 (EXIF 또는 지정)
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

---

## 4. 자동 전처리 파이프라인

### ① 음성 (Voice Pipeline)

```
[업로드] → [ffmpeg 변환] → [Silero VAD 발화 검출] → [STT 라우팅] → [클립 분할] → [DB 기록]
                │                                       │
                ├─ 원본 보존 (raw_archives)              ├─ 기본: Groq API (whisper-large-v3)
                └─ STT 전송용 16kHz mono 임시 파일       │        language="ko", verbose_json
                                                        └─ 폴백: 로컬 whisper.cpp (Small)
                                                                 · API 장애/한도 소진 시
                                                                 · local_only 플래그 지정 시
```

1. **포맷 변환:** 원본은 무압축 보존, STT 전송용으로 16kHz/16bit/Mono WAV 임시 생성 (Whisper 네이티브 스펙 — 정확도·전송속도 개선).
2. **VAD:** Silero VAD로 발화 경계 검출. `speech_pad_ms` 300~400ms로 첫 음절 잘림 방지.
3. **STT:** Groq API 우선 (무료 티어: 일 2,000건 / 28,800초 — 조건 변동 가능, 분기별 재확인). 429 시 지수 백오프, 연속 실패 시 로컬 폴백 → 야간 배치 처리.
4. **클립 분할:** Whisper 타임스탬프 × VAD 경계 교차 검증으로 2~10초 분할. 파일명 `{speaker_id}_{0001}.wav`.
5. **DB 기록:** 대본·엔진·신뢰도를 DB에만 기록. CSV는 Export 시 생성.

### ② 텍스트 (LLM Pipeline)

1. 웹 UI에서 [질문-답변] 또는 [일기/자유글] 작성.
2. DB에 원문 저장. Export 시 표준 파인튜닝 JSONL로 변환:

```json
{"messages": [{"role": "user", "content": "아빠가 가장 보람찼던 순간은 언제야?"}, {"role": "assistant", "content": "너희들이 건강하게 자라줘서 각자 꿈을 찾아갈 때였지."}]}
```

### ③ 이미지 (LoRA Pipeline)

1. 업로드 시 EXIF에서 날짜 추출 → `recorded_at`.
2. **캡셔닝은 라즈베리파이에서 하지 않는다.** 다음 중 택일:
   - (a) 업로드 시 웹 UI에서 가족이 간단 수동 태깅
   - (b) Export 직전 클라우드 GPU/비전 API에서 일괄 자동 캡셔닝
3. Export 시 이미지 + 동명 `.txt` 캡션 쌍으로 출력.

---

## 5. 백업 전략 (Phase 1 필수 요소)

| 계층 | 방법 | 주기 |
| --- | --- | --- |
| 오프사이트 (기본) | rclone **crypt** → Google Drive (Google One 용량 요금제 확인) | 매일 야간 |
| 로컬 (확장) | 데이터 수십 GB 초과 시 외장 HDD(rsync/borg) 추가 | 매일 야간 |
| DB | `pg_dump` 덤프를 위 백업에 포함 | 매일 야간 |

### Google Drive 백업 운용 규칙

- **암호화 필수:** rclone `crypt` 리모트로 파일명 포함 클라이언트 측 암호화. 암호화 비밀번호는 서버 외부(종이/패스워드 매니저)에 별도 보관 — 분실 시 백업 전체 복원 불가.
- **아카이브 후 업로드:** 작은 파일 수천 개를 개별 업로드하지 않는다. 야간 배치에서 `raw_archives/` 증분 + `pg_dump`를 날짜별 `tar.zst`로 묶어 큰 파일 단위로 업로드 (API 레이트 리밋 회피).
- **헤드리스 인증:** PC에서 `rclone config`로 OAuth 토큰 발급 후 라즈베리파이의 `~/.config/rclone/rclone.conf`로 복사.
- 백업 대상: `raw_archives/`, `trained_models/`, DB 덤프. (`ai_processed/`는 재생성 가능하므로 제외)
- 월 1회 복원 테스트로 백업 유효성 검증. 계정 잠금 리스크에 대비해 데이터가 커지면 로컬 HDD 계층을 추가한다.

---

## 6. 구축 로드맵

```
[Phase 1: 인프라+백업] → [Phase 2: DB & 파이프라인] → [Phase 3: 웹 UI] → [Phase 4: Export] → [Phase 5: 클로닝 학습]
```

### Phase 1 — 하드웨어 및 OS 인프라
1. PCIe HAT + NVMe SSD 장착. Ubuntu Server 24.04 LTS (64-bit) 설치
2. Pi 5 부트로더(EEPROM) 최신화 및 NVMe 부팅 순서 설정
3. NVMe Gen3 활성화: `/boot/firmware/config.txt`에 `dtparam=pciex1_gen=3` 추가
4. `sudo apt purge snapd` 등 불필요 서비스 제거 (RAM 확보)
5. Docker & Docker Compose 설치
6. Tailscale로 가족 전용 가상 폐쇄망 구축
7. **백업 체계 구축 (rclone crypt → Google Drive, 야간 cron) — 이 단계에서 완료**

### Phase 2 — DB 및 전처리 모듈
1. Docker Compose로 PostgreSQL(+pgvector) 실행
2. ffmpeg / Silero VAD 세팅, whisper.cpp 빌드 (폴백용)
3. FastAPI 백엔드: 업로드 API, Groq STT 연동(+백오프/폴백 라우팅), 클립 분할 모듈
4. Groq API 키는 `.env` + Docker secret으로 관리

### Phase 3 — 웹 UI (Next.js)
- **데일리 인터뷰:** 매일/매주 질문 → 음성 녹음 또는 텍스트 답변
  - 녹음 가이드 배너: "조용한 곳에서 / 마이크 30cm 이내 / 평소 말하듯"
  - 업로드 시 SNR 간이 측정 → 미달 시 재녹음 안내
- **페르소나 태깅 입력폼:** 어조·감정·대화 상대 터치 태그 + `민감(로컬 전용)` 토글
- **감정 다양성 대시보드:** 감정별 수집 분포 표시, 부족한 감정 유도 질문 자동 배치
- **인생 타임라인:** 연도별 사진·음성 데이터 밀도 시각화
- **동의 기록:** 화자 최초 등록 시 AI 학습 동의 항목 (DB 저장)

### Phase 4 — Export
- 어드민 [AI 데이터셋 내보내기]: 화자 선택 → 용도별 출력
  - Voice: 모델 프리셋(32kHz/24kHz) 선택 → WAV + metadata.csv ZIP
  - LLM: `train_{speaker}.jsonl`
  - LoRA: 이미지 + `.txt` 캡션 쌍
- `stt_confidence` 임계값 미만 클립은 제외 또는 경고 표시

### Phase 5 — 음성 클로닝 학습 및 운용
1. **2단계 전략:** 제로샷(5초 샘플)으로 품질 사전 검증 → 데이터 30분+ 축적 시 파인튜닝
2. **모델:** GPT-SoVITS 1순위 (한국어 공식 지원, 1분 데이터부터 가능, MIT). 예비: Fish Speech(Apache 2.0), XTTS-v2(비상업), CosyVoice 2. 착수 전 최신 동향 재확인.
3. **학습:** RunPod RTX 4090 (~$0.4~0.7/hr) + GPT-SoVITS WebUI → SoVITS 모듈 → GPT 모듈 순차 학습 → 테스트 문장 검수 → 가중치 회수 → 인스턴스 즉시 종료 (1회 ~$1 내외)
4. **보관:** `trained_models/`에 버전 누적 (삭제 금지) + `training_manifest.json`으로 재현성 확보
5. **추론 운용:** (A) 자주 쓸 문장 사전 생성 → (B) 필요 시 온디맨드 GPU → (C) 추후 가정 내 GPU 추론 서버 (LLM 페르소나 실시간 연동 단계)

---

## 7. 윤리 및 동의

- 클로닝 대상 본인의 **명시적 동의를 사전에 기록**한다 (`speakers.consent_at`).
- 고인 대비 아카이브 성격이라면 **생전에 본인 의사를 확인**해 가족 간 갈등을 예방한다.
- 학습 모델과 생성 음성은 가족 내부 용도로 한정. 외부 공유 시 본인(또는 유족 전원) 합의 필요.
- 생성 음성에는 메타데이터로 "AI 생성" 표시를 남겨 실제 녹음과 구분한다.
- 민감한 녹음(유언·재산·건강 등)은 `local_only` 플래그로 외부 API 전송을 차단한다.

---

## 8. 운영 체크리스트

- [ ] 백업 자동화(rclone crypt→Google Drive) + 월 1회 복원 테스트
- [ ] rclone crypt 비밀번호 오프라인 별도 보관
- [ ] Google One 용량 잔여분 분기별 확인 / 수십 GB 초과 시 외장 HDD 계층 추가
- [ ] Groq 데이터 정책 확인 및 가족 공지, 무료 티어 조건 분기별 재확인
- [ ] `stt_confidence` 하위 항목 월간 리포트 → 재전사 여부 결정
- [ ] 임베딩 모델 확정 (OpenAI 1536 vs BGE-M3 1024) 후 vector 차원 반영
- [ ] 데이터 1~5분: 제로샷 테스트 / 30분+: 1차 파인튜닝
- [ ] 학습 후 GPU 인스턴스 종료 확인
- [ ] 분기별 재학습 여부 결정
