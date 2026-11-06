#!/usr/bin/env bash
# 진입점 Envoy + 요청 기록(journal) 로컬 시험 (인프라 12.4). 실제 entrypoint/docker-compose.yml 에 업스트림 stub 만 덧붙인다.
# 확인: 꺼짐이면 기록 0 · 켜면 쓰기만 기록 · hold 면 쓰기 429 + Retry-After · journal 이 죽어도 쓰기 통과 · 지연 p95
# 사용: entrypoint/journal/tests/envoy-test.sh   (Docker 필요. KEEP=1 이면 남긴다)
set -uo pipefail
cd "$(dirname "$0")/../.."
P=echo-journal-test
export WEIGHTS_TOKEN=wt GRAFANA_ADMIN_PASSWORD=unused JOURNAL_TOKEN=jt JOURNAL_ENABLED=true \
  UPSTREAMS=aws=stub:8080,gcp=stub:8080 ENTRY_HTTP_PORT=18080 WEIGHTS_API_PORT=18081 JOURNAL_ADMIN_PORT=18082
DC=(docker compose -p $P -f docker-compose.yml -f journal/tests/compose.stub.yml)
E=http://127.0.0.1:18080 J=http://127.0.0.1:18082 A=http://127.0.0.1:9901
pass=0 fail=0
ok()  { echo "  ✅ $*"; pass=$((pass+1)); }
bad() { echo "  ❌ $*"; fail=$((fail+1)); }
check() { [[ $3 == "$2" ]] && ok "$1 ($3)" || bad "$1: 기대 '$2', 실제 '$3'"; }
code() { curl -s -o /dev/null -w '%{http_code}' -H 'Host: demo.echoport.uk' "$@"; }
jcount() { curl -s -H "Authorization: Bearer jt" "$J/status" | python -c 'import json,sys; print(json.load(sys.stdin)["count"])'; }
runtime() { curl -s -X POST "$A/runtime_modify?journal.enabled=$1" >/dev/null; }
p95() {  # p95 <n> → 쓰기 n 번의 p95(ms)
  for _ in $(seq 1 "$1"); do curl -s -o /dev/null -w '%{time_total}\n' -X POST -H 'Host: demo.echoport.uk' "$E/api/writes"; done |
    sort -n | awk '{a[NR]=$1} END {i=int(NR*0.95); if(i<1)i=1; printf "%.1f", a[i]*1000}'; }
cleanup() { [[ ${KEEP:-} == 1 ]] || "${DC[@]}" down -v >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 준비: journal · weights-api · envoy · stub"
"${DC[@]}" up -d --build --wait journal weights-api envoy stub >/dev/null 2>&1 || { "${DC[@]}" ps; "${DC[@]}" logs --tail 20 envoy; exit 1; }
for i in $(seq 1 30); do [[ $(code "$E/healthz") == 200 ]] && break; sleep 1; done
check "진입점 → stub" 200 "$(code "$E/healthz")"

echo "== 1. 필터 꺼짐(기본 journal.enabled=0): 쓰기는 지나가고 기록 0"
check "POST" 201 "$(code -X POST "$E/api/writes" -d '{}')"
check "기록 수" 0 "$(jcount)"
off_p95=$(p95 30)

echo "== 2. 필터 켬: 쓰기만 기록, 읽기는 기록 안 함, Envoy x-request-id 가 키"
runtime 100
check "POST" 201 "$(code -X POST -H 'Content-Type: application/json' "$E/api/writes" -d '{"a":1}')"
check "GET" 200 "$(code "$E/api/writes/summary")"
check "기록 수" 1 "$(jcount)"
curl -s -H "Authorization: Bearer jt" "$J/entries?since=0" | python -c '
import json,sys,base64; e=json.load(sys.stdin)["entries"][0]
print("method", e["method"]); print("path", e["path"]); print("host", e["host"]); print("key", "yes" if e["requestId"] else "no"); print("body", base64.b64decode(e["body"]).decode())' > /tmp/e.txt
check "기록 메서드" POST "$(sed -n 's/^method //p' /tmp/e.txt)"
check "기록 경로" /api/writes "$(sed -n 's/^path //p' /tmp/e.txt)"
check "기록 Host" demo.echoport.uk "$(sed -n 's/^host //p' /tmp/e.txt)"
check "멱등 키(x-request-id) 있음" yes "$(sed -n 's/^key //p' /tmp/e.txt)"
check "본문" '{"a":1}' "$(sed -n 's/^body //p' /tmp/e.txt)"
code -X POST -H 'Idempotency-Key: my-key' "$E/api/writes" -d '{}' >/dev/null
check "Idempotency-Key 가 우선" my-key "$(curl -s -H 'Authorization: Bearer jt' "$J/entries?since=0" | python -c 'import json,sys; print(json.load(sys.stdin)["entries"][-1]["requestId"])')"
on_p95=$(p95 30)

echo "== 3. hold: 쓰기 429 + Retry-After, 읽기는 통과"
curl -s -X POST -H "Authorization: Bearer jt" "$J/hold" >/dev/null
hdr=$(curl -s -D - -o /dev/null -X POST -H 'Host: demo.echoport.uk' "$E/api/writes" -d '{}')
check "hold 중 POST" 429 "$(awk 'NR==1{print $2}' <<<"$hdr")"
check "Retry-After" 2 "$(grep -i '^retry-after:' <<<"$hdr" | tr -d '\r' | awk '{print $2}')"
check "hold 중 GET" 200 "$(code "$E/api/writes/summary")"
curl -s -X POST -H "Authorization: Bearer jt" "$J/release" >/dev/null
check "release 뒤 POST" 201 "$(code -X POST "$E/api/writes" -d '{}')"

echo "== 4. 확인 포트(8081)는 밖에 열리지 않는다"
check "호스트에서 8081" 000 "$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/check/x -X POST)"

echo "== 5. journal 정지: 쓰기 통과(fail-open)"
"${DC[@]}" stop journal >/dev/null 2>&1
check "journal 없이 POST" 201 "$(code -X POST "$E/api/writes" -d '{}')"
"${DC[@]}" start journal >/dev/null 2>&1

echo "== 6. 지연 (쓰기 30번 p95, 같은 PC 안)"
echo "  필터 꺼짐 ${off_p95}ms · 켬 ${on_p95}ms"

echo; echo "결과: 통과 $pass · 실패 $fail"
[[ $fail == 0 ]]
