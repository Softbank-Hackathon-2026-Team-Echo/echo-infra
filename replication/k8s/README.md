# 이전 엔진 — 실제 클러스터 배선 (A 도쿄 EKS ↔ B 서울 GKE)

로컬 PoC([../README.md](../README.md))의 메커니즘을 두 클러스터에 그대로 옮긴다. 양쪽을 **대칭**으로 둬서 정방향(A→B)·역방향(B→A)·컷오버·롤백이 같은 스크립트로 돈다.

```text
AWS 앱 ──▶ A PgBouncer ──┐                       ┌── B PgBouncer ◀── GCP 앱
                        ├─▶ A Postgres ══복제══▶ B Postgres ◀┘  (컷오버 전: 두 PgBouncer 모두 A 를 본다)
                        │   (NLB, GCP NAT 만)      (LB, AWS NAT 만)
컷오버 = 두 PgBouncer PAUSE → B 따라잡음 → 역방향 구독(B→A) → 백엔드를 B 로 → RESUME   (쓰기 정지 ≈ 1초)
```

- 앱은 **자기 쪽 PgBouncer 로만** 붙는다(`echo-pgbouncer.echo-data.svc.cluster.local:6432`, 유저 `app_rw`, DB `app`). 컷오버는 접속 문자열이 아니라 PgBouncer 백엔드 전환이다(ADR-0004).
- cross-cloud 는 공개 LB 지만 **상대 클라우드 NAT IP 만** 받고(`30-expose.yaml`), scram + TLS(`sslmode=require`, 자체 서명)다.
- 역방향 구독은 **컷오버의 쓰기 정지 창 안에서** 만든다(`copy_data=false`). 창 안엔 쓰기가 없어 빈틈이 없다. 롤백도 거울이다.

| 파일 | 내용 |
|---|---|
| `aws-tokyo/` | A: 네임스페이스·Postgres·PgBouncer(도현 1차안, 적용됨) + `30-expose.yaml`(NLB) + TLS(`40-tls.md`·`tls-patch.json`) + `pgbouncer-emptydir-patch.yaml`(ini 를 즉시 바꿀 수 있게) |
| `gcp-seoul/` | B: 같은 구성(처음부터 TLS·emptyDir ini 포함). PgBouncer 백엔드 자리표시 `__A_HOST__` |
| `scripts/` | `subscribe.sh`(A→B 세우기) · `lag.sh` · `cutover.sh` · `rollback.sh` · `verify.sh`(누락·중복 대조) · `ops-table.sh`(컷오버 결과 표 `echo_ops.cutover_runs` 만들기, 인프라 7.2) · `writer.sh`(진입점 경유 쓰기 부하) · `rehearsal.sh`(한 번에: 대조→컷오버→대조→롤백→대조, `rehearsals/` 에 기록) · `common.sh` |

## 적용 순서 (사람이, 데스크톱에서 · 인프라 담당 확인 뒤)

```bash
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
A=echo-dev-eks; B=gke_team-echo-final_asia-northeast3-a_echo-dev-gke; cd replication/k8s

# 0) A: TLS 켜기 + PgBouncer ini 를 emptyDir 로 (각각 재시작 1회)
#    40-tls.md 의 명령(Secret echo-pg-tls → tls-patch.json)
kubectl --context $A -n echo-data patch deploy echo-pgbouncer --patch-file aws-tokyo/pgbouncer-emptydir-patch.yaml
kubectl --context $A -n echo-data rollout status deploy/echo-pgbouncer

# 1) A 를 서울에서 보이게 (NLB, GCP NAT 만)
kubectl --context $A apply -f aws-tokyo/30-expose.yaml
A_HOST=$(kubectl --context $A -n echo-data get svc echo-pg-external -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); echo "$A_HOST"

# 2) B: 비밀을 A 와 같은 값으로 (같은 계정·비밀번호여야 앱·복제가 양쪽에서 같은 접속 문자열을 쓴다)
kubectl --context $B apply -f gcp-seoul/00-namespace.yaml
kubectl --context $A -n echo-data get secret echo-pg-secret -o json | ruby -rjson -e 'd=JSON.parse(STDIN.read); d["metadata"]={"name"=>"echo-pg-secret","namespace"=>"echo-data"}; puts d.to_json' | kubectl --context $B apply -f -
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=echo-pg-b" -keyout /tmp/pgb.key -out /tmp/pgb.crt
kubectl --context $B -n echo-data create secret tls echo-pg-tls --cert=/tmp/pgb.crt --key=/tmp/pgb.key; rm -f /tmp/pgb.key /tmp/pgb.crt

# 3) B 기동 (PgBouncer 는 A 를 본다)
kubectl --context $B apply -f gcp-seoul/10-postgres.yaml
kubectl --context $B -n echo-data rollout status statefulset/echo-pg
sed "s/__A_HOST__/$A_HOST/" gcp-seoul/20-pgbouncer.yaml | kubectl --context $B apply -f -
kubectl --context $B -n echo-data rollout status deploy/echo-pgbouncer
kubectl --context $B apply -f gcp-seoul/30-expose.yaml
B_HOST=$(kubectl --context $B -n echo-data get svc echo-pg-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo "$B_HOST"

# 4) 정방향 복제 A→B
A_HOST=$A_HOST scripts/subscribe.sh
scripts/lag.sh; scripts/verify.sh
```

