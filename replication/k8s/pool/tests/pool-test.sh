#!/usr/bin/env bash
# 풀 계층(PgBouncer-DB 분리) 통합 시험. Docker 로 k3s 한 대를 띄워 저장소 매니페스트를 그대로 적용한다.
#   A = ns echo-data   (aws-tokyo/10-postgres.yaml)        — 쓰기 담당(발행)
#   B = ns echo-data-b (같은 파일, 네임스페이스만 바꿈)     — 사본(구독 echo_sub)
#   풀 = ns echo-pool  (pool/aws-tokyo, db-writer → A)
# 시험
#   1) 인증: auth_file + SCRAM pass-through 로 app_rw 가 PgBouncer 를 거쳐 A 에 쓴다(DB 함수·pgbouncer_auth 없이)
#   2) DNS: ExternalName 을 바꾼 뒤 파드에서 새 주소가 보이기까지 걸린 시간
#   3) 전환: 쓰기를 계속 넣는 중에 PAUSE → 따라잡기 → db-writer=B → RECONNECT → RESUME. 쓰기 정지 시간, 받은 쓰기 누락 0, 전환 뒤 A 에 쓰기 0
#   4) 재시작: PgBouncer 파드를 지워도 B 로 붙는다(옛 방식은 ConfigMap 값으로 돌아감)
#   5) NetworkPolicy: 앱 네임스페이스에서 DB 직접 접속은 막히고, echo-pool 에서는 된다
# 범위 밖: 클러스터 두 개(실제 교차 클라우드)·TLS 검증·역방향 구독 — 운영 리허설 몫
# 사용: replication/k8s/pool/tests/pool-test.sh   (KEEP=1 이면 k3s 를 남긴다)
set -uo pipefail
# Git Bash(Windows): docker 에 넘기는 인자(/tmp/… 같은 컨테이너 안 경로)를 Windows 경로로 바꾸지 않게. 호스트 파일은 hostpath 로 넘긴다
export MSYS_NO_PATHCONV=1
hostpath() { command -v cygpath >/dev/null && cygpath -w "$1" || echo "$1"; }
cd "$(dirname "$0")/../.."   # replication/k8s
C=echo-pool-t-k3s
pass=0 fail=0
ok()  { echo "  ✅ $*"; pass=$((pass+1)); }
bad() { echo "  ❌ $*"; fail=$((fail+1)); }
k()   { docker exec -i "$C" kubectl "$@"; }
pg()  { local ns=$1; shift; k -n "$ns" exec -i echo-pg-0 -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d app -tA "$@"; }
adm() { k -n echo-pool exec -i deploy/echo-pgbouncer -c admin -- psql -X -h 127.0.0.1 -p 6432 -U pgbouncer_admin -d pgbouncer -tA "$@"; }
now() { python -c 'import time;print(time.time())'; }
cleanup() { [[ ${KEEP:-} == 1 ]] || docker rm -f "$C" >/dev/null 2>&1; rm -rf "$TMP"; }
TMP=$(mktemp -d); trap cleanup EXIT
IMAGES="postgres:17 postgres:17-alpine edoburu/pgbouncer:v1.26.1-p0 busybox:1.37"

