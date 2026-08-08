# 🏠 Family Archive — AI-Ready 가족 아카이브 플랫폼

가족의 기록(텍스트·이미지·동영상·음성)을 수집·보존하는 **아카이브 사이트**이자, 그 자료를 향후 구성원별 **페르소나 AI** 학습에 그대로 쓸 수 있는 형태로 구조화하는 데이터 플랫폼입니다.

> **이 프로젝트의 범위**
> 본 시스템은 AI 페르소나 제작의 **전 단계**, 즉 **수집·정제·구조화 계층**을 담당합니다.
> 모델 학습과 실시간 추론은 별도 환경(클라우드 GPU 또는 추후 도입할 추론 서버)에서 수행합니다.
> 따라서 서버는 고사양일 필요가 없으며, 저전력 24시간 운용에 최적화합니다.

> 📐 **설계 문서:** [구성 요소별 설계 명세](docs/설계_명세.md) — 요소별 핵심 원칙·기능·내용
> 🗂 **데이터셋:** [데이터셋 구성 가이드](docs/데이터셋_구성.md) — 생성 과정과 저장 형식 예시
> 🗃 **분류:** [자료 분류체계](docs/자료_분류체계.md) — 문헌형식 20종과 Export 매핑
> 📤 **가족용 사용 안내:** [자료 올리기 안내](docs/업로드_안내.md)
> 🔐 **운영자용:** [Google Drive 백업 설정](docs/백업_설정.md)

---

## 1. 설계 원칙

1. **두 개의 얼굴.** 가족에게는 평범한 아카이브 사이트로 보이고, 내부적으로는 AI 학습용 데이터셋이 함께 쌓인다. 사용자는 데이터셋을 만들고 있다는 것을 의식하지 않는다.
2. **한 번의 입력, 두 가지 쓰임.** 인물·연도·장소 태그는 아카이브 브라우징에도 쓰이고 동시에 학습 메타데이터가 된다. 학습 전용 입력을 따로 요구하지 않는다.
3. **PostgreSQL이 유일한 원본(Source of Truth).** CSV/JSONL 등 학습용 산출물은 Export 시점에 DB에서 생성하는 파생물이다.
4. **무압축 원본 보존.** 모델별 포맷(샘플레이트 등)은 Export 시 프리셋으로 변환한다. 특정 모델 규격을 마스터로 삼지 않는다.
5. **수집 서버와 추론 서버를 분리한다.** 한 대에 합치지 않는다. 대화형 AI가 필요해지는 시점에 별도 머신을 추가한다.
6. **데이터는 대체 불가능하다.** 백업은 기능이 아니라 전제 조건이다.

---

## 2. 시스템 아키텍처

```
[가족 사용자]
     │ 스마트폰 / PC 웹 접속
     ▼
[Tailscale / Cloudflare Tunnel]  ← 공인 IP 불필요, 가족 전용 폐쇄망
     ▼
[Caddy] → [Next.js 프론트엔드] → [FastAPI 백엔드]
                                       │
        ┌──────────────────────────────┼───────────────────────────┐
        ▼                              ▼                           ▼
[PostgreSQL + pgvector]        [Storage (USB SSD/HDD)]      [전처리 엔진]
  메타데이터 · 태그 · 임베딩      원본 미디어 · 파생물          ├─ ffmpeg (변환/오디오 추출)
                                                             ├─ Silero VAD
                                                             ├─ Groq STT API (기본)
                                                             └─ whisper.cpp (폴백)
```

### 하드웨어

| 구분 | 구성 | 비고 |
| --- | --- | --- |
| 서버 | **Raspberry Pi 4 (4GB)** 이상 | 수집·전처리 전용이므로 충분. Pi 5 / 미니PC로 교체 가능 |
| 부팅 | MicroSD **High Endurance 등급** | 여분 카드 1장 필수. 세팅 완료 후 전체 이미지 백업 |
| 데이터 | USB 3.0 외장 SSD/HDD | **DB·미디어는 반드시 SD 밖에 배치** (SD 수명 보호) |
| 냉각 | 방열판 + 팬 | 24/7 운용 |
| 전원 | 소형 UPS (권장) | 정전 시 DB 손상 방지 |

