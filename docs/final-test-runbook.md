# 최종 테스트 절차 — 11/6 전체 리허설 · 11/7 시연 (인프라 몫)

누가 무엇을 어느 순서로 확인하는지, 실패하면 어떻게 되돌리는지. 숫자는 지금까지 실측(설계 문서 7절) 기준 "기대값".

## 0. 전제

- **변경 동결**: 11/6 18:00 이후 인프라 변경 없음(긴급은 채널 공지 뒤). Terraform `apply`·`kubectl apply`·DNS 변경 금지.
- **역할**: 대시보드 조작(이전·복귀) = API/프론트 담당 · DB 컷오버·롤백 = 인프라(동옥) · 관측·보안 화면 = 보안/DB 담당 · 사회 1명.
- **원본 상태**(모든 시험의 시작점): 가중치 `aws=100, gcp=0`, A 가 주 DB(A PgBouncer → `echo-pg`, B PgBouncer → A NLB), A→B `echo_sub` streaming, 역방향 구독 없음.

## 1. 시작 전 점검 (10분, 인프라)

| 항목 | 명령·보는 곳 | 통과 기준 |
|---|---|---|
| 복제 | A: `pg_stat_replication` · `replication/k8s/scripts/verify.sh` | `echo_sub` streaming, 지연 0, A = B, 누락 0·중복 0 |
| PgBouncer | 두 클러스터 `grep '^app = ' /etc/pgbouncer/pgbouncer.ini` · `SHOW DATABASES` | A → `echo-pg`, B → A NLB, paused 0 |
| 진입점 | `http://34.158.202.103/__entry/healthz`, `http://8.230.16.205/__entry/healthz`, admin `/clusters` | 둘 다 200, aws·gcp 업스트림 healthy, 가중치 aws=100(a·b 동일) |
| 앱 | `https://demo-y6cz3jrc.echoport.uk/readyz` + 환경별 주소 3개 | 전부 200 |
| 관제탑 | echo-was `/healthz`, 대시보드 환경 카드 | 3환경 CONNECTED |
| 관측 | Grafana 「Echo 고정 진입점」·「세 환경 한 그래프」 | 최근 5분 데이터 있음, 수집기 3곳 Running |
| 부하 | `make loadgen-off` 상태 확인 | 시연 직전에만 `make loadgen-on`(50 rps) |
| 컷오버 결과 표 | `echo_ops.cutover_runs` 양쪽 | 읽힘(echo_monitor) |

점검 명령 묶음: `replication/k8s/scripts/preflight.sh` (읽기만, 19개 항목, 실패가 있으면 종료 1).

## 2. 시연 순서 (11/4 합동 리허설로 확정)

| # | 단계 | 누가 | 기대값 | 보는 곳 |
|---|---|---|---|---|
| 1 | 부하 켜기 `make loadgen-on` | 인프라 | 50 rps, 5xx 0 | Grafana rps |
| 2 | **Echo 이전 aws→gcp** (10→50→100%) | 대시보드 | ~10초, 실패 0, 데이터 확인 = A `echo_sub` 지연 0 | 대시보드 진행 화면, Grafana 교차 |
| 3 | **DB 컷오버 A→B** — Job(`echo-ops`, 12.2 적용 뒤) 또는 `B_HOST=34.22.85.222 scripts/cutover.sh` | 인프라 | 쓰기 정지 6~9초, `echo_sub_rev` streaming, 누락 0·중복 0 | 터미널 + `echo_ops.cutover_runs` → 결과 화면 |
| 4 | (선택) 재난: A NLB 차단 → EMERGENCY 이전 → promote | 12.x 범위, 리허설 결과 보고 결정 | | |
| 5 | **Echo 복귀 gcp→aws** (Start failback) | 대시보드 | ~9초, 실패 0, 데이터 확인 = B `echo_sub_rev` 지연 0 | 같음 |
| 6 | **DB 롤백 B→A** `A_HOST=<A NLB> scripts/rollback.sh` | 인프라 | 복귀 ~10초, 원본 상태로 | 터미널 + 결과 표 |
| 7 | 대조 `verify.sh`, 부하 끄기 `make loadgen-off`, 캡처 | 인프라 | A = B 누락 0·중복 0 | |

- 2 → 3 → 5 순서가 고정인 이유: 이전 **도중** 컷오버는 쓰기 정지가 오류율 롤백을 부르고, 복귀의 데이터 확인은 역방향 구독이 있어야 통과한다.
- 3·6 사이에 대시보드 이전을 돌리지 않는다(컷오버 창에서 `echo_sub` 가 꺼져 데이터 확인이 실패).

## 3. 진입점 페일오버 (인프라 5.1, 11/6 측정)

전제: Cloudflare `*.echoport.uk` A 레코드 두 개(34.158.202.103, 8.230.16.205, 둘 다 프록시).

```bash
HOST=demo-y6cz3jrc.echoport.uk DURATION=120 entrypoint/scripts/failover-probe.sh   # 창 1
gcloud compute instances stop echo-dev-entry --zone asia-northeast3-a --configuration=echo   # 창 2, 30초 뒤
gcloud compute instances start echo-dev-entry --zone asia-northeast3-a --configuration=echo  # 측정 끝나면
```
기대: 실패 구간 수 초 이내, 보조(b)로 넘어가 200 유지. 결과는 설계 문서 7절·#33.

## 4. 온프레 랜선 분리 (인프라 13, 다른 담당)

온프레 네트워크를 끊으면 진입점 헬스체크가 실패를 감지해 클라우드로 넘기는 시연. 진입점에 `onprem` 갈래가 추가된 뒤 이 절을 채운다.

## 5. 실패 시 되돌리기

| 상황 | 조치 |
|---|---|
| 컷오버·롤백 스크립트가 중간에 멈춤 | 스크립트는 SIGTERM 에 양쪽 RESUME. 수동: `pgb A "RESUME app;"`·`pgb B "RESUME app;"` → `lag.sh` 로 구독 상태 확인 → 필요하면 `rollback.sh` |
| 이전 판정 실패 | echo-was 가 출발 100% 로 자동 롤백. 수동: `PUT /weights {"aws":100,"gcp":0}` |
| A 가 진짜 죽음 | 롤백이 아니라 승격: B `ALTER SUBSCRIPTION echo_sub DISABLE` → B PgBouncer 를 `echo-pg` 로 repoint → RESUME. A 복구 뒤 `subscribe.sh`(copy_data) 로 다시 동기화 |
| 진입점 a 죽음 | b 가 받는다(가중치 마지막 값). 복구: `gcloud compute instances start echo-dev-entry` |
| 앱이 DB 에 못 붙음 | `demo-y6cz3jrc-env` DATABASE_URL 이 자기 쪽 PgBouncer 인지, PgBouncer paused 0 인지 |
| 뭐든 끝난 뒤 | 1절 점검표로 원본 상태 확인 |

## 6. 기록

- DB: `rehearsal.sh` → `replication/k8s/rehearsals/<시각>.md`, 컷오버·롤백은 `echo_ops.cutover_runs` 행.
- 앱 이전: echo-was 실행 로그, 대시보드 결과 화면, Grafana 캡처.
- 실측값은 `docs/design-infra.md` 7절 표에 한 줄씩.
