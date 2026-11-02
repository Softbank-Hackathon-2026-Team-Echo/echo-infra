# 인프라·이전 엔진 14: DB 백업 — base backup + 연속 WAL (PITR)

- 상태: Draft (팀 검토 전)
- 확인일: 2026-11-03
- GitHub 이슈: echo-infra #14 `[DB 백업] [protocol] CDC 이벤트 메시지 정의`
  - **이슈 재정의:** 원래 "CDC 이벤트 메시지(MySQL/GTID)"였으나, 앱이 PostgreSQL로 확정되고(#4) 이전이 네이티브 논리 복제로 가면서(ADR-0004) **Debezium/CDC 이벤트를 쓰지 않는다.** 백업은 Postgres 네이티브 **base backup + 연속 WAL(PITR)**로 한다. 이슈 제목·본문은 이 SPEC 기준으로 갱신 필요.
- 저장소: `echo-infra` · 브랜치 `feat/db-backup-pitr`
- 작성: 이도현
- 근거: [ADR-0004](../docs/adr/[ADR-0004] 데이터 이전 — PostgreSQL 논리 복제 + PgBouncer 컷오버.md), [ADR-0003(대체됨)](../docs/adr/[ADR-0003] CDC 캡처 — 직접 구현 대신 Debezium Server 도입.md)

## 1. 목표

PostgreSQL을 **base backup + 연속 WAL 로그**로 백업해, 라이브 복제(#7)와 별개로 **임의 시점 복구(PITR)**가 가능하게 한다. 사본과 원본의 차이를 로그로 계속 메워 RPO를 초 단위로 줄인다. "그냥 복사"가 아니라 로그를 쌓아 gap을 줄이는 방식이다.

## 2. 현재 맥락과 확인된 사실

- 관리 대상 DB = PostgreSQL(#4). 이전(#7)은 논리 복제라 **B(서울)는 라이브 복제본**이다. 이 SPEC의 백업은 그와 별개의 **내구 복구 재료**다.
- **왜 백업이 또 필요한가:** 라이브 복제본은 논리 손상·오염(랜섬웨어·잘못된 쓰기)까지 그대로 따라 복제한다. 과거 시점으로 돌아가려면 base + WAL 로그가 있어야 한다(ADR-0002 영역의 토대).
- Debezium/CDC 이벤트는 쓰지 않는다(ADR-0004로 ADR-0003 대체).
- 재난 전제: 도쿄가 죽으면 S3 도쿄 백업에 못 닿는다 → 백업은 **cross-cloud 사본**이 있어야 한다(`docs/architecture.md`: AWS state 사본도 GCS에).

## 3. 범위

### 포함

- **base backup**: `pg_basebackup` 주기 적재 → object storage.
- **연속 WAL**: `pg_receivewal`로 WAL을 object storage에 near-real-time 스트리밍(파일 단위 `archive_command`보다 gap이 작다).
- **PITR 복구 스크립트**: base 적재 → WAL을 목표 시점까지 replay.
- **cross-cloud 사본**: S3(도쿄) ↔ GCS(서울) 미러.
- **복구 검증**: 복구 후 체크섬·행수 대조.

### 제외

- 라이브 논리 복제 이전(#7).
- 랜섬웨어 과거 clean 지점 복원의 탐지·판단(ADR-0002, 별도).
- Debezium/CDC 이벤트 메시지(드롭).
- Object Storage(앱의 비정형 파일) 백업.

## 4. 설계 (단계)

1. **base backup 주기 적재** — `pg_basebackup`를 주기로 떠서 object storage에 올린다. 뜬 시점의 WAL 위치(LSN)를 함께 기록한다.
2. **연속 WAL 스트리밍** — `pg_receivewal`로 WAL을 object storage에 계속 쌓는다. 같은 구간이 다시 와도 덮어써 안전하게(idempotent).
3. **cross-cloud 미러** — base + WAL을 서울(GCS)로도 복제한다. 도쿄가 죽어도 복구 재료가 산다.
4. **PITR 복구** — base 적재 후 WAL을 목표 시점(LSN/시각)까지 replay. 복제본까지 잃었거나 과거로 돌아가야 할 때 쓴다.
5. **복구 검증** — 복구 결과의 체크섬·행수를 기록과 대조한다. 통과 못 하면 그 복구는 실패로 본다.

## 5. 완료 조건

- base backup + 연속 WAL이 object storage에 쌓이고, cross-cloud 사본이 있다.
- 임의 시점으로 PITR 복구가 성공하고, 체크섬·행수 검증을 통과한다.
- 마지막 base 이후 WAL gap이 초 단위임을 측정으로 보인다.

## 6. 이번에 하지 않는 것

- 라이브 이전·컷오버(#7), 롤백·역방향 복제(#8).
- 랜섬웨어 탐지·과거 clean 지점 자동 복원(ADR-0002).
- Debezium/CDC 이벤트.