### 소프트웨어

| 구분 | 선택 | 비고 |
| --- | --- | --- |
| OS | Ubuntu Server 24.04 LTS (64-bit, 헤드리스) | `snapd` 제거로 RAM 확보 |
| 인프라 | Docker & Docker Compose | 앱 격리 · 서버 이전 용이 |
| DB | PostgreSQL + pgvector | 메타데이터 + RAG 임베딩 |
| 백엔드 | Python FastAPI | BackgroundTasks 사용 (Celery/Redis 미사용) |
| 프론트 | Next.js (standalone 빌드) | **빌드는 PC에서 수행 후 배포** |
| 네트워크 | Tailscale 또는 Cloudflare Tunnel | |

### 저사양(SD카드) 운용 지침

- PostgreSQL 데이터 디렉토리와 미디어 저장소를 USB 저장장치로 이전
- `/var/log` → tmpfs (log2ram), 스왑 비활성화, `noatime` 마운트
- Next.js는 PC에서 빌드 후 결과물만 배포 (Pi에서 빌드 금지)
- 동영상 트랜스코딩 금지. 원본 보존 + 오디오 추출만 수행
- ffmpeg 변환·백업은 새벽 배치로 분산

---

## 3. 정보 구조 (사람이 보는 계층)

일반적인 아카이브 사이트의 문법을 따른다.

### 브라우징 축

| 축 | 내용 |
| --- | --- |
| 인물별 | 구성원 프로필 → 해당 인물의 모든 기록 |
| 연도별 | 타임라인. 연도별 자료 밀도 시각화 |
| 유형별 | 텍스트 / 이미지 / 동영상 / 음성 |
| 컬렉션별 | "할머니 구술사", "1985 제주 여행" 등 큐레이션 묶음 |
| 검색 | 키워드 + 의미 검색(pgvector) |

### 주요 화면

1. **홈 / 타임라인** — 연도축 위에 자료 밀도와 최근 업로드 표시
2. **인물 페이지** — 프로필, 대표 사진, 관련 기록, 수집 현황
3. **컬렉션 페이지** — 하나의 사건·세션으로 묶인 자료 묶음
4. **상세 페이지** — 미디어 뷰어 + 전사문 + 태그 + 원본 다운로드
5. **업로드 화면** — 드래그앤드롭 + 최소 태깅 (아래 5절)
6. **데일리 인터뷰** — 매일/매주 질문 제시 → 음성 또는 텍스트 답변
7. **어드민** — 수집 현황 대시보드, 화자 태깅 작업대, 데이터셋 Export

---

## 4. 데이터 모델

