#!/usr/bin/env bash
# 리허설용 쓰기 부하: 진입점(대표 주소)으로 POST /api/writes 를 초당 RATE 건 보낸다. 실패(비 2xx)는 그대로 세어 보여 준다.
# 사용: RATE=10 DURATION=120 replication/k8s/scripts/writer.sh   (기본 10 rps, 60초)
set -uo pipefail
ENTRY="${ENTRY:-http://34.158.202.103}"; HOST="${HOST:-shop.echoport.uk}"
RATE="${RATE:-10}"; DURATION="${DURATION:-60}"
interval=$(echo "scale=4; 1/$RATE" | bc -l); end=$(( $(date +%s) + DURATION )); ok=0; fail=0
while [ "$(date +%s)" -lt "$end" ]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST -H "Host: $HOST" -H 'Content-Type: application/json' -d '{}' "$ENTRY/api/writes")
  if [[ "$code" == 2* ]]; then ok=$((ok+1)); else fail=$((fail+1)); echo "$(date +%T) non-2xx: $code" >&2; fi
  sleep "$interval"
done
echo "writes ok=$ok fail=$fail (rate=$RATE/s, ${DURATION}s)"
