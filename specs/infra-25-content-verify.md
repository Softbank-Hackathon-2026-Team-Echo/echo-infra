# 인프라 25: 행 내용·스키마 지문 대조 검증기 (#150)

DB 이전 검증에서 「번호·개수 기반 누락·중복 확인」과 「실제 행 내용·스키마가 같은지」를 나눠 판정합니다. 이번 단계는 **조회 전용 검증 명령과 격리 시험**입니다. 운영 DB 에는 붙지 않았고, 쓰기 전환 순서·운영 설정·echo-was 는 바꾸지 않았습니다.

## 1. 두 검사의 보장 범위

| | 장부 검사 (`verify.sh`, `record_run`) | 내용 검사 (`content-verify.sh`, 이번) |
|---|---|---|
| 대상 | 시험 장부 `demo.seq_write` 하나 | 등록한 표 목록(`TABLES`) |
| 보는 것 | 번호 `n` 의 개수·공백(누락)·중복, 양쪽 `max(n)` | 행 수 · 기본 키 집합 지문 · 행 내용 지문 · 스키마 지문을 따로 |
| 말할 수 있는 것 | 장부 번호가 빠지거나 겹치지 않았다 | 등록한 표의 모든 행 값과 열 구성이 같다(지원 범위 안에서) |
| 말할 수 없는 것 | 행 값·다른 표·스키마가 같다 | 등록하지 않은 표, 기본값·인덱스·제약·트리거·권한, 지원 밖 타입 |
| 전환 영향 | 결과 표 `echo_ops.cutover_runs` 에 기록 | 없음(결과 JSON 만 낸다. 전환을 막거나 허용하지 않는다) |

## 2. 사용

```bash
# 1) 조회 계정 (운영 적용은 승인 뒤. 이 PR 은 스크립트만)
TABLES="demo.seq_write" replication/k8s/scripts/verify-user.sh
# 2) 대조 (A→B, 정방향 슬롯으로 따라잡기 확인)
TABLES="demo.seq_write" SLOT=echo_sub replication/k8s/scripts/content-verify.sh > result.json
```

| 환경 변수 | 기본 | 뜻 |
|---|---|---|
| `SRC` · `DST` | `A` · `B` | 출발·도착 (common.sh 의 컨텍스트·네임스페이스, Postgres 파드 안 psql) |
| `TABLES` | `demo.seq_write` | 등록 표 1~50 개, `schema.table` 소문자·숫자·`_` |
| `SLOT` | 없음 | 출발 쪽 논리 복제 슬롯. 주면 도착이 출발 시점까지 따라잡았는지 확인 |
| `CATCHUP_WAIT` | 10 | 따라잡기 대기 최대 초 |
| `MAX_ROWS` | 200000 | 표당 행 상한. 넘으면 지문을 만들지 않고 UNKNOWN |
| `QUERY_TIMEOUT_MS` | 20000 | 한 쪽 조회의 문장 시간 상한 |
| `VERIFY_USER` · `VERIFY_DB` | `echo_verify` · `app` | 조회 계정·DB |

종료 코드: `0` 모두 MATCH · `1` MISMATCH 있음 · `2` MISMATCH 없이 UNKNOWN 있음 · `3` 입력 오류(아무것도 실행하지 않음).

## 3. 비교 시점 — 「출발 → 도착 → 출발」

1. **S1** 출발 지문을 트랜잭션 하나(`REPEATABLE READ READ ONLY`)로 읽고 그 시점 LSN 을 남깁니다.
2. `SLOT` 이 있으면 출발의 `pg_replication_slots.confirmed_flush_lsn ≥ S1 LSN` 이 될 때까지 기다립니다. 시간 안에 안 되면 `NOT_CAUGHT_UP` 입니다.
3. **T** 도착 지문을 읽습니다.
4. **S2** 출발 지문을 다시 읽습니다.