echo "== 준비: k3s · 이미지 · A/B Postgres · 복제 · 풀 계층"
docker rm -f "$C" >/dev/null 2>&1
docker run -d --privileged --name "$C" rancher/k3s:v1.36.5-k3s1 server --disable traefik --disable metrics-server --disable servicelb >/dev/null
for img in $IMAGES; do docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null; done
for i in $(seq 1 90); do k get --raw /readyz >/dev/null 2>&1 && break; sleep 1; done
docker save $IMAGES | docker exec -i "$C" ctr -n k8s.io images import - >/dev/null
k wait --for=condition=Ready node --all --timeout=90s >/dev/null

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=echo-pg-test" -keyout "$(hostpath "$TMP/pg.key")" -out "$(hostpath "$TMP/pg.crt")" 2>/dev/null
SUPER=$(openssl rand -hex 12); APP=$(openssl rand -hex 12); REPL=$(openssl rand -hex 12); PGB=$(openssl rand -hex 12); ADMIN=$(openssl rand -hex 12)
for ns in echo-data echo-data-b; do
  k create namespace "$ns" >/dev/null
  docker cp "$(hostpath "$TMP/pg.crt")" "$C:/tmp/pg.crt" && docker cp "$(hostpath "$TMP/pg.key")" "$C:/tmp/pg.key"
  k -n "$ns" create secret tls echo-pg-tls --cert=/tmp/pg.crt --key=/tmp/pg.key >/dev/null
  k -n "$ns" create secret generic echo-pg-secret --from-literal=POSTGRES_PASSWORD="$SUPER" --from-literal=APP_PASSWORD="$APP" \
    --from-literal=REPL_PASSWORD="$REPL" --from-literal=PGB_AUTH_PASSWORD="$PGB" --from-literal=userlist.txt="\"pgbouncer_auth\" \"$PGB\"" >/dev/null
  sed -e "s/namespace: echo-data$/namespace: $ns/" -e 's/storageClassName: ebs-csi-default-sc/storageClassName: local-path/' aws-tokyo/10-postgres.yaml \
    | sed '/resources:/,/limits:/{s/cpu: "250m"/cpu: "50m"/}' | k apply -f - >/dev/null
done
for ns in echo-data echo-data-b; do k -n "$ns" wait --for=condition=Ready pod/echo-pg-0 --timeout=180s >/dev/null || { bad "$ns Postgres 가 뜨지 않음"; exit 1; }; done
for ns in echo-data echo-data-b; do pg "$ns" -c "CREATE TABLE public.writes (id int PRIMARY KEY, at timestamptz NOT NULL DEFAULT now())" >/dev/null; done
# B 의 app_rw 검증자를 A 와 같게(운영 sync-role-verifiers.sh 와 같은 일) — 없으면 SCRAM pass-through 가 B 로그인에 실패한다
V=$(pg echo-data -c "select rolpassword from pg_authid where rolname='app_rw'")
# psql 변수(:'v')는 -c 에서 치환되지 않으므로 SQL 을 stdin 으로 넣는다(common.sh 머리말과 같은 이유)
printf '%s' "$V" | k -n echo-data-b exec -i echo-pg-0 -c postgres -- sh -c   'v=$(cat); echo "ALTER ROLE app_rw PASSWORD :'"'"'v'"'"';" | psql -X -q -v ON_ERROR_STOP=1 -U postgres -d app -v v="$v"' >/dev/null
[[ $(pg echo-data -c "select md5(rolpassword) from pg_authid where rolname='app_rw'") == $(pg echo-data-b -c "select md5(rolpassword) from pg_authid where rolname='app_rw'") ]]   || { bad "B 의 app_rw 검증자를 A 와 맞추지 못함"; exit 1; }
echo "CREATE SUBSCRIPTION echo_sub CONNECTION 'host=echo-pg.echo-data.svc.cluster.local dbname=app user=repl_user password=$REPL sslmode=require' PUBLICATION echo_pub;" \
  | k -n echo-data-b exec -i echo-pg-0 -c postgres -- psql -X -q -U postgres -d app >/dev/null
k create namespace echo-pool >/dev/null
k -n echo-pool create secret generic echo-pgbouncer-secret --from-literal=ADMIN_PASSWORD="$ADMIN" \
  --from-literal=userlist.txt="$(printf '"app_rw" "%s"\n"pgbouncer_admin" "%s"\n' "$V" "$ADMIN")" >/dev/null
unset V
kubectl kustomize pool/aws-tokyo | k apply -f - >/dev/null
k -n echo-pool rollout status deploy/echo-pgbouncer --timeout=120s >/dev/null || { bad "풀 PgBouncer 가 뜨지 않음"; exit 1; }
k create namespace app >/dev/null
for i in $(seq 1 30); do [[ $(pg echo-data -c "select count(*) from pg_stat_replication where application_name='echo_sub' and state='streaming'") == 1 ]] && break; sleep 1; done

URL="postgresql://app_rw:$APP@echo-pgbouncer.echo-pool.svc.cluster.local:6432/app?sslmode=disable"
client() { k -n app run "c$RANDOM" --rm -i --restart=Never --image=postgres:17-alpine --image-pull-policy=Never --quiet -- psql -X -tA "$URL" -c "$1" 2>&1; }