### 앱 DB 연결

- 수동 배치 데모앱(`demo-app/`): Secret `echo-demo/demo-db` 의 `database-url` 을 자기 쪽 PgBouncer 로 바꾼다(값은 셸 안에서만 조립).
  ```bash
  for C in $A $B; do
    kubectl --context $C -n echo-data get secret echo-pg-secret -o jsonpath='{.data.APP_PASSWORD}' | base64 -d | \
      xargs -I{} kubectl --context $C -n echo-demo create secret generic demo-db --from-literal="database-url=postgresql://app_rw:{}@echo-pgbouncer.echo-data.svc.cluster.local:6432/app" --dry-run=client -o yaml | kubectl --context $C apply -f -
    kubectl --context $C -n echo-demo rollout restart deploy/demo-app
  done
  ```
  (`password` 키가 사라지면 `demo-db`·`demo-pgbouncer` 파드는 그대로 두고 쓰지 않는다. 지워도 된다.)
- echo-was 실제 실행기(API 서버 3-2 P9): 앱 네임스페이스의 `{ns}-env` Secret `DATABASE_URL` 에 같은 문자열. 지민·데이터 파트가 넣는다.

### 리허설 (10 rps 쓰기 중)

```bash
scripts/verify.sh                       # 누락 0 · 중복 0 · max(n) 같음
B_HOST=$B_HOST scripts/cutover.sh       # 쓰기 정지 시간 출력
scripts/verify.sh; scripts/lag.sh       # 역방향(B→A) 이 붙어 있어야 한다
A_HOST=$A_HOST scripts/rollback.sh      # 복귀 시간 출력
scripts/verify.sh
```

### 다시 돌려도 되는가 · 종료 코드 (인프라 12.1, [#66](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-infra/issues/66))

`cutover.sh`·`rollback.sh` 는 시작할 때 **지금 쓰기 담당**(`writer_side`: 구독 방향과 두 PgBouncer 백엔드가 같은 쪽을 가리키는지)을 본다. 이미 도착이 쓰기 담당이거나, `PLAN_ID=<이전 계획 uuid>` 를 주었고 그 계획의 기록이 이미 있으면 PAUSE 없이 끝난다. 그래서 같은 명령을 다시 돌려도 쓰기 정지가 한 번 더 생기지 않는다.

| 종료 코드 | 뜻 | 쓰기 담당 | 다음 |
|---|---|---|---|
| 0 | 끝남 (이번에 옮겼거나 `ALREADY_WRITER`·`ALREADY_DONE`) | 도착 | 다음 단계 |
| 1 | 바뀐 것 없음 (시작 전 확인 실패 · 따라잡기 실패 · 쓰기 정지 중 실패 → 양쪽 RESUME 함) | 출발 그대로 | 트래픽을 출발로 되돌리거나 원인을 고친 뒤 다시 |
| 2 | 부분 상태 (구독·백엔드를 바꾸는 중 실패 → **RESUME 하지 않음**, 또는 시작 전에 이미 어긋나 있음) | 판단 불가 | 아래 "부분 상태 복구" |

`PLAN_ID` 를 주면 결과 표 행의 `plan_id` 에 남는다(echo-was 가 시간 창 대신 계획으로 찾을 수 있게). 같은 `(plan_id, kind)` 는 한 번만 기록된다(고유 색인).

로컬 시험: `scripts/tests/run.sh` (Docker 로 Postgres 두 대를 띄우고 `tests/bin/kubectl` 이 `kubectl exec` 를 넘긴다. 컷오버·롤백 한 바퀴 + 멱등 + 실패 처리 + 부분 상태 복구, 34개 확인).

### 부분 상태 복구

`writer_side` 출력(`PARTIAL(구독=…, PgBouncer=…, A 백엔드=…, B 백엔드=…)`)으로 어디서 멈췄는지 본다. 앱 쓰기는 PgBouncer PAUSE 로 막혀 있을 수 있으니 먼저 판단하고 RESUME 한다.