```sql
-- 1. 구성원
CREATE TABLE members (
    member_id    VARCHAR(30) PRIMARY KEY,   -- 'grandma_01'
    name         VARCHAR(50) NOT NULL,
    relation     VARCHAR(30),               -- '할머니', '아빠'
    birth_year   INT,
    traits       JSONB,                     -- 말투 특성, 자주 쓰는 표현, 성격 요약

    -- 입력 모드 (확장 대비)
    input_mode   VARCHAR(10) DEFAULT 'proxy',  -- 'self'(본인 직접) | 'proxy'(가족 대리 수집)

    -- AI 활용 동의 (단계별)
    ai_consent   VARCHAR(20) DEFAULT 'none',
                 -- 'none' | 'search'(검색·RAG만) | 'voice'(음성 합성까지) | 'persona'(대화형까지)
    consent_at   TIMESTAMP
);

-- 2. 컬렉션 (사건/세션 단위 묶음)
CREATE TABLE collections (
    collection_id BIGSERIAL PRIMARY KEY,
    title         VARCHAR(200) NOT NULL,    -- '2026 설날 인터뷰' / '1962년 결혼'
    description   TEXT,
    occurred_at   DATE,
    period_label  VARCHAR(30),              -- 날짜 미상 시 '1960년대 초' 등
    location      VARCHAR(100),

    -- 사건 단위로도 사용한다. 연결된 파일이 0건이어도 유효하다.
    -- (인생의 중요한 사건 대부분은 남은 기록이 없다 → 이것이 곧 '수집 과제'가 된다)
    kind          VARCHAR(15) DEFAULT 'session'
                  -- 'session'(녹음·촬영 세션) | 'event'(생애 사건) | 'background'(인물·장소·조직)
);

-- 2-1. 구성원별 기억 (같은 사건도 사람마다 다르게 기억한다)
CREATE TABLE memories (
    memory_id     BIGSERIAL PRIMARY KEY,
    collection_id BIGINT REFERENCES collections(collection_id),
    member_id     VARCHAR(30) REFERENCES members(member_id),

    narrative     TEXT,                     -- 이 사건에 얽힌 이야기 (자유 서술)

    -- 감정의 이중 구조: 이 두 값의 간극이 그 사람의 해석 방식이다
    emotion_then    VARCHAR(20),            -- 당시 감정: 고난|슬픔|분노|기쁨|사랑|행복|
                                            --   즐거움|두려움|미안함|배신감
    evaluation_now  VARCHAR(20),            -- 현재 평가: 성공|실패|후회|즐거움|슬픔|
                                            --   고난|위기|기회
    motive          VARCHAR(20),            -- 동기: 질투|사랑|분노|결핍|의무|인정|
                                            --   연민|호기심|성취|우연  (선택 입력)
    reason_then     TEXT,                   -- 당시 그렇게 느낀 이유
    reason_now      TEXT,                   -- 지금 그렇게 평가하는 이유

    -- 출처 구분: 본인 답변만 페르소나 학습에 사용한다
    answered_by   VARCHAR(10) DEFAULT 'self',  -- 'self'(본인) | 'family'(가족 추정)

    embedding     vector(1024),
    created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 3. 아카이브 항목
CREATE TABLE archive_items (
    id             BIGSERIAL PRIMARY KEY,
    collection_id  BIGINT REFERENCES collections(collection_id),
    memory_id      BIGINT REFERENCES memories(memory_id),      -- 연결된 기억 (없으면 NULL)

    -- 생산자와 주제인물은 다르다.
    --   creator  : 이 기록을 만들거나 말한 사람 → 페르소나 학습에 사용
    --   subjects : 이 기록에 등장하는 사람들    → 아카이브 브라우징에 사용
    -- 예) 할머니가 아빠 어린 시절을 회상한 녹음
    --     → creator=할머니, subjects=[할머니, 아빠]. 아빠 페르소나 학습에는 쓰지 않는다.
    creator_id     VARCHAR(30) REFERENCES members(member_id),
    subject_ids    VARCHAR(30)[],

    media_type     VARCHAR(10) NOT NULL,    -- 파일 형식: 'text'|'image'|'video'|'audio'

    -- 문헌형식: 자료의 성격 (스캔한 편지는 형식상 image지만 성격은 letter)
    -- 20종 전체 목록과 근거는 docs/자료_분류체계.md 참조
    doc_type       VARCHAR(20),             -- diary|letter_sent|writing|interview|
                                            -- oral_history|vital|education|award|
                                            -- official|financial|medical|letter_recv|
                                            -- media|about|photo|av|ephemera|object|
                                            -- genealogy|ritual
    doc_type_by    VARCHAR(10) DEFAULT 'auto',  -- 'auto'(추정) | 'user'(확인)
    verified_date  DATE,                    -- 증빙 자료에서 확인된 확정 일자 (연표 기준점)

    file_path      TEXT NOT NULL,           -- 원본 경로
    title          VARCHAR(200),
    raw_content    TEXT,                    -- 원문 또는 STT 전사문

    -- 공통 태그 (아카이브 브라우징 + 학습 메타데이터 겸용)
    subjects_tagged_by VARCHAR(10) DEFAULT 'user', -- 'user'(사람 확인) | 'auto'(얼굴인식 추정)
    location       VARCHAR(100),

    -- 비전자 원본 (디지털화해도 실물은 남는다)
    physical_location  VARCHAR(200),        -- '안방 장롱 위 상자'
    physical_condition VARCHAR(10),         -- 'good'|'fair'|'poor' — poor는 우선 디지털화
    recorded_at    TIMESTAMP,               -- 실제 기록 시점 (EXIF 또는 수동)

    -- 페르소나 태그
    emotion        VARCHAR(20),             -- 'joy'|'sadness'|'calm'|'serious'
    target_person  VARCHAR(30),             -- 대화 상대 ('손주에게')
    speech_style   VARCHAR(30),             -- 'casual'|'formal'|'dialect'

    -- 처리 이력
    stt_engine     VARCHAR(40),             -- 'groq-whisper-large-v3'|'whispercpp-small'
    stt_confidence REAL,
    local_only     BOOLEAN DEFAULT FALSE,   -- TRUE: 외부 API 전송 금지 (민감)

    -- 학습 적격 상태 (5절 참조)
    ai_status      VARCHAR(20) DEFAULT 'pending',
                   -- 'ready' | 'pending' | 'excluded'
    ai_exclude_reason VARCHAR(50),          -- 'no_speaker_tag'|'low_quality'|'user_opt_out'

    embedding      vector(1024),            -- 임베딩 모델 확정 후 차원 조정
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 4. 발화 세그먼트 (음성/동영상 전사 결과. 화자 태깅 단위)
CREATE TABLE utterances (
    utterance_id  BIGSERIAL PRIMARY KEY,
    item_id       BIGINT REFERENCES archive_items(id),
    member_id     VARCHAR(30) REFERENCES members(member_id),  -- NULL이면 미태깅
    seq           INT NOT NULL,             -- 대화 순서
    start_sec     REAL,
    end_sec       REAL,
    text          TEXT NOT NULL,
    clip_path     TEXT,                     -- 분할 WAV 클립 (학습용)
    confidence    REAL
);

-- 5. 얼굴 기준 벡터 (구성원별 다중 등록. 연령대별로 나눠 관리)
CREATE TABLE face_references (
    ref_id       BIGSERIAL PRIMARY KEY,
    member_id    VARCHAR(30) REFERENCES members(member_id),
    era_label    VARCHAR(30),              -- '1960s'|'1990s'|'current' 등 연령대 구분
    embedding    vector(512),              -- InsightFace 등 얼굴 임베딩
    source_item  BIGINT REFERENCES archive_items(id),  -- 이 벡터를 얻은 원본 사진
    created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX ON face_references USING hnsw (embedding vector_cosine_ops);

-- 6. 사진/영상에서 검출된 얼굴
CREATE TABLE face_detections (
    face_id      BIGSERIAL PRIMARY KEY,
    item_id      BIGINT REFERENCES archive_items(id),
    bbox         INT[4],                   -- [x, y, w, h]
    embedding    vector(512),
    crop_path    TEXT,                     -- 얼굴 크롭 이미지 (향후 LoRA/아바타 자산)
    frame_sec    REAL,                     -- 동영상인 경우 해당 프레임 시각

    -- 매칭 결과
    suggested_member VARCHAR(30) REFERENCES members(member_id),
    similarity   REAL,                     -- 기준 벡터와의 코사인 유사도
    confirmed_member VARCHAR(30) REFERENCES members(member_id),  -- 사람이 확정한 값
    status       VARCHAR(15) DEFAULT 'pending'
                 -- 'confirmed' | 'suggested' | 'pending' | 'rejected'
);
```

