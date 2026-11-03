# [#1][protocol] Debezium 이벤트 포맷을 채택하고 쓰는 필드를 고정한다

> 선행: 없음. [ADR-0003](<../adr/[ADR-0003] CDC 캡처 — 직접 구현 대신 Debezium Server 도입.md>), [ADR-0001](<../adr/[ADR-0001] 데이터 정합성 — 복제 시점이 아니라 복구 기준점으로.md>) 참고.
> 이 이슈는 **메시지 계약만** 정의한다. 캡처(#2)·소비(#3) 구현은 별도 이슈다.

### 배경

ADR-0001은 전달 보장을 at-least-once + 멱등성(Idempotency)으로 하기로 했다. 이 방식이 성립하려면, 이벤트에 **순서 키(GTID)**와 **멱등 키(PK)**가 반드시 실려 있어야 한다.

ADR-0003에서 캡처를 Debezium Server로 정했으므로, **메시지 형식을 새로 설계하지 않고 Debezium envelope를 채택한다.** 다만 Debezium envelope는 필드가 많고 포맷이 Debezium에 종속되므로, 이 이슈에서 **우리가 의존하는 필드만 고정하고, Consumer가 쓸 내부 공통 형태로의 매핑을 정의**한다. 그래야 나중에 캡처를 바꿔도 하류(#3·#5·#6)가 덜 흔들린다.

### 설계

**1. Debezium envelope에서 쓰는 필드**

Debezium 변경 이벤트에서 아래만 쓴다. 나머지는 무시한다.

| Debezium 필드 | 쓰임 |
| --- | --- |
| `op` (`c`/`u`/`d`/`r`) | INSERT / UPDATE / DELETE / snapshot-read 구분 |
| `after` | 변경 후 행 전체(ROW 이미지) |
| `before` | `DELETE` 때 대상 식별 |
| `source.gtid` | 순서 키. "어디까지 처리했는지"의 기준(Offset) |
| `source.db` · `source.table` | 대상 DB·테이블 |
| message key | 대상 행의 Primary Key. 멱등 적용의 기준 |
| `ts_ms` | 원본에서 변경이 일어난 시각 |

**2. 내부 공통 이벤트로 정규화한다**

Debezium envelope를 받아 내부 형태(`source_id`·`gtid`·`db`·`table`·`op`·`pk`·`after`·`ts`)로 한 번 변환한다. 하류는 이 내부 형태만 본다. Debezium 포맷 종속을 이 변환 한 곳에 가둔다(ADR-0003 🔴 완화책).

**3. 순서 키와 멱등 키**

- **순서 키는 `gtid`다.** Consumer는 이 값으로 "어디까지 처리했는지"를 추적한다.
- **멱등 키는 `(source_id, db, table, pk)`다.** 같은 행 이벤트가 두 번 와도, 더 과거의 `gtid`면 무시한다.

**4. reject 규칙**

변환 단계에서 필수 필드(`op`·`source.gtid`·대상·`pk`)가 없거나 모르는 `op`면 reject한다. 모르는 값을 덜 안전한 쪽으로 처리하지 않고, 아예 막아 원인을 드러낸다.

### 작업

- 내부 공통 이벤트 타입을 파일 하나에 정의한다.
- Debezium envelope → 내부 이벤트 매핑·검증 함수를 만든다.
- 필수 필드 누락·미지 `op` 시 reject한다.

### 완료 조건

- 내부 이벤트 타입 정의와 매핑 규칙 문서가 있다.
- 샘플 Debezium 이벤트(`c`/`u`/`d`/`r` 각각)가 내부 이벤트로 올바로 변환되는 테스트가 통과한다.
- 필수 필드가 빠지거나 모르는 `op`인 이벤트가 reject되는 테스트가 통과한다.

### 이번에 하지 않는 것

- Managed DB(RDS/Cloud SQL)용 이벤트 형식. provider-native 경로라 별도로 정한다.
- Checkpoint 스키마·백업 카탈로그 스키마(#5).
- Object Storage 변경 이벤트.
