# Stateless 읽기 원점 단절 후보 계약 — 기본 OFF

GitHub 이슈: echo-infra#122(HTTP 원점 단절 stateless 읽기 대피·재연결 고정).
선행: echo-infra#113(서비스별 Host·가중치 격리), head `883e03881020fecf1b28c16f08faffa392f053b6`.

## 1. 범위·판정

이 후보는 HTTP 원점 장애 뒤 명시한 GET/HEAD 경로만 다른 원점으로 보내기 위한 제어면이다. DB writer 선출·승격·fencing(옛 writer 쓰기 차단)·복제·journal 재생을 하지 않는다. `statelessOnly`는 운영자의 선언이며 데이터가 안전함을 자동 판별하는 보안 검사가 아니다. DB 조회·민감 정보·전체 앱 캐시는 대상이 아니다.

| 계층 | 확인 | 판정 |
|---|---|---|
| 제품 제어면·생성기 + 실제 loopback HTTP fixture | 원점 reset/refused/blackhole/delay/reconnect/flap, 제어면 정지, 전체 원점 정지 | 제한된 fixture 인수 PASS, 요청 오류 존재 |
| 실제 Envoy validate·file xDS 수용·요청 | 미실행, 현재 승인된 동일 실행 엔진 확인 불가 | PARTIAL_BLOCKED |
| 고객 URL·물리 단절·단일 DB writer·정합성 | 미확인/미실행 | UNVERIFIED |

Envoy 인수 전 운영 ON 금지다. 생성 JSON과 제한 HTTP interpreter 통과는 Envoy 스키마·동작 증거가 아니다. 무중단·완전 무손실을 보장하지 않는다.

## 2. 활성화·정확한 입력

기본값 `READ_FAILOVER_ENABLED=0`. `1`일 때만 `SERVICE_ROUTING_ENABLED=1` 및 읽기 전용 정책 파일 `READ_FAILOVER_POLICIES_FILE`이 필요하다. 그 외 플래그 값은 시작을 거절한다. 기존 compose·배포 파일은 변경하지 않았다.

정책 JSON은 최상위 `services` 배열 하나다. 각 항목은 다음 필드만 허용한다.

| 필드 | 계약 |
|---|---|
| serviceId / publicHost | 이미 등록된 서비스 UUID 및 그 서비스의 정확한 public Host |
| statelessOnly | boolean true, 운영자의 stateless 선언 |
| safePaths | 1~32개 정확 경로. 루트·와일드카드·query·중복·`/__entry/` 거절 |
| eligibleEnvironmentIds | 등록된 2~8개 환경 UUID, 중복 거절 |

정책 대상은 initialWeights에 단일 100% 주력이 있어야 한다. 정책 미등록 서비스와 unknown Host에는 후보 경로를 추가하지 않는다. 모든 서비스의 기존 weights/revision과 legacy 렌더링은 읽기 대피 관측만으로 수정하지 않는다.

## 3. 건강 관측·고정·재시작

제품 `poll_read_health()`는 지정된 Envoy admin의 `/clusters?format=json`만 0.4초 제한으로 읽고 로컬 루프가 0.5초 기다린다. 표본은 active check·outlier·pending 상태가 정상인 호스트여야 한다. 최소 3개 정상 표본 및 2초 안정 구간, 표본 간 1.5초 이하를 요구한다. 연속 2개 불량 표본 뒤 자격 있는 대체 원점을 선택한다. cluster 연결·health timeout 후보는 0.25초, health interval/no-traffic interval 0.5초, unhealthy threshold 2·healthy threshold 3이다. 실제 탐지·수용·요청 지연은 native에서 아직 측정하지 않았다.

떠난 원점은 `state/read-failover.json`의 quarantined에 남는다. 선택 원점 회복에도 옛 원점 자동 failback을 하지 않는다. 재시작은 quarantine/write gate를 보존하되 건강 표본은 새로 수집한다. marker가 있는데 상태 파일이 없거나 hash가 맞지 않으면 자동 초기화하지 않고 거절한다. 이 latch는 프록시 로컬 상태이며 두 진입점 간 분산 합의나 DB fencing이 아니다.

admin 연결 실패 시 마지막 생성 파일을 유지한다. 제어면이 죽은 동안 새 장애를 처리할 수 있음을 보장하지 않는다. CDS/RDS는 별도 파일 갱신이며 원자적인 다중 자원 수용·분산 latch 일관성도 아직 인수하지 않았다.

## 4. 쓰기 보류·조회 분리

`_read_routes()`는 아래 중 하나이면 unsafe method를 `503 WRITE_SAFETY_NOT_READY; no dispatch`로 생성한다.