echo "== 1. 인증: auth_file + SCRAM pass-through (DB 함수 없이)"
out=$(client "insert into public.writes(id) values (0) returning inet_server_addr()")
A_IP=$(k -n echo-data get pod echo-pg-0 -o jsonpath='{.status.podIP}'); B_IP=$(k -n echo-data-b get pod echo-pg-0 -o jsonpath='{.status.podIP}')
[[ $out == *"$A_IP"* ]] && ok "app_rw → 풀 PgBouncer → A($A_IP) 쓰기 성공" || bad "쓰기 실패 또는 A 가 아님: $out"
[[ $(adm -c "SHOW DATABASES" | awk -F'|' '$1=="app"{print $2}') == db-writer.echo-pool.svc.cluster.local ]] && ok "PgBouncer 백엔드 = db-writer" || bad "백엔드가 db-writer 가 아님"
[[ $(adm -c "SHOW USERS" | grep -c pgbouncer_auth) == 0 ]] && ok "pgbouncer_auth(DB 역할) 를 쓰지 않음" || bad "pgbouncer_auth 가 보임"

echo "== 2. DNS: ExternalName 변경이 파드에 보이기까지"
k -n echo-pool create service externalname dns-probe --external-name=echo-pg.echo-data.svc.cluster.local >/dev/null
sleep 2; k -n echo-pool exec deploy/echo-pgbouncer -c admin -- getent hosts dns-probe.echo-pool.svc.cluster.local >/dev/null
t0=$(now); k -n echo-pool patch svc dns-probe --type merge -p '{"spec":{"externalName":"echo-pg.echo-data-b.svc.cluster.local"}}' >/dev/null
dns_s=""; for i in $(seq 1 120); do
  if k -n echo-pool exec deploy/echo-pgbouncer -c admin -- getent hosts dns-probe.echo-pool.svc.cluster.local 2>/dev/null | grep -q "$B_IP"; then dns_s=$(python -c "print(round($(now)-$t0,1))"); break; fi; sleep 0.5; done
[[ -n $dns_s ]] && ok "새 주소가 보이기까지 ${dns_s}초 (k3s CoreDNS)" || bad "60초 안에 새 주소가 보이지 않음"

echo "== 3. 전환 A → B (쓰기를 넣는 중)"
k -n app run writer --restart=Never --image=postgres:17-alpine --image-pull-policy=Never --env="URL=$URL" -- sh -c \
  'i=1; while [ ! -f /tmp/stop ] && [ $i -le 100000 ]; do if psql -X -tAq "$URL" -c "insert into public.writes(id) values ($i)" >/dev/null 2>&1; then echo "ok $i"; else echo "fail $i"; fi; i=$((i+1)); sleep 0.1; done; sleep 3600' >/dev/null
