#!/usr/bin/env bash
# 롤백 B→A (SPEC infra-8): cutover.sh 의 거울. 두 PgBouncer PAUSE → A 가 B 를 따라잡음 → A 시퀀스 → 역방향 구독 중지
#   → 정방향 구독(A→B, copy_data=false) 을 창 안에서 다시 켬 → 백엔드를 A 로 → RESUME. 복귀 시간을 찍는다.
# 사용: A_HOST=<aws-tokyo/30-expose.yaml 의 NLB DNS> [PLAN_ID=<복귀 계획 uuid>] replication/k8s/scripts/rollback.sh
#   다시 돌려도 안전하다: 쓰기 담당이 이미 A 거나 같은 PLAN_ID 기록이 있으면 아무것도 하지 않는다(인프라 12.1).
#   종료 코드 0 끝남 · 1 바뀐 것 없음 · 2 부분 상태(common.sh guard_on_error).
source "$(dirname "$0")/common.sh"
: "${A_HOST:?A_HOST=<aws-tokyo/30-expose.yaml 의 NLB DNS>}"
guard_install
plan_id_check
ops_table_ensure   # 결과 표가 양쪽에 있는지(쓰기 정지 창 밖에서). 인프라 7.2
preflight ROLLBACK B A   # 이미 A 가 쓰기 담당이거나 이 계획 기록이 있으면 여기서 끝(인프라 12.1)
window_prep A B          # 풀 방식 판정·A 토큰을 창 밖에서 한 번(#133)
GUARD_PHASE=paused
t0=$(now); WINDOW_T0=$t0
pgb A "PAUSE app;" >/dev/null; lap "A PAUSE"
pgb B "PAUSE app;" >/dev/null; lap "B PAUSE"
tp=$(now)
for i in $(seq 1 100); do
  behind=$(pg B -c "SELECT COALESCE(MIN(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)), -1) FROM pg_stat_replication WHERE application_name='echo_sub_rev';")
  [[ "$behind" == "0" ]] && break; sleep 0.1
done
tc=$(now); lap "따라잡기(확인 ${i}회)"
maxA=$(pg A -c "SELECT COALESCE(max(n),0) FROM demo.seq_write;"); maxB=$(pg B -c "SELECT COALESCE(max(n),0) FROM demo.seq_write;")
[[ "$maxA" == "$maxB" ]] || { echo "따라잡기 실패: A max(n)=$maxA B max(n)=$maxB → RESUME 하고 중단"; pgb A "RESUME app;"; pgb B "RESUME app;"; exit 1; }
lap "장부 대조 A=B max(n)=$maxB"
pg A -c "SELECT setval(pg_get_serial_sequence('demo.seq_write','id'), (SELECT COALESCE(max(id),0) FROM demo.seq_write)+1000);" >/dev/null
lap "A 시퀀스 +1000"
GUARD_PHASE=switching   # 여기부터 실패하면 RESUME 하지 않는다(옛 쪽에 쓰면 A 로 복제되지 않는다)
pg A -c "ALTER SUBSCRIPTION echo_sub_rev DISABLE;" >/dev/null; lap "A 역방향 구독 끔"
pg B -c "DROP SUBSCRIPTION IF EXISTS echo_sub;" >/dev/null; lap "B 옛 정방향 구독 지움"
kubectl --context "$B_CTX" -n "$NS" exec -i echo-pg-0 -c postgres -- sh -c \
  'echo "CREATE SUBSCRIPTION echo_sub CONNECTION :'"'"'conn'"'"' PUBLICATION echo_pub WITH (copy_data = false);" | \
   psql -X -v ON_ERROR_STOP=1 -U postgres -d app -v conn="host=$0 port=5432 dbname=app user=repl_user password=$REPL_PASSWORD sslmode=require"' "$A_HOST" >/dev/null
lap "B 정방향 구독 만듦"
pg A -c "DROP SUBSCRIPTION IF EXISTS echo_sub_rev;" >/dev/null; lap "A 역방향 구독 지움"
repoints A "$A_LOCAL" B "$A_HOST"   # 두 쪽 표지판을 바꾸고 반영 대기는 한 번
pgb A "RESUME app;" >/dev/null; lap "A RESUME"
pgb B "RESUME app;" >/dev/null; lap "B RESUME"
t1=$(now)
GUARD_PHASE=done; trap - ERR
printf '롤백 완료. max(n)=%s\n 복귀 시간(PAUSE→RESUME): %.3fs\n   ├ PAUSE 드레인: %.3fs\n   ├ 따라잡기: %.3fs\n   └ 시퀀스·정방향 구독·repoint·RESUME: %.3fs\n' \
  "$maxB" "$(echo "$t1-$t0" | bc -l)" "$(echo "$tp-$t0" | bc -l)" "$(echo "$tc-$tp" | bc -l)" "$(echo "$t1-$tc" | bc -l)"
record_run ROLLBACK B A "$t0" "$tp" "$tc" "$t1"   # RESUME 뒤 A 에 결과 한 줄(echo-was 가 읽음)
persist_after_switch A B   # 파드가 다시 떠도 새 백엔드가 유지되게(쓰기 정지 창 밖)