| 출력 | 멈춘 곳 | 되돌리기 (출발을 다시 쓰기 담당으로) |
|---|---|---|
| `구독=?`, `PgBouncer=A` (컷오버 중) | B `echo_sub` 를 끈 뒤, 역방향 구독·repoint 전 | `pg B "ALTER SUBSCRIPTION echo_sub ENABLE;"` → A 에 `echo_sub_rev` 가 있으면 `pg A "DROP SUBSCRIPTION echo_sub_rev;"` → `pgb A "RESUME app;"; pgb B "RESUME app;"` → `cutover.sh` 다시 |
| `구독=B`, `PgBouncer=?` (컷오버 중) | 역방향 구독은 만들었고 repoint 가 한쪽만 됨 | 앞으로 끝낸다: `repoint B echo-pg; repoint A $B_HOST` → 양쪽 RESUME (B 가 쓰기 담당) |
| `구독=?`, `PgBouncer=B` (롤백 중) | A `echo_sub_rev` 를 끈 뒤, 정방향 구독·repoint 전 | `pg A "ALTER SUBSCRIPTION echo_sub_rev ENABLE;"` → 양쪽 RESUME → `rollback.sh` 다시 |
| `구독=A`, `PgBouncer=?` (롤백 중) | 정방향 구독은 만들었고 repoint 가 한쪽만 됨 | 앞으로 끝낸다: `repoint A echo-pg; repoint B $A_HOST` → 양쪽 RESUME (A 가 쓰기 담당) |

(`pg`·`pgb`·`repoint` 는 `source scripts/common.sh` 뒤에 쓸 수 있다.) 복구 뒤 `scripts/verify.sh` 로 누락·중복 0 을 확인한다.

## echo-was 와의 접점

- `DataSyncChecker.replication_lag(source, target)`(API 서버 8, 단계 `DATA_SYNC_CHECK`): publisher 쪽에서 `SELECT EXTRACT(EPOCH FROM replay_lag) FROM pg_stat_replication WHERE application_name = 'echo_sub'`(정방향; 역방향은 `echo_sub_rev` 를 B 에서). 접속은 `A_HOST`/`B_HOST`(GKE NAT 가 허용돼 있다)로 `pg_monitor` 권한 계정이 필요하다 — `scripts/monitor-user.sh` 가 양쪽에 `echo_monitor`(pg_monitor) 를 만들고 비밀번호를 Secret Manager `echo-dev-echo-was-pg-monitor-password`(껍데기는 Terraform, 값은 스크립트) 에 넣는다. echo-was 는 SecretSync 로 받는다(11/4).
- **컷오버·롤백 결과 표 `echo_ops.cutover_runs`**(인프라 7.2, [#57](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-infra/issues/57)): `cutover.sh`·`rollback.sh` 가 RESUME 뒤 새 primary 에 한 줄(종류 CUTOVER/ROLLBACK · 쓰기 정지 ms · 드레인·따라잡기·전환 ms · 장부 건수 · 누락 · 중복)을 쓴다. echo-was 는 같은 `echo_monitor` 연결로 읽어 이전 계획 결과에 붙인다(API 서버 16, [echo-was#63](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-was/issues/63)). 기록이 실패해도 컷오버·롤백은 성공으로 둔다. 표는 `subscribe.sh`·`cutover.sh`·`rollback.sh` 가 시작할 때 `ops_table_ensure` 로 양쪽에 있는지 보고(없으면 만들고 켜진 구독을 REFRESH), 따로 `scripts/ops-table.sh` 로도 만든다 — A 를 새로 세워도 다시 생긴다.
- 컷오버·롤백 **실행 자체**는 아직 echo-was 이전 계획에 없다(복제 지연 확인만). 시연은 사람이 `cutover.sh` 를 돌린다. 이전 계획과 잇는 것은 인프라 12.2(컷오버 Job, [#67](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-infra/issues/67))·API 서버 17([echo-was#75](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-was/issues/75))에서 한다. 일꾼은 위 종료 코드로 다음 동작을 정한다.

## 주의

- `FOR ALL TABLES` 발행이라도 **새 테이블은 B 에 DDL 을 먼저 넣고** `ALTER SUBSCRIPTION echo_sub REFRESH PUBLICATION`.
- 복제되는 표의 키에 `bigserial` 을 쓰지 않는다: 논리 복제는 시퀀스를 넘기지 않아 반대쪽이 같은 번호를 다시 내면 키 충돌로 복제가 멈춘다(`echo_ops.cutover_runs` 는 uuid).
- PgBouncer 가 1개여야 repoint 가 한 번에 끝난다(replicas 1 유지).
- 재난(A 급사) 때는 롤백이 아니라 승격이다: B 에서 `ALTER SUBSCRIPTION echo_sub DISABLE` → B PgBouncer 를 `echo-pg` 로 repoint → RESUME. A 복구 뒤 `rollback.sh` 전에 재동기화가 필요하다(SPEC infra-8).