k -n app wait --for=condition=Ready pod/writer --timeout=60s >/dev/null; sleep 4
t_pause=$(now); adm -c "PAUSE app;" >/dev/null
a_max_at_pause=$(pg echo-data -c "select max(id) from public.writes")
for i in $(seq 1 60); do lag=$(pg echo-data -c "select pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) from pg_stat_replication where application_name='echo_sub'"); [[ $lag == 0 ]] && break; sleep 0.2; done
pg echo-data-b -c "ALTER SUBSCRIPTION echo_sub DISABLE" >/dev/null
k -n echo-pool patch svc db-writer --type merge -p '{"spec":{"externalName":"echo-pg.echo-data-b.svc.cluster.local"}}' >/dev/null
for i in $(seq 1 120); do k -n echo-pool exec deploy/echo-pgbouncer -c admin -- getent hosts db-writer.echo-pool.svc.cluster.local 2>/dev/null | grep -q "$B_IP" && break; sleep 0.5; done
adm -c "RECONNECT app;" >/dev/null; adm -c "RESUME app;" >/dev/null; t_resume=$(now)
sleep 5; k -n app exec writer -- touch /tmp/stop; sleep 2
pause_s=$(python -c "print(round($t_resume-$t_pause,1))")
k -n app logs writer > "$TMP/w.log"
acked=$(awk '$1=="ok"{print $2}' "$TMP/w.log" | sort -n); nacked=$(echo "$acked" | grep -c .); nfail=$(grep -c '^fail' "$TMP/w.log")
echo "     쓰기 정지 ${pause_s}초 · 받은 쓰기 ${nacked} · 실패 ${nfail}"
python -c "import sys; sys.exit(0 if $pause_s < 15 else 1)" && ok "쓰기 정지 ${pause_s}초" || bad "쓰기 정지가 김: ${pause_s}초"
pg echo-data-b -c "select id from public.writes where id > 0 order by id" > "$TMP/b.ids"
missing=$(comm -23 <(echo "$acked") <(sort -n "$TMP/b.ids") | grep -c .)
[[ $missing == 0 ]] && ok "받은 쓰기 ${nacked}건 모두 B 에 있음(누락 0)" || bad "B 에 없는 받은 쓰기 ${missing}건"
a_max_end=$(pg echo-data -c "select max(id) from public.writes where id < 999999")
[[ $a_max_end == "$a_max_at_pause" ]] && ok "PAUSE 뒤 A 에 들어간 쓰기 0 (A 최대 id ${a_max_at_pause} 그대로)" || bad "PAUSE 뒤에도 A 에 쓰기: ${a_max_at_pause} → ${a_max_end}"
b_after=$(pg echo-data-b -c "select count(*) from public.writes where id > ${a_max_at_pause:-0}")
[[ $b_after -gt 0 ]] && ok "전환 뒤 쓰기 ${b_after}건은 B 에만" || bad "전환 뒤 B 에 쓰기가 없음"
[[ $nfail == 0 ]] && ok "전환 중 앱 쓰기 실패 0(PAUSE 로 기다렸다가 B 로)" || echo "  ⚠ 전환 중 실패 ${nfail}건(누락은 아님 — 실패한 요청은 앱이 실패를 받았다)"

echo "== 4. 재시작: PgBouncer 파드를 지워도 B 로"
k -n echo-pool delete pod -l app=echo-pgbouncer --wait=false >/dev/null; sleep 2
k -n echo-pool rollout status deploy/echo-pgbouncer --timeout=120s >/dev/null
out=$(client "insert into public.writes(id) values (999999) returning inet_server_addr()")
[[ $out == *"$B_IP"* ]] && ok "재시작 뒤에도 B($B_IP) 로 씀" || bad "재시작 뒤 B 가 아님: $out"
[[ $(pg echo-data -c "select count(*) from public.writes where id=999999") == 0 ]] && ok "A 에는 안 들어감" || bad "A 에 들어감"

echo "== 5. NetworkPolicy: DB 직접 접속 차단 (aws-tokyo/40-networkpolicy.yaml)"
k apply -f - < aws-tokyo/40-networkpolicy.yaml >/dev/null; sleep 5
direct=$(k -n app run "d$RANDOM" --rm -i --restart=Never --image=postgres:17-alpine --image-pull-policy=Never --quiet -- \
  sh -c "PGCONNECT_TIMEOUT=5 psql -X -tA 'postgresql://app_rw:$APP@echo-pg.echo-data.svc.cluster.local:5432/app?sslmode=require' -c 'select 1' 2>&1" 2>&1)
[[ $direct != 1 ]] && ok "app 네임스페이스 → A:5432 직접 접속 막힘" || bad "직접 접속이 됨"
via=$(k -n echo-pool exec deploy/echo-pgbouncer -c admin -- sh -c "PGCONNECT_TIMEOUT=5 psql -X -tA 'postgresql://app_rw:$APP@echo-pg.echo-data.svc.cluster.local:5432/app?sslmode=require' -c 'select 1'" 2>&1)
[[ $via == 1 ]] && ok "echo-pool → A:5432 는 됨" || bad "echo-pool 에서 막힘: $via"
[[ $(pg echo-data -c "select 1") == 1 ]] && ok "kubectl exec 로 부르는 psql(컷오버 스크립트 방식)은 그대로" || bad "exec psql 이 막힘"

echo
echo "결과: 통과 $pass · 실패 $fail   (DNS 반영 ${dns_s:-?}초 · 쓰기 정지 ${pause_s:-?}초)"
[[ $fail == 0 ]]