### 학습 적격 상태 (`ai_status`)

| 값 | 의미 |
| --- | --- |
| `ready` | 화자 확정 + 품질 기준 충족. 데이터셋에 포함 |
| `pending` | 아카이브에는 보이나 학습 불가. 화자 미태깅, 검수 대기 등 |
| `excluded` | 영구 제외. 본인 요청, 품질 미달, 민감 기록 |

> **원칙:** 학습에 못 쓰는 자료도 아카이브에는 남는다. 화자 태깅이 안 된 대화 녹음도 **RAG 검색용으로는 그대로 유용**하다.

---

## 5. 업로드 및 전처리 파이프라인

### 업로드 시 요구하는 입력 (최소화 원칙)

필수는 **누가(인물)** 와 **언제(연도)** 뿐. 나머지는 나중에 보완 가능하도록 `pending` 처리한다.

- 인물 선택 (다중)
- 시점 (이미지·동영상은 EXIF/메타데이터에서 자동 추출, 없으면 입력)
- 컬렉션 지정 (선택, 새로 만들기 가능)
- `민감(로컬 전용)` 토글

### ① 음성 (Audio)

```
[업로드] → [원본 보존] → [16kHz mono 임시 변환] → [Silero VAD]
   → [STT: Groq whisper-large-v3 (폴백: whisper.cpp)]
   → [utterances 테이블에 세그먼트 저장] → [화자 태깅 대기]
```

