#!/usr/bin/env bash
# 원본 장애 승격 (SPEC infra-12.3): A(도쿄)에 닿지 않을 때 B(서울)만으로 쓰기 담당을 B 로 옮긴다.
#   B PgBouncer PAUSE → B 시퀀스 맞춤 → B echo_sub DISABLE → B PgBouncer 백엔드를 B 로 → RESUME → 결과 기록(mode=PROMOTE).
#   A 가 죽어 있으므로 따라잡기·역방향 구독은 없다. A 가 살아나면 사람이 resync-a.sh 로 A 를 B 의 사본으로 다시 맞춘다.
# 사용: [PLAN_ID=<이전 계획 uuid>] replication/k8s/scripts/promote.sh
#   보통은 ALLOW_PROMOTE=true cutover.sh 가 A 에 닿지 않을 때 이 스크립트로 넘어온다.
#   A 에 닿으면 거부한다(쓰기 담당이 둘이 되지 않게). 정말 필요하면 FORCE_PROMOTE=1.
#   종료 코드 0 끝남 · 1 바뀐 것 없음 · 2 부분 상태(common.sh guard_on_error).
# 잃었을 수 있는 범위: B 가 A 에서 마지막으로 받은 시각(없으면 장부 마지막 쓰기 시각)부터 PAUSE 까지를 rpo_estimate_ms 로 남긴다.
#   A 가 죽은 뒤에는 A 에 쓸 수 없으므로 실제로 잃은 범위는 이 값보다 작거나 같다(상한).
source "$(dirname "$0")/common.sh"
GUARD_SIDES=B   # A 에는 닿지 않는다
guard_install
plan_id_check
if a_reachable && [[ ${FORCE_PROMOTE:-} != 1 ]]; then
  echo "[중단] A 에 닿는다 — 승격하지 않는다(쓰기 담당이 둘이 된다). 정상 컷오버는 cutover.sh 를 쓴다" >&2; exit 1
fi
pg B <<<"$OPS_DDL" >/dev/null   # 결과 표·칸을 B 에만(A 에는 닿지 않는다). REFRESH 는 A 연결이 필요해 하지 않는다
s=$(b_side_state)
case $s in
  WRITER)  persist_backend B ;;   # 지난 승격이 ConfigMap 을 못 맞췄으면 여기서 맞춘다
  REPLICA) ;;
  *)       echo "[중단] B 상태를 판단할 수 없다: $s — replication/k8s/README.md '부분 상태 복구'를 따른다" >&2; exit 2 ;;
esac
n=$(plan_runs B CUTOVER)
if [[ $n != 0 ]]; then echo "[건너뜀] ALREADY_DONE: 이 계획($PLAN_ID)의 CUTOVER 기록이 이미 있다"; exit 0; fi
case $s in
  WRITER)  echo "[건너뜀] ALREADY_WRITER: 쓰기 담당이 이미 B 다"; exit 0 ;;
  REPLICA) echo "[확인] A 에 닿지 않는다 → B 를 쓰기 담당으로 올린다" ;;
esac
last=$(pg B -c "SELECT EXTRACT(EPOCH FROM COALESCE((SELECT last_msg_receipt_time FROM pg_stat_subscription WHERE subname = 'echo_sub' AND last_msg_receipt_time IS NOT NULL LIMIT 1), (SELECT max(wrote_at) FROM demo.seq_write)));")
window_prep B   # 풀 방식 판정을 창 밖에서 한 번(#133). A 에는 닿지 않으니 B 만
GUARD_PHASE=paused
t0=$(now); WINDOW_T0=$t0
pgb B "PAUSE app;" >/dev/null; lap "B PAUSE"
tp=$(now)
pg B -c "SELECT setval(pg_get_serial_sequence('demo.seq_write','id'), (SELECT COALESCE(max(id),0) FROM demo.seq_write)+1000);" >/dev/null
lap "B 시퀀스 +1000"
GUARD_PHASE=switching   # 여기부터 실패하면 RESUME 하지 않는다
pg B -c "ALTER SUBSCRIPTION echo_sub DISABLE;" >/dev/null; lap "B 정방향 구독 끔"
repoint B "$B_LOCAL"
pgb B "RESUME app;" >/dev/null; lap "B RESUME"
t1=$(now)
GUARD_PHASE=done; trap - ERR
rpo=NULL; [[ -n $last ]] && rpo=$(printf '%.0f' "$(echo "($t0 - $last) * 1000" | bc -l)")
printf '승격 완료. 쓰기 담당 = B\n 쓰기 정지 시간(PAUSE→RESUME): %.3fs\n 잃었을 수 있는 범위(상한): %s ms\n' "$(echo "$t1-$t0" | bc -l)" "$rpo"
record_run CUTOVER A B "$t0" "$tp" "$tp" "$t1" PROMOTE "$rpo"
persist_after_switch B   # 파드가 다시 떠도 B 백엔드가 유지되게. A 는 닿지 않으니 resync-a.sh 가 맞춘다
echo " A 가 살아나면: A_HOST=… B_HOST=… replication/k8s/scripts/resync-a.sh"
