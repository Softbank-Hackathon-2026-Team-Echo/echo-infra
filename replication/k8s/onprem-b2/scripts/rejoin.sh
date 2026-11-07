#!/usr/bin/env bash
# failover.sh 뒤 원래대로: 온프레 = 원본, B2 = 복제본 (인프라 18). failover 와 같은 TARGET 으로 돌린다.
# 승격 뒤 B2 에 쓴 행은 버린다(시험용). 온프레가 다시 닿아야 한다(simulate-down.sh up 뒤).
#   1) GKE 대기 앱 0  2) 옛 구독 지우기(슬롯은 온프레에서 직접 지움)  3) B2 표 비우기
#   4) 구독 다시 만들기(초기 복사)  5) 온프레·GCP·AWS 행 수·md5 비교
source "$(dirname "$0")/common.sh"
[[ ${CONFIRM:-} == yes ]] || { echo "$TLABEL B2 의 승격 뒤 데이터를 버리고 다시 복제한다. 진행하려면 CONFIRM=yes $0" >&2; exit 2; }

kubectl --context "$TARGET_CTX" -n "$NS" scale deploy demo-app --replicas=0 >/dev/null

b2 "$TARGET_CTX" -c "ALTER SUBSCRIPTION $SUB DISABLE;" >/dev/null 2>&1 || true
b2 "$TARGET_CTX" -c "ALTER SUBSCRIPTION $SUB SET (slot_name = NONE);" >/dev/null 2>&1 || true
b2 "$TARGET_CTX" -c "DROP SUBSCRIPTION IF EXISTS $SUB;" >/dev/null
onprem_sh <<EOF
set -e
# 끊긴 동안 남은 walsender 가 슬롯을 잡고 있을 수 있어 먼저 끊는다.
k3s kubectl -n echo-demo exec demo-db-0 -- psql -XAt -U demo -d demo -c \
  "select pg_terminate_backend(active_pid) from pg_replication_slots where slot_name='$SUB' and active" >/dev/null
sleep 1
k3s kubectl -n echo-demo exec demo-db-0 -- psql -XAt -U demo -d demo -c \
  "select pg_drop_replication_slot(slot_name) from pg_replication_slots where slot_name='$SUB'" >/dev/null
echo "온프레 슬롯 $SUB 정리"
EOF

b2 "$TARGET_CTX" -c "TRUNCATE demo.seq_write;" >/dev/null
kubectl --context "$TARGET_CTX" -n "$NS" exec -i onprem-pg-0 -c postgres -- bash -s <<EOF
psql -X -q -v ON_ERROR_STOP=1 -U demo -d demo -c "CREATE SUBSCRIPTION $SUB CONNECTION 'host=\$SRC_HOST port=5432 dbname=demo user=repl_onprem password=\$SRC_REPL_PASSWORD sslmode=require' PUBLICATION echo_onprem_pub;"
EOF

for _ in $(seq 1 30); do
  st=$(b2 "$TARGET_CTX" -c "select string_agg(srsubstate::text,'') from pg_subscription_rel") || true
  [[ $st == r ]] && break; sleep 2
done
echo "구독 상태: ${st:-?} (r = 복제 중)"

o=$(onprem_sh <<EOF
k3s kubectl -n echo-demo exec demo-db-0 -- psql -XAt -U demo -d demo -c "$SNAP_SQL"
EOF
)
echo "온프레 : $o"
echo "$TLABEL B2 : $(b2 "$TARGET_CTX" -c "$SNAP_SQL")"
echo "$WITNESS B2 : $(b2 "$WITNESS_CTX" -c "$SNAP_SQL")"
