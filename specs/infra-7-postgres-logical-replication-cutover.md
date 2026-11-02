# 인프라·이전 엔진 7: PostgreSQL 논리 복제 + 컷오버 (PgBouncer 대기 · 시퀀스 맞춤)

- 상태: Draft (팀 검토 전)
- 확인일: 2026-11-03
- 노션 태스크: https://app.notion.com/p/ad4ee1910af34aa6bcd4a756aec712dd
- GitHub 이슈: echo-infra #7 `[인프라·이전 엔진 7] PostgreSQL 논리 복제 + 컷오버`
- 저장소: `echo-infra` · 브랜치 `feat/pg-logical-replication-cutover`
- 작성: 이도현
- 근거: [ADR-0004](../docs/adr/[ADR-0004] 데이터 이전 — PostgreSQL 논리 복제 + PgBouncer 컷오버.md)

## 1. 목표

AWS 도쿄(A)의 PostgreSQL을 GCP 서울(B)로 **네이티브 논리 복제**하고, **PgBouncer로 쓰기를 짧게 멈춰 무손실 컷오버**한다. 순번 쓰기 N건 대조로 **누락 0·중복 0**을 증명하고, 컷오버 복제 지연 **≤ 1초(NFR-03)**를 지키며, 쓰기 정지 시간을 **측정값 그대로 공개**한다. 1차 기능 F8(데이터 동기화).

## 2. 현재 맥락과 확인된 사실

- 관리 대상 앱(#4) = 웹앱 + PostgreSQL + **데이터 대조용 순번 쓰기 엔드포인트**. 세 환경에 배포.
- 소스 DB = **클러스터 안 self-managed PostgreSQL**(ADR-0004). Managed(RDS/Cloud SQL) 아님.
- 시나리오 = AWS 도쿄(A, Primary) → GCP 서울(B, Standby). 환경 이름 `aws-tokyo`·`gcp-seoul`. CIDR 비중복 보장(`docs/architecture.md`, `contracts/aws-outputs.md`).
- **논리 복제는 시퀀스·DDL을 옮기지 않는다**(PostgreSQL 공식). → 컷오버 전 시퀀스 맞춤 필요.
- 연계: 측정·부하는 #10(10 rps 발생기 + 자동 기록), 롤백·역방향 복제는 #8, 백업(PITR)은 #14. 이 SPEC은 **정방향 이전과 컷오버**만 다룬다.
- echo-was 계약: 이미지 `repo@sha256:…`(tag 금지), secretRef `aws-sm:<이름|ARN>`. DB 접속 비밀은 Secrets Manager/Secret Manager, 저장소에 0건(NFR-17).

## 3. 범위

### 포함

- A Postgres: `wal_level=logical`, `CREATE PUBLICATION`, 복제 유저·슬롯.
- B Postgres: 초기 데이터 복사 + `CREATE SUBSCRIPTION`.
- **PgBouncer**: 앱과 DB 사이. 컷오버 때 `PAUSE`/`RESUME`, 백엔드 repoint.
- **시퀀스 맞춤** 절차·스크립트.
- 컷오버 오케스트레이션(수동 트리거부터, 목업 우선 → 실제 연결).
- 순번 대조 검증(누락·중복·복제 지연·쓰기 정지 시간).

### 제외

- 역방향 복제·자동 롤백 (#8).
- 백업·PITR·WAL 아카이브 (#14).
- 사용자 트래픽 전환·진입점 (#5·#6). 이 SPEC은 **DB 컷오버**까지. 앱의 DB 접속 repoint 접점만 맞춘다.
- Managed DB(RDS/Cloud SQL) 경로.
- 대용량·멀티테이블 최적화, 스키마 변경 중 이전.

## 4. 설계 (단계)

**1. A·B Postgres 기동 + PgBouncer 삽입**
- 앱이 **PgBouncer를 통해서만** DB에 붙게 배선한다. 컷오버가 접속 문자열 변경이 아니라 PgBouncer 백엔드 전환으로 이뤄지게 하기 위함.

**2. 논리 복제 뼈대**
- A: `wal_level=logical`, `CREATE PUBLICATION echo_pub FOR TABLE …`, 복제 전용 유저.
- B: 스키마 선반영 후 `CREATE SUBSCRIPTION echo_sub CONNECTION '…A…' PUBLICATION echo_pub`(초기 copy 포함).
- 복제 지연 모니터: `pg_stat_replication` / `pg_replication_slots`의 lag.

**3. 컷오버 절차 (스크립트 1개)**
```
① PgBouncer PAUSE            # A 쓰기 드레인·정지
② 복제 지연 0 대기 (≤ 1초)     # B가 A를 따라잡음
③ 시퀀스 맞춤                 # B: setval(seq, max(pk)+여유)
④ B 쓰기 가능화 · PgBouncer 백엔드를 B로
⑤ PgBouncer RESUME           # 쓰기가 B로
```
- ①~④ 사이 타임스탬프를 남겨 **쓰기 정지 시간**을 산출한다.

**4. 검증**
- #10 부하(10 rps)로 순번 쓰기를 돌리며 컷오버 실행.
- 컷오버 전후 A·B의 순번 집합을 대조 → **누락(gap) 0 · 중복 0**.
- 복제 지연·쓰기 정지 시간을 #10 자동 기록에 남긴다.

## 5. 완료 조건

- 순번 쓰기 N건 대조 결과 **누락 0 · 중복 0**.
- 컷오버 시점 복제 지연 **≤ 1초**(NFR-03).
- 쓰기 정지 시간을 **측정값 그대로 공개**.
- 컷오버 절차가 **스크립트로 재현** 가능(수동 트리거).

## 6. 이번에 하지 않는 것

- 역방향 복제·자동 롤백·60초 복귀 (#8).
- 백업·PITR (#14).
- 사용자 트래픽 전환·판정 규칙 (#6).
- Managed DB 경로.
