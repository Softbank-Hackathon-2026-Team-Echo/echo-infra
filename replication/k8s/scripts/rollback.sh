#!/usr/bin/env bash
# 롤백 B→A (SPEC infra-8): cutover.sh 의 거울. 두 PgBouncer PAUSE → A 가 B 를 따라잡음 → A 시퀀스 → 역방향 구독 중지
#   → 정방향 구독(A→B, copy_data=false) 을 창 안에서 다시 켬 → 백엔드를 A 로 → RESUME. 복귀 시간을 찍는다.
# 사용: A_HOST=<aws-tokyo/30-expose.yaml 의 NLB DNS> replication/k8s/scripts/rollback.sh
source "$(dirname "$0")/common.sh"
: "${A_HOST:?A_HOST=<aws-tokyo/30-expose.yaml 의 NLB DNS>}"
A_LOCAL="${A_LOCAL:-echo-pg}"
t0=$(now)
pgb A "PAUSE app;" >/dev/null; pgb B "PAUSE app;" >/dev/null
tp=$(now)
for i in $(seq 1 100); do
  behind=$(pg B -c "SELECT COALESCE(MIN(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), -1) FROM pg_stat_replication WHERE application_name='echo_sub_rev';")
  [[ "$behind" == "0" ]] && break; sleep 0.1
done
tc=$(now)
maxA=$(pg A -c "SELECT COALESCE(max(n),0) FROM demo.seq_write;"); maxB=$(pg B -c "SELECT COALESCE(max(n),0) FROM demo.seq_write;")
[[ "$maxA" == "$maxB" ]] || { echo "따라잡기 실패: A max(n)=$maxA B max(n)=$maxB → RESUME 하고 중단"; pgb A "RESUME app;"; pgb B "RESUME app;"; exit 1; }
pg A -c "SELECT setval(pg_get_serial_sequence('demo.seq_write','id'), (SELECT COALESCE(max(id),0) FROM demo.seq_write)+1000);" >/dev/null
pg A -c "ALTER SUBSCRIPTION echo_sub_rev DISABLE;" >/dev/null
pg B -c "DROP SUBSCRIPTION IF EXISTS echo_sub;" >/dev/null
kubectl --context "$B_CTX" -n "$NS" exec -i echo-pg-0 -c postgres -- sh -c \
  'psql -X -v ON_ERROR_STOP=1 -U postgres -d app -v conn="host=$0 port=5432 dbname=app user=repl_user password=$REPL_PASSWORD sslmode=require" \
   -c "CREATE SUBSCRIPTION echo_sub CONNECTION :'"'"'conn'"'"' PUBLICATION echo_pub WITH (copy_data = false);"' "$A_HOST" >/dev/null
pg A -c "DROP SUBSCRIPTION IF EXISTS echo_sub_rev;" >/dev/null
repoint A "$A_LOCAL"; repoint B "$A_HOST"
pgb A "RESUME app;" >/dev/null; pgb B "RESUME app;" >/dev/null
t1=$(now)
printf '롤백 완료. max(n)=%s\n 복귀 시간(PAUSE→RESUME): %.3fs\n   ├ PAUSE 드레인: %.3fs\n   ├ 따라잡기: %.3fs\n   └ 시퀀스·정방향 구독·repoint·RESUME: %.3fs\n' \
  "$maxB" "$(echo "$t1-$t0" | bc -l)" "$(echo "$tp-$t0" | bc -l)" "$(echo "$tc-$tp" | bc -l)" "$(echo "$t1-$tc" | bc -l)"