1. durable latch의 writesBlocked가 true.
2. 현재 제어 weights가 정책의 initialWeights와 다름.
3. 선택 원점이 안정 건강 자격을 갖추지 못함.

고장 전 정상 POST도 응답 유실이면 결과 UNKNOWN이다. HTTP 실패를 DB 미커밋으로 단정하지 않는다. 쓰기 gate 해제용 writer/fencing/복제 receipt 연동은 구현하지 않았으며 NOT_READY다. 제어 weights 변경이나 프로세스 재시작으로 gate를 해제하지 않는다.

정책에 없는 GET/HEAD는 기존 원점에 남기며 민감 조회를 대체 원점으로 보내지 않는다. 안전 경로 GET/HEAD만 선택된 원점에 간다. 후보의 route timeout·max_stream_duration은 1.5초, GET/HEAD retry 최대 1회·per-try 0.5초·backoff 0.025~0.1초, unsafe retry 0이다. 클라이언트 retry/timeout/hedge 헤더 제거 후보를 생성한다. 헤더 처리 순서·실제 deadline 강제·자동 송신 횟수는 Envoy에서 아직 검증하지 않았다. 기존 legacy 재시도 정책을 이 계약의 unsafe0으로 오해하지 않는다.

## 5. 실측 — Envoy와 섞지 않음

아래는 제품 RDS 생성기를 읽는 제한 HTTP fixture의 기존 raw를 2026-11-07 재집계한 값이다. 재실행한 native 수치가 아니다. 복구 시간은 장애 이벤트부터 첫 대체 원점 요청 시작까지이며 물리 단절 RTO 보장이 아니다.

| fixture | 요청 | 오류 | 워밍업 오류 | 다른 서비스 오류 | 대체 응답까지 초 | 원점 POST 수 | 최대 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| reset | 81 | 14 | 9 | 0 | 1.502798 | 1 | 436.141667 |
| refused | 96 | 15 | 10 | 0 | 1.122198 | 0 | 136.281583 |
| blackhole | 90 | 15 | 10 | 0 | 1.795905 | 1 | 507.590250 |
| delay | 90 | 14 | 10 | 0 | 2.055049 | 1 | 819.273292 |
| control-outage | 46 | 8 | 8 | 0 | 해당 없음 | 0 | 404.572417 |
| all-dead | 145 | 30 | 12 | 0 | 0.800691 | 1 | 505.602208 |
| 합계 | 548 | 96 | 59 | 0 | 보장값 아님 | 4 | 819.273292 |

측정 구간 합 62.222626초. 동일 키 추가 POST 송신 0은 이 fixture 원점 수신 기록의 관측이다. 실DB 커밋 중복·누락 0의 증거가 아니다. 쓰기 보류 503와 전체 원점 정지 오류도 오류 합계에 포함한다.

| native 항목 | 요청 | 오류·복구·지연 | imageID | 판정 |
|---|---:|---|---|---|
| 공식 Envoy v1.39.6 linux/arm64 | 0 | 측정 없음 | null | PARTIAL_BLOCKED |

2026-11-07 18:15 KST M1의 선택 context `colima`는 과거와 같은 default socket이나 Colima profile 상태가 Stopped다. Running인 `colima-echo`는 다른 socket이므로 대신 선택하지 않았다. daemon 기동·다른 socket/SSH·image pull/run·새 network 0. 승인 digest는 `sha256:eebc293321d015af3ce65cb2424d0a7aaab417a7101f2a4e57d514b7826789ba`이며 이번 실물 확인을 수행하지 못했다.

## 6. 운영 인수·중단 조건

고객 URL이 Envoy를 통과하는지와 실제 단절 장비는 NET1 회신 전 미확인이다. 기본 OFF를 유지한다. 별도 승인 없이 운영 VM/DB/Cloudflare/공유 NIC/VPN/기존 Docker 자원을 변경하지 않는다.

native 재개 전 기존 해커톤 엔진의 정확한 context·profile·endpoint와 사용 승인을 확인한다. 새 엔진 기동이나 임의 tag 변경으로 우회하지 않는다. 원본 제품 생성물의 validate, file xDS config_dump·성공/거부 counter·오류 로그·실요청을 각각 수집한다. file xDS를 gRPC wire ACK로 표현하지 않는다. sourceSHA·imageID·원점 POST 송신·cleanup을 함께 남긴다.

writer/fencing/복제 상태 불명확, 모든 안전 원점 없음, native reject, 예상 밖 다른 서비스 영향 또는 시험 자원 소유권 불명확이면 중단한다. 도현 replay와 동옥 onprem-b2를 수정하거나 새 DB 승격/복귀 엔진을 만들지 않는다. ON·운영 merge/deploy·실 장애 주입은 이 후보의 승인에 포함되지 않는다.
