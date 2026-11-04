#!/usr/bin/env bash
# 진입점 두 곳 페일오버 측정 (인프라 5.1): 대표 주소를 Cloudflare 경유(https)로 초당 RATE 번 호출해 실패 구간을 찍는다.
# 사용: HOST=demo-y6cz3jrc.echoport.uk DURATION=120 entrypoint/scripts/failover-probe.sh
#   다른 창에서 주 VM 을 멈춘다:  gcloud compute instances stop echo-dev-entry --zone asia-northeast3-a --configuration=echo
#   끝나면 다시 켠다:            gcloud compute instances start echo-dev-entry --zone asia-northeast3-a --configuration=echo
set -uo pipefail
HOST="${HOST:?HOST=<대표 주소>}"; DURATION="${DURATION:-120}"; RATE="${RATE:-4}"; PATH_="${PROBE_PATH:-/healthz}"
interval=$(echo "scale=4; 1/$RATE" | bc -l); end=$(( $(date +%s) + DURATION ))
ok=0; fail=0; first_fail=""; last_fail=""
while [ "$(date +%s)" -lt "$end" ]; do
  t=$(date +%s.%N); code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "https://$HOST$PATH_")
  if [[ "$code" == 2* ]]; then ok=$((ok+1)); else
    fail=$((fail+1)); [ -z "$first_fail" ] && first_fail=$t; last_fail=$t
    echo "$(date -r "${t%.*}" +%T) non-2xx: $code" >&2
  fi
  sleep "$interval"
done
echo "probe ok=$ok fail=$fail (rate=$RATE/s, ${DURATION}s, $HOST$PATH_)"
if [ -n "$first_fail" ]; then printf '실패 구간: %.1f초 (첫 실패 → 마지막 실패)\n' "$(echo "$last_fail - $first_fail" | bc -l)"; else echo "실패 구간: 0초"; fi