- 원본은 무압축 그대로 `raw_archives/`에 보존
- VAD `speech_pad_ms` 300~400ms로 첫 음절 잘림 방지
- **단독 녹음**(1인 인터뷰): 화자 자동 확정 → `ai_status = ready`
- **대화 녹음**(다인): 화자 미상 → `pending`. 어드민 화자 태깅 작업대에서 문장별로 인물 지정
- `local_only` 항목은 외부 API 전송 금지, 로컬 whisper.cpp로만 처리

### ② 동영상 (Video)

```
[업로드] → [원본 보존(트랜스코딩 없음)] → [ffmpeg로 오디오 트랙 추출]
   → [음성 파이프라인으로 위임] → [썸네일 프레임 추출]
```

- 동영상은 세 가지 자산의 결합체: 음성(→STT/음성학습) + 프레임(→얼굴/아바타 학습) + 영상 자체(→감상용)
- Pi 4에서는 **트랜스코딩하지 않는다.** 오디오 추출과 썸네일 생성만 수행
- 프레임 단위 인물 추출은 향후 아바타 학습 단계에서 별도 처리

### ③ 이미지 (Image)

```
[업로드] → [EXIF 추출(날짜·위치)] → [썸네일 생성]
   → [얼굴 검출·임베딩 (InsightFace)] → [기준 벡터와 매칭] → [인물 태그 제안]
```

