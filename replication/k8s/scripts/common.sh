#!/usr/bin/env bash
# 두 클러스터의 Postgres·PgBouncer 파드에 kubectl exec 로 psql 을 보내는 공통 함수. 비밀번호는 파드 env(Secret)에서만 읽는다(여기 출력 없음).
# 주의: psql 변수(:'conn')는 -c 문자열에서는 치환되지 않는다(서버로 그대로 간다). CREATE SUBSCRIPTION 처럼 변수를 쓰는 SQL 은 echo … | psql 로 stdin 에 넣는다.
set -euo pipefail
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
A_CTX="${A_CTX:-echo-dev-eks}"
B_CTX="${B_CTX:-gke_team-echo-final_asia-northeast3-a_echo-dev-gke}"
NS="${NS:-echo-data}"

# psql on Postgres pod: pg <A|B> "<sql>" [-v var=val ...]
pg() { local side=$1; shift; local ctx; [[ $side == A ]] && ctx=$A_CTX || ctx=$B_CTX
  kubectl --context "$ctx" -n "$NS" exec -i echo-pg-0 -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d app -tA "$@"; }
# pgbouncer admin console: pgb <A|B> "<cmd>". pgbouncer 이미지에 psql 이 없어 Postgres 파드에서 보낸다(비밀번호 = 파드 env PGB_AUTH_PASSWORD).
pgb() { local side=$1; local cmd=$2; local ctx; [[ $side == A ]] && ctx=$A_CTX || ctx=$B_CTX
  kubectl --context "$ctx" -n "$NS" exec -i echo-pg-0 -c postgres -- sh -c \
    'PGPASSWORD=$PGB_AUTH_PASSWORD psql -X -h echo-pgbouncer -p 6432 -U pgbouncer_auth -d pgbouncer -tAc "$0"' "$cmd"; }
# pgbouncer ini 의 백엔드 host 를 바꾸고 RELOAD: repoint <A|B> <new_host>
repoint() { local side=$1; local host=$2; local ctx; [[ $side == A ]] && ctx=$A_CTX || ctx=$B_CTX
  kubectl --context "$ctx" -n "$NS" exec -i deploy/echo-pgbouncer -- sh -c \
    'sed -i "s/^app = host=[^ ]*/app = host=$0/" /etc/pgbouncer/pgbouncer.ini && grep "^app = " /etc/pgbouncer/pgbouncer.ini' "$host" >/dev/null
  pgb "$side" "RELOAD;" >/dev/null; }
now() { date +%s.%N; }
