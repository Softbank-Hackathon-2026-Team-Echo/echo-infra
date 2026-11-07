#!/usr/bin/env bash
# 온프레 장애 시 GCP B2 를 승격하고 GKE 대기 앱을 켠다 (인프라 18). 온프레에 닿지 않는다고 가정한다.
#   1) 승격 전 B2 상태 기록  2) 구독 끄기  3) 시퀀스 앞당기기(promote.sh 와 같은 +1000)
#   4) 대기 앱 replicas 1  5) 앱으로 쓰기 1건  6) AWS B2(증인)와 비교해 잃은 행 수 출력
# 되돌리기는 rejoin.sh. 확인 없이 돌지 않게 CONFIRM=yes 를 요구한다.
source "$(dirname "$0")/common.sh"
[[ ${CONFIRM:-} == yes ]] || { echo "GCP B2 를 승격한다. 진행하려면 CONFIRM=yes $0" >&2; exit 2; }

t0=$(date +%s.%N)
before=$(b2 "$GCP_CTX" -c "$SNAP_SQL")
last=$(b2 "$GCP_CTX" -c "select coalesce(to_char(last_msg_receipt_time at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'-') from pg_stat_subscription where subname='$SUB'")
echo "승격 전 GCP B2: $before (마지막 수신 $last)"

b2 "$GCP_CTX" -c "ALTER SUBSCRIPTION $SUB DISABLE;" >/dev/null
b2 "$GCP_CTX" -c "SELECT setval(pg_get_serial_sequence('demo.seq_write','id'), (SELECT COALESCE(max(id),0) FROM demo.seq_write)+1000);" >/dev/null
t1=$(date +%s.%N)
echo "B2 승격 완료 ($(printf '%.1f' "$(echo "$t1-$t0" | bc -l)")s)"

kubectl --context "$GCP_CTX" -n "$NS" scale deploy demo-app --replicas=1 >/dev/null
kubectl --context "$GCP_CTX" -n "$NS" rollout status deploy demo-app --timeout=180s >/dev/null
t2=$(date +%s.%N)
PORT=${PORT:-18080}
kubectl --context "$GCP_CTX" -n "$NS" port-forward svc/demo-app "$PORT:80" >/dev/null 2>&1 & pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$PORT/healthz" && break; sleep 0.5; done
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' "http://127.0.0.1:$PORT/api/writes" -d '{}' || true)
echo "GKE 앱 기동 ($(printf '%.1f' "$(echo "$t2-$t1" | bc -l)")s), 쓰기 1건 응답 ${code:-?}"

after=$(b2 "$GCP_CTX" -c "$SNAP_SQL")
witness=$(b2 "$AWS_CTX" -c "$SNAP_SQL" 2>/dev/null || echo "- - -")
read -r _ bmax _ <<<"$before"; read -r wc _ _ <<<"$witness"
echo "승격 후 GCP B2: $after"
echo "AWS B2(온프레 마지막 상태 증인): $witness"
if [[ $wc != - ]]; then
  lost=$(b2 "$AWS_CTX" -c "select count(*) from demo.seq_write where id > $bmax")
  echo "잃은 행 수(온프레에 있었지만 GCP B2 에 오기 전 끊긴 것): $lost"
fi
echo "전체 걸린 시간: $(printf '%.1f' "$(echo "$t2-$t0" | bc -l)")s"