- **자동 캡셔닝은 서버에서 하지 않는다.** 업로드 시 간단 수동 태깅 또는 Export 직전 클라우드 일괄 처리
- 태그(인물·연도·장소·상황)가 그대로 LoRA 캡션 재료가 됨
- 얼굴 인식 상세는 [5.5절](#55-얼굴-인식-기반-인물-태그-제안) 참조

### 5.5 얼굴 인식 기반 인물 태그 제안

업로드 시 가장 번거로운 "나온 사람 모두 선택"을 줄이기 위해, 검출된 얼굴을 구성원 기준 벡터와 대조해 태그를 **제안**한다.

**모델:** InsightFace `buffalo_s` (ONNX Runtime, CPU). Pi 4에서 사진 1장당 약 1~3초. 업로드 후 백그라운드 처리이므로 지연은 문제되지 않는다. 벡터 검색은 기존 pgvector를 그대로 사용한다.

**핵심 원칙 — 자동 태깅이 아니라 제안이다.**

| 유사도 | 동작 |
| --- | --- |
| 높음 (≈0.6 이상) | 해당 인물을 **미리 체크된 상태**로 제안. 사용자는 확인만 |
| 애매 | "○○님인가요?" 확인 요청 |
| 낮음 / 미매칭 | 얼굴 박스만 표시하고 인물 선택 요청 |

- 사용자가 확인·수정하면 그 벡터를 `face_references`에 추가하여 정확도가 누적 개선된다.
- `subjects_tagged_by='auto'` 인 항목은 **`ai_status`를 `ready`로 승격하지 않는다.** 사람이 확인한 태그만 학습 데이터셋에 포함한다.

**이 프로젝트 특유의 난점과 대응**

| 난점 | 대응 |
| --- | --- |
| **나이 변화** — 20대와 80대 얼굴은 벡터 거리가 멂 | 한 인물에 **연령대별 기준 벡터를 다중 등록** (`face_references.era_label`). 옛날 사진을 태깅할수록 해당 시대 정확도가 올라감 |
| 오래된 사진의 화질 (흑백·스캔 노이즈·초점) | 검출 실패를 정상으로 간주. 수동 태깅으로 폴백 |
| 가족 간 닮음 (부모-자식, 형제) | 임계값을 보수적으로 잡고 확인 절차를 반드시 거침 |

**부수 효과**

- 얼굴 크롭(`face_detections.crop_path`)이 자동으로 축적된다. 향후 **LoRA·아바타 학습 자산**으로 그대로 활용한다.
- 동영상은 프레임을 일정 간격으로 샘플링해 동일 로직을 적용, 등장인물을 제안한다.

**프라이버시:** 얼굴 임베딩은 생체정보에 해당한다. 전 과정을 로컬에서 처리하며 외부 API로 전송하지 않는다. 백업 시 rclone crypt 암호화 범위에 포함되는지 확인한다.

### ④ 텍스트 (Text)

```
[웹 입력 또는 파일 업로드] → [본문 저장] → [임베딩 생성] → [태깅]
```

- 데일리 인터뷰의 [질문–답변] 형태는 질문이 DB에 이미 있으므로 **user/assistant 짝이 자동 완성**됨 (LLM 학습에 가장 이상적인 형태)
- 일기·편지 등 자유글은 화자 발화 코퍼스로 활용

---

## 6. 저장 구조

```
/data/                              ← USB 저장장치 (SD카드 아님)
├── raw_archives/                   # 무압축 원본 = 유일한 마스터
│   ├── audio/  images/  video/  text/
├── derived/                        # 재생성 가능한 파생물
│   ├── clips/                      #   발화 단위 분할 WAV
│   ├── thumbnails/
│   └── audio_from_video/
├── exports/                        # 학습용 데이터셋 (Export 시 생성)
│   ├── voice_{member}/             #   프리셋별 WAV + metadata.csv
│   ├── llm_{member}.jsonl
│   └── lora_{member}/              #   이미지 + .txt 캡션 쌍
└── pg_data/                        # PostgreSQL 데이터 디렉토리
```

---

## 7. 데이터셋 Export (기계가 읽는 계층)

어드민에서 구성원을 선택하고 용도별로 내보낸다. `ai_status = ready` 항목만 포함된다.

| 용도 | 산출물 | 구성 |
| --- | --- | --- |
| 음성 클로닝 | `voice_{member}.zip` | 프리셋별 WAV(32kHz/24kHz) + `metadata.csv` |
| LLM 파인튜닝 | `llm_{member}.jsonl` | `{"messages":[{"role":"user",...},{"role":"assistant",...}]}` |
| 이미지 LoRA | `lora_{member}.zip` | 이미지 + 동명 `.txt` 캡션 |
| RAG | `rag_{member}.json` | 전사문 + 메타데이터 + 임베딩 |

- Export 시 원본에서 대상 프리셋 샘플레이트로 재변환
- `stt_confidence` 임계값 미만 클립은 제외 또는 경고 표시

### 수집 현황 대시보드

어드민에 구성원별로 다음을 표시하여 **"언제 페르소나를 만들 수 있는가"**를 가늠한다.

- 학습 가능 음성 총 길이 (목표: 30분~1시간)
- Q&A 쌍 개수 (목표: 500~1,000턴)
- 인물 사진 장수 (목표: 20~50장)
- 감정 태그별 분포 (부족한 감정은 데일리 인터뷰 질문으로 유도)
- 화자 태깅 대기 항목 수

---

## 8. 백업

| 계층 | 방법 | 주기 |
| --- | --- | --- |
| 오프사이트 (기본) | rclone **crypt** → Google Drive | DB 하루 2~3회 / 미디어는 업로드 직후 |
| 로컬 (확장) | 데이터 수십 GB 초과 시 외장 HDD 추가 | 매일 야간 |
| 시스템 | SD카드 전체 이미지 백업 | 세팅 완료 시 + 주요 변경 시 |

- **암호화 필수.** rclone `crypt`로 파일명까지 클라이언트 측 암호화. 비밀번호는 서버 외부에 별도 보관 (분실 시 복원 불가)
- 작은 파일 다수를 개별 업로드하지 않는다. 날짜별 `tar.zst`로 묶어 업로드 (API 레이트 리밋 회피)
- 헤드리스 인증: PC에서 `rclone config`로 토큰 발급 후 `~/.config/rclone/rclone.conf` 복사
- 백업 대상: `raw_archives/`, `pg_dump`. (`derived/`, `exports/`는 재생성 가능)
- **월 1회 복원 테스트**로 유효성 검증 (`restore.sh verify` — 임시 DB에 덤프를 적용해 운영 DB를 건드리지 않고 확인)

### 구현

| 파일 | 역할 |
| --- | --- |
| `scripts/backup.sh` | `db` / `media` / `full` 모드. 중복 실행 방지(flock), 리모트 사전 점검, 로컬 덤프 보존 관리 |
| `scripts/restore.sh` | `list` / `db` / `media` / `verify`. 재해 복구 및 정기 검증 |
| `docs/백업_설정.md` | rclone crypt 설정, 헤드리스 인증, cron 등록, 복구 절차 |

**cron 기본 구성**

```cron
0 13,21 * * *  backup.sh db      # DB 덤프 하루 3회
0 3 * * *      backup.sh full    # 전체 백업 (새벽)
0 4 1 * *      restore.sh verify # 월 1회 백업 검증
```

> `sync`가 아닌 `copy`를 사용한다. 로컬에서 실수로 파일을 삭제해도 원격 백업은 보존된다.

---

## 9. 구축 로드맵

```
[Phase 1: 인프라·백업] → [Phase 2: DB·업로드·전처리] → [Phase 3: 아카이브 UI]
   → [Phase 4: 태깅·Export] → [향후: 페르소나 AI]
```

### Phase 1 — 인프라 및 백업
1. Ubuntu Server 24.04 LTS (헤드리스) 설치, `snapd` 제거
2. USB 저장장치 마운트, `/data` 구조 생성, log2ram·noatime·스왑off 적용
3. Docker & Docker Compose 설치
4. Tailscale로 가족 전용 폐쇄망 구축
5. **rclone crypt → Google Drive 백업 자동화** ([설정 가이드](docs/백업_설정.md))
   - PC에서 OAuth 인증 → `rclone.conf` 서버 복사 → crypt 리모트 구성
   - `backup.sh` 배치 및 cron 등록 → `restore.sh verify`로 복원 검증
6. SD카드 전체 이미지 백업 보관

### Phase 2 — DB 및 수집 파이프라인
1. PostgreSQL + pgvector 컨테이너 기동, 스키마 적용
2. ffmpeg / Silero VAD 세팅, whisper.cpp 빌드(폴백용)
3. FastAPI: 업로드 API, 미디어 타입별 라우팅, STT 연동(백오프·폴백), 세그먼트 분할
4. Groq API 키는 `.env` + Docker secret 관리

### Phase 3 — 아카이브 사이트 UI
1. Next.js 기본 레이아웃 + 인증(가족 계정)
2. 업로드 화면 (드래그앤드롭, 최소 태깅, EXIF 자동 추출)
3. 브라우징: 타임라인 / 인물 / 유형 / 컬렉션 / 검색
4. 상세 페이지: 미디어 뷰어 + 전사문 + 태그 편집
5. **얼굴 인식 인물 태그 제안** (사진 수백 장·수동 태깅 데이터가 쌓인 뒤 도입)
   - InsightFace 백그라운드 워커, 구성원별 기준 얼굴 등록 화면
   - 업로드 결과 화면에서 제안 태그 확인·수정 → 기준 벡터 자동 보강
6. 데일리 인터뷰 화면 (질문 제시 → 녹음/텍스트 답변)
   - 녹음 가이드: "조용한 곳에서 / 마이크 30cm 이내 / 평소 말하듯"
   - 업로드 시 SNR 간이 측정 → 미달 시 재녹음 안내

### Phase 4 — 태깅 도구 및 Export
1. 화자 태깅 작업대: 전사 세그먼트 목록에 인물을 터치로 지정
2. 수집 현황 대시보드
3. 용도별 데이터셋 Export 구현
4. `ai_status` 일괄 관리 도구

### 향후 — 페르소나 AI (별도 환경)
- **말투**: 대화 데이터 LoRA 파인튜닝 → "그 사람처럼 말한다"
- **기억**: pgvector RAG → **실제 기록에 근거한 답변만 생성** (환각 방지의 핵심)
- **목소리**: GPT-SoVITS 등으로 클로닝 (30분~1시간 데이터)
- 학습은 클라우드 GPU(RunPod 등), 추론은 별도 로컬 머신 또는 온디맨드 GPU
- 본 서버는 이 단계에서도 **데이터 공급원 역할만** 수행한다

---

## 10. 윤리 및 동의

- **사전 동의 필수.** 구성원 등록 시 AI 학습 활용 동의를 명시적으로 받고 기록한다 (`members.ai_consent`).
- 고인을 대비한 아카이브라면 **생전에 본인 의사를 확인**한다. 이 대화 자체가 가장 값진 기록이 되는 경우가 많다.
- 민감한 기록(유언·재산·건강 등)은 `local_only`로 외부 API 전송을 차단한다.
- 생성된 AI 음성·텍스트에는 **"AI 생성" 표시**를 남겨 실제 기록과 구분한다.
- 페르소나 AI는 **"그 사람의 대체물"이 아니라 "그 사람이 남긴 이야기에 접근하는 도구"**로 규정한다.
- 외부 공유·공개는 본인(또는 유족 전원) 합의를 거친다.

---

## 11. 운영 체크리스트

- [ ] 백업 자동화 + 월 1회 복원 테스트
- [ ] rclone crypt 비밀번호 오프라인 별도 보관
- [ ] SD카드 여분 확보 및 이미지 백업 최신화
- [ ] Google Drive 잔여 용량 분기별 확인
- [ ] Groq 데이터 정책 확인 및 가족 공지, 무료 티어 조건 분기별 재확인
- [ ] 임베딩 모델 확정 후 `vector()` 차원 반영
- [ ] 화자 태깅 대기 항목 월간 정리
- [ ] 얼굴 인식 제안 중 미확인(`status='suggested'`) 항목 월간 정리
- [ ] 구성원별 연령대 기준 얼굴 벡터 보강 (옛날 사진 태깅 시)
- [ ] `stt_confidence` 하위 항목 검토 및 재전사 여부 결정
- [ ] 구성원별 AI 학습 동의 기록 확보

---

## 12. 무엇보다 먼저

시스템은 나중에 얼마든지 고도화할 수 있지만, **기록할 기회는 지나가면 돌아오지 않습니다.**
서버가 완성되기를 기다리지 말고, 오늘 스마트폰 음성 메모로 30분을 녹음하세요.
그 파일은 어떤 하드웨어를 쓰든, 어떤 모델이 나오든 그대로 쓸 수 있습니다.
