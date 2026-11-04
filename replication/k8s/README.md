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
| `aws-tokyo/` | A: 네임스페이스·Postgres(TLS)·PgBouncer(emptyDir ini)·`30-expose.yaml`(NLB). `kustomization.yaml` 로 한 번에(`apply -k`), **클러스터 실제 상태와 같음**(11/4 `diff -k` 확인) |
| `gcp-seoul/` | B: 같은 구성(처음부터 TLS·emptyDir ini 포함). PgBouncer 백엔드 자리표시 `__A_HOST__` |
| `scripts/` | `subscribe.sh`(A→B 세우기) · `lag.sh` · `cutover.sh` · `rollback.sh` · `verify.sh`(누락·중복 대조) · `writer.sh`(진입점 경유 쓰기 부하) · `rehearsal.sh`(한 번에: 대조→컷오버→대조→롤백→대조, `rehearsals/` 에 기록) · `common.sh` |

## 적용 순서 (사람이, 데스크톱에서 · 인프라 담당 확인 뒤)

```bash
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
A=echo-dev-eks; B=gke_team-echo-final_asia-northeast3-a_echo-dev-gke; cd replication/k8s

# 0~1) A 전체 (Postgres TLS · PgBouncer emptyDir · NLB). Secret 두 개를 먼저 손으로(aws-tokyo/README.md · 40-tls.md)
kubectl --context $A diff -k aws-tokyo    # 바뀌는 것 확인(빈 출력 = 이미 같음)
kubectl --context $A apply -k aws-tokyo
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

## echo-was 와의 접점

- `DataSyncChecker.replication_lag(source, target)`(API 서버 8, 단계 `DATA_SYNC_CHECK`): publisher 쪽에서 `SELECT EXTRACT(EPOCH FROM replay_lag) FROM pg_stat_replication WHERE application_name = 'echo_sub'`(정방향; 역방향은 `echo_sub_rev` 를 B 에서). 접속은 `A_HOST`/`B_HOST`(GKE NAT 가 허용돼 있다)로 `pg_monitor` 권한 계정이 필요하다 — `CREATE ROLE echo_monitor LOGIN PASSWORD …; GRANT pg_monitor TO echo_monitor;` 를 양쪽에 넣고 Secret Manager 로 전달(요청 오면 한다).
- 컷오버·롤백 **실행 자체**는 echo-was 이전 계획에 없다(복제 지연 확인만). 시연은 사람이 `cutover.sh` 를 돌린다. 이전 계획과 잇는 것(비율 100% 도착 뒤 컷오버 호출)은 후속.

## 주의

- `FOR ALL TABLES` 발행이라도 **새 테이블은 B 에 DDL 을 먼저 넣고** `ALTER SUBSCRIPTION echo_sub REFRESH PUBLICATION`.
- PgBouncer 가 1개여야 repoint 가 한 번에 끝난다(replicas 1 유지).
- 재난(A 급사) 때는 롤백이 아니라 승격이다: B 에서 `ALTER SUBSCRIPTION echo_sub DISABLE` → B PgBouncer 를 `echo-pg` 로 repoint → RESUME. A 복구 뒤 `rollback.sh` 전에 재동기화가 필요하다(SPEC infra-8).