표마다 S1 = S2 일 때만 판정하고, 다르면 그 표는 `SOURCE_CHANGED`(UNKNOWN)입니다. 출발 표가 S1·S2 사이에 바뀌지 않았고 도착이 S1 시점까지 따라잡았다면 T 는 같은 상태여야 하므로, 그때의 차이만 MISMATCH 로 봅니다. 사전 상태 조회(행 수·지연)와 최종 내용 대조를 같은 증거로 쓰지 않습니다.

한계: 그 사이에 바뀌었다가 정확히 되돌아온 경우(ABA)는 구분하지 못합니다. `SLOT` 이 없으면 따라잡기를 확인하지 않습니다(복제 관계가 없는 두 DB 비교용).

## 4. 지문 규칙 (`content-verify/1`)

| 지문 | 계산 | 고정한 표현 규칙 |
|---|---|---|
| 행 내용 | `md5(string_agg(to_jsonb(행)::text, 줄바꿈 ORDER BY 기본 키))` | jsonb 가 키(열 이름)를 정렬해 **열 순서와 무관**합니다. NULL(`null`)과 빈 문자열(`""`)을 구분합니다. 세션 고정: `TimeZone=UTC`, `DateStyle=ISO, YMD`, `IntervalStyle=iso_8601`, `bytea_output=hex`, `extra_float_digits=1` |
| 기본 키 | `md5(string_agg(ROW(기본 키)::text …))` | 순서 = `ROW(기본 키)::text COLLATE "C"` (DB 정렬 규칙과 무관). 복합 키 지원 |
| 스키마 | `md5(열 이름 · format_type · NOT NULL 을 이름 순 COLLATE "C" + 기본 키 열 목록)` | 기본값·identity·인덱스·제약·트리거·권한은 넣지 않습니다(구독자 쪽에서 다를 수 있어서) |

지원 타입: `int2 int4 int8 numeric float4 float8 bool text varchar bpchar uuid date time timestamp timestamptz interval jsonb bytea`. 그 밖의 타입이 하나라도 있으면 그 표는 UNKNOWN 입니다. 방법 버전이 다르면 지문끼리 비교하지 않습니다.

## 5. 결과

표준 출력에 JSON 하나를 냅니다. 행 원문·접속 비밀은 결과·로그 어디에도 쓰지 않습니다(지문·개수·코드만). 오류 원문도 행 값이 섞일 수 있어 남기지 않고 종류만 고릅니다.

```json
{"method":"content-verify/1","checkedAt":"…Z","source":{"side":"A","db":"app","lsn":"0/7848E48"},"target":{…},
 "alignment":{"rule":"source-target-source","slot":"echo_sub","caughtUp":true,"waitedMs":109},
 "limits":{"maxRows":200000,"queryTimeoutMs":20000},
 "tables":[{"table":"demo.seq_write","result":"MATCH","reason":null,"rows":{"source":300,"target":300},
            "fingerprints":{"schema":{…},"primaryKeys":{…},"rows":{…}}}],
 "summary":{"match":1,"mismatch":0,"unknown":0},"elapsedMs":674}
```

| 결과 | reason |
|---|---|
| MISMATCH | `SCHEMA` · `TARGET_TABLE_MISSING` · `ROW_COUNT` · `PRIMARY_KEYS` · `ROW_CONTENT` |
| UNKNOWN | `UNSUPPORTED_TYPE` · `NO_PRIMARY_KEY` · `SOURCE_TABLE_MISSING` · `ROW_LIMIT` · `NOT_CAUGHT_UP` · `SLOT_MISSING` · `SOURCE_CHANGED` · `SOURCE_TIMEOUT` · `TARGET_TIMEOUT` · `*_PERMISSION_DENIED` · `*_QUERY_FAILED` · `CATALOG_*` |

## 6. 조회 계정 `echo_verify` (`verify-user.sh`)

