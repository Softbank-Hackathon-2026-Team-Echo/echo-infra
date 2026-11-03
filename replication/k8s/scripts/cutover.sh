#!/usr/bin/env bash
# 컷오버 A→B (SPEC infra-7 §4-3): 두 PgBouncer PAUSE → B 가 A 를 따라잡을 때까지 → B 시퀀스 맞춤 → 정방향 구독 중지
#   → 역방향 구독(B→A, copy_data=false) 을 **쓰기 정지 창 안에서** 만든다(창 안엔 쓰기가 없어 빈틈이 없다)
#   → 두 PgBouncer 백엔드를 B 로 → RESUME. 쓰기 정지 시간(PAUSE→RESUME)을 측정값 그대로 찍는다.
# 사용: B_HOST=<gcp-seoul/30-expose.yaml 의 LB IP> replication/k8s/scripts/cutover.sh
#   B_LOCAL(기본 echo-pg: B 클러스터 안 PgBouncer 가 보는 B 주소), A 쪽 PgBouncer 는 B_HOST(인터넷·TLS) 로 간다.
source "$(dirname "$0")/common.sh"
: "${B_HOST:?B_HOST=<gcp-seoul/30-expose.yaml 의 EXTERNAL-IP>}"
B_LOCAL="${B_LOCAL:-echo-pg}"
t0=$(now)
pgb A "PAUSE app;" >/dev/null; pgb B "PAUSE app;" >/dev/null
tp=$(now)
# B 가 A 를 따라잡음: A 의 replay_lsn == current_wal_lsn (최대 10초)
for i in $(seq 1 100); do
  behind=$(pg A -c "SELECT COALESCE(MIN(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), -1) FROM pg_stat_replication WHERE application_name='echo_sub';")
  [[ "$behind" == "0" ]] && break; sleep 0.1
done
tc=$(now)
maxA=$(pg A -c "SELECT COALESCE(max(n),0) FROM demo.seq_write;"); maxB=$(pg B -c "SELECT COALESCE(max(n),0) FROM demo.seq_write;")
[[ "$maxA" == "$maxB" ]] || { echo "따라잡기 실패: A max(n)=$maxA B max(n)=$maxB → RESUME 하고 중단"; pgb A "RESUME app;"; pgb B "RESUME app;"; exit 1; }
pg B -c "SELECT setval(pg_get_serial_sequence('demo.seq_write','id'), (SELECT COALESCE(max(id),0) FROM demo.seq_write)+1000);" >/dev/null
pg B -c "ALTER SUBSCRIPTION echo_sub DISABLE;" >/dev/null
# 역방향 B→A: A 가 B 를 구독 (copy_data=false: 지금까지의 행은 이미 A 에 있다)
kubectl --context "$A_CTX" -n "$NS" exec -i echo-pg-0 -c postgres -- sh -c \
  'psql -X -v ON_ERROR_STOP=1 -U postgres -d app -v conn="host=$0 port=5432 dbname=app user=repl_user password=$REPL_PASSWORD sslmode=require" \
   -c "CREATE SUBSCRIPTION echo_sub_rev CONNECTION :'"'"'conn'"'"' PUBLICATION echo_pub WITH (copy_data = false);"' "$B_HOST" >/dev/null
repoint B "$B_LOCAL"; repoint A "$B_HOST"
pgb B "RESUME app;" >/dev/null; pgb A "RESUME app;" >/dev/null
t1=$(now)
printf '컷오버 완료. max(n)=%s\n 쓰기 정지 시간(PAUSE→RESUME): %.3fs\n   ├ PAUSE 드레인: %.3fs\n   ├ 따라잡기: %.3fs\n   └ 시퀀스·역방향 구독·repoint·RESUME: %.3fs\n' \
  "$maxA" "$(echo "$t1-$t0" | bc -l)" "$(echo "$tp-$t0" | bc -l)" "$(echo "$tc-$tp" | bc -l)" "$(echo "$t1-$tc" | bc -l)"