- NOSUPERUSER · NOCREATEDB · NOCREATEROLE · NOREPLICATION · NOBYPASSRLS, 비밀번호 없음입니다. 파드 안 로컬 소켓으로만 붙고, 네트워크 접속(scram)으로는 로그인할 수 없습니다.
- 등록 표에만 `SELECT`, 그 스키마에만 `USAGE` 를 줍니다. `default_transaction_read_only = on` 입니다.
- 슈퍼유저 `postgres`·`demo` 나 앱 쓰기 계정 `app_rw` 로 검증하지 않습니다. `echo_monitor`(pg_monitor)는 표를 읽을 수 없어 쓰지 않습니다.
- GRANT 는 논리 복제로 옮겨지지 않으므로 A·B 각각에 실행합니다(스크립트가 양쪽에 함).

## 7. 격리 시험 (`replication/k8s/scripts/tests/content-verify-test.sh`)

로컬 Docker Postgres 17 두 대와 기존 시험용 `tests/bin/kubectl` 로 돌립니다. 운영 경로와 같은 `kubectl exec … psql` 코드 경로를 탑니다. 11/8 결과: **통과 38 · 실패 0**.

| 사례 | 기대 | 결과 |
|---|---|---|
| A→B 복제 뒤 등록 표 4개 (단일 키·복합 키·NULL·빈 문자열·jsonb·bytea·float·timestamptz·한글) | MATCH, 종료 0 | 통과 |
| 같은 입력 두 번 | 지문 같음(재현) | 통과 |
| 열 순서만 다른 표 | MATCH | 통과 |
| `point` 열, 기본 키 없음 | UNKNOWN `UNSUPPORTED_TYPE` · `NO_PRIMARY_KEY`, 종료 2 | 통과 |
| 결과·오류 출력에 행 값(`secret-row-value`, 한글 값) | 없음 | 통과 |
| `echo_verify` 로 INSERT, `pg_authid` 조회 | 둘 다 거부, 기본 읽기 전용 on | 통과 |
| 도착에서 값 하나만 바꿈(행 수·ID 같음) | MISMATCH `ROW_CONTENT`, 종료 1 | 통과 |
| NULL → 빈 문자열 | MISMATCH `ROW_CONTENT` | 통과 |
| 도착에서 1행 삭제 / 같은 개수에 다른 키 | `ROW_COUNT` / `PRIMARY_KEYS` | 통과 |
| 도착에 열 추가 / 도착에 표 없음 | `SCHEMA` / `TARGET_TABLE_MISSING` | 통과 |
| 구독 멈춘 채 출발에 쓰기 / 없는 슬롯 | `NOT_CAUGHT_UP` / `SLOT_MISSING` | 통과 |
| 검사 중 출발에 계속 쓰기 | `SOURCE_CHANGED` | 통과 |
| `MAX_ROWS=10` / `QUERY_TIMEOUT_MS=50` (30만 행) | `ROW_LIMIT` / `SOURCE_TIMEOUT` | 통과 |
| 표·슬롯 이름에 SQL 주입 | 종료 3, 실행 없음 | 통과 |

소요 시간(로컬 M 시리즈 노트북 Docker, 참고값): 작은 표 3개 0.67초, 30만 행·75 MB 표 1개 2.3~2.6초(출발 2회 + 도착 1회 읽기 포함). 운영 DB 크기·부하에서의 시간은 재지 않았습니다.

## 8. 검증하지 못한 범위·다음 단계

- 운영 A·B 에서 실행하지 않았습니다. `verify-user.sh` 운영 적용(역할 추가)과 첫 운영 조회는 승인 뒤 시연 이후에 합니다.
- 운영 DB 의 조회 부하는 미산정입니다. 첫 운영 실행은 `demo.seq_write` 하나, 기본 상한으로 시작합니다.
- 도착이 물리 복제 대기 서버인 경우, 출발과 도착의 PostgreSQL 주 버전이 다른 경우, 지원 밖 타입은 시험하지 않았습니다.
- 계획 식별자와 결과 연결·API 응답 초안은 이 이슈 댓글에서 API 서버 쪽과 맞춥니다(이 PR 은 결과 JSON 까지).
- 전환 차단 조건으로 쓰려면 성능·실패 시 동작·복귀 영향 검증과 별도 적용 승인이 먼저입니다.
