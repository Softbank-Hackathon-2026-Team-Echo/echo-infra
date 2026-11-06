#!/usr/bin/env bash
# 요청 기록 재생 종합 시험 (인프라 12.4). 실제 요청 경로 그대로:
#   클라이언트 → 진입점 Envoy(+ journal 기록) → 도쿄 앱 → Postgres A ──논리 복제──▶ Postgres B ← 서울 앱
# 시나리오(solve_split_brain.md): 1·2·3 쓰기 → B 복제 멈춤 → 4·5(A 에만) → A 정지 → 승격 → 6·7·8
#   재생 켬(REPLAY_ON_PROMOTE=true): B = 1~8, 4·5 살아남, 누락 0·중복 0
#   재생 끔(기본, 지금 동작):        B 에 4·5 의 요청이 없음(잃음) — 비교용
# 사용: replication/k8s/scripts/tests/replay-test.sh   (Docker 필요. DEMO_APP_DIR 기본 = 형제 디렉터리 echo-demo-app)
set -uo pipefail
cd "$(dirname "$0")"
T=$PWD; S=$T/..; ROOT=$(cd "$T/../../../.." && pwd)
export STATE=$T/.state-replay PATH="$T/bin:$PATH" MSYS_NO_PATHCONV=1
export A_CTX=test-a B_CTX=test-b A_HOST=echo-t-pg-a B_HOST=echo-t-pg-b
export WEIGHTS_TOKEN=wt GRAFANA_ADMIN_PASSWORD=unused JOURNAL_TOKEN=jt JOURNAL_ENABLED=true \
  UPSTREAMS=aws=app_a:8080,gcp=app_b:8080 ENTRY_HTTP_PORT=18080 WEIGHTS_API_PORT=18081 JOURNAL_ADMIN_PORT=18082
export JOURNAL_URL=http://127.0.0.1:18082 REPLAY_BASE=http://127.0.0.1:18090
# Docker 에 넘기는 경로는 Windows(Git Bash)에서도 읽게 pwd -W 로(MSYS_NO_PATHCONV=1 이라 자동 변환이 없다).
w() { (cd "$1" && { pwd -W 2>/dev/null || pwd; }); }
RW=$(w "$ROOT"); TW=$(w "$T")
export DEMO_APP_DIR="${DEMO_APP_DIR:-$(w "$ROOT/../echo-demo-app")}"
# buildx bake 는 MSYS_NO_PATHCONV=1 과 같이 쓰지 않는다(Git Bash) → compose 명령만 끈다.
DC=(env -u MSYS_NO_PATHCONV docker compose -p echo-replay-test --project-directory "$RW/entrypoint"
    -f "$RW/entrypoint/docker-compose.yml" -f "$TW/docker-compose.yml" -f "$TW/compose.replay.yml")
exec </dev/null
pass=0 fail=0
ok()    { echo "  ✅ $*"; pass=$((pass+1)); }
bad()   { echo "  ❌ $*"; fail=$((fail+1)); }
check() { [[ $3 == "$2" ]] && ok "$1 ($3)" || bad "$1: 기대 '$2', 실제 '$3'"; }
q()     { local c; [[ $1 == A ]] && c=echo-t-pg-a || c=echo-t-pg-b; docker exec -i "$c" psql -X -U postgres -d app -tAq -c "$2"; }
write() { curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Host: demo.echoport.uk' -H "Idempotency-Key: $1" http://127.0.0.1:18080/api/writes; }
wait_n() { local side=$1 n=$2 i; for i in $(seq 1 50); do [[ $(q "$side" "SELECT count(*) FROM demo.seq_write;") == "$n" ]] && return 0; sleep 0.2; done; return 1; }
ledger() { q B "SELECT count(*)||' '||count(DISTINCT n)||' '||COALESCE(min(n),0)||' '||COALESCE(max(n),0) FROM demo.seq_write;"; }
keys()  { q B "SELECT string_agg(request_id, ',' ORDER BY n) FROM demo.seq_write;"; }
cleanup() { [[ ${KEEP:-} == 1 ]] || "${DC[@]}" down -v >/dev/null 2>&1; }
trap cleanup EXIT

setup() {
  "${DC[@]}" down -v >/dev/null 2>&1
  "${DC[@]}" up -d pg_a pg_b >/dev/null 2>&1 || { echo "Postgres 를 띄우지 못했다"; "${DC[@]}" up -d pg_a pg_b; exit 1; }
  for c in echo-t-pg-a echo-t-pg-b; do
    for i in $(seq 1 60); do docker exec "$c" pg_isready -U postgres -d app >/dev/null 2>&1 && break; sleep 0.5; done
  done
  sleep 1
  for side in A B; do q "$side" "CREATE ROLE app_rw LOGIN; CREATE ROLE echo_monitor LOGIN;
    CREATE ROLE repl_user LOGIN REPLICATION PASSWORD 'test'; GRANT pg_read_all_data TO repl_user;" >/dev/null; done
  # 앱이 뜰 때 schema.sql(request_id 칸 포함)을 양쪽에 만든다 → 그 뒤 발행·구독
  local up
  up=$("${DC[@]}" up -d --build --wait journal weights-api envoy app_a app_b 2>&1) || { echo "$up" | tail -15; exit 1; }
  for i in $(seq 1 60); do [[ $(q B "SELECT to_regclass('demo.seq_write') IS NOT NULL AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='seq_write' AND column_name='request_id');") == t &&
    $(q A "SELECT to_regclass('demo.seq_write') IS NOT NULL;") == t ]] && break; sleep 1; done
  q A "CREATE PUBLICATION echo_pub FOR ALL TABLES;" >/dev/null
  rm -rf "$STATE"; mkdir -p "$STATE"; : > "$STATE/pgb.log"
  echo "app = host=echo-pg port=5432 dbname=app" > "$STATE/pgb_A.ini"
  echo "app = host=$A_HOST port=5432 dbname=app" > "$STATE/pgb_B.ini"
  cp "$STATE/pgb_A.ini" "$STATE/cm_A.ini"; cp "$STATE/pgb_B.ini" "$STATE/cm_B.ini"; : > "$STATE/cm.log"
  "$S/subscribe.sh" >/dev/null 2>&1 || { echo "subscribe.sh 실패"; exit 1; }
  curl -s -X POST "127.0.0.1:9901/runtime_modify?journal.enabled=100" >/dev/null   # 진입점 기록 켬
  for i in $(seq 1 30); do [[ $(curl -s -o /dev/null -w '%{http_code}' -H 'Host: demo.echoport.uk' http://127.0.0.1:18080/readyz) == 200 ]] && break; sleep 1; done
}

scenario() {  # scenario <true|false> <PLAN_ID>
  local mode=$1 plan=$2 out rc
  echo "== [재생 $mode] 준비"; setup
  echo "== [재생 $mode] 1·2·3 쓰기 (진입점 경유) → A·B 둘 다"
  for k in w1 w2 w3; do write $k >/dev/null; done
  wait_n B 3 && ok "B 도 3건" || bad "B 복제 안 됨: $(q B 'SELECT count(*) FROM demo.seq_write;')"
  echo "== [재생 $mode] B 복제 멈춤 → 4·5 (A 에만) → A 정지"
  q B "ALTER SUBSCRIPTION echo_sub DISABLE;" >/dev/null; sleep 1
  for k in w4 w5; do write $k >/dev/null; done
  check "A 장부" 5 "$(q A 'SELECT count(*) FROM demo.seq_write;')"
  check "B 장부(4·5 못 받음)" 3 "$(q B 'SELECT count(*) FROM demo.seq_write;')"
  docker stop echo-t-pg-a >/dev/null
  q B "ALTER SUBSCRIPTION echo_sub ENABLE;" >/dev/null   # 평소 상태(구독 켜짐, A 에 못 닿음)
  echo "== [재생 $mode] 승격"
  out=$(REPLAY_ON_PROMOTE=$mode PLAN_ID=$plan "$S/promote-with-replay.sh" 2>&1); rc=$?
  echo "$out" | grep -E '재생|승격|중단|경고|쓰기 정지' | sed 's/^/     │ /'
  check "종료 코드" 0 $rc
  check "진입점 쓰기 막기 풀림" False "$(curl -s -H 'Authorization: Bearer jt' $JOURNAL_URL/status | python -c 'import json,sys; print(json.load(sys.stdin)["hold"])')"
  echo "== [재생 $mode] 트래픽을 서울로(재난 긴급 이전) → 6·7·8"
  curl -s -X PUT -H 'Authorization: Bearer wt' -H 'Content-Type: application/json' -d '{"aws":0,"gcp":100}' http://127.0.0.1:18081/weights >/dev/null
  sleep 1
  for k in w6 w7 w8; do check "쓰기 $k" 201 "$(write $k)"; done
  if [[ $mode == true ]]; then
    check "B 장부 (건수 번호수 min max)" "8 8 1 8" "$(ledger)"
    check "B 의 요청 순서 (4·5 살아남)" "w1,w2,w3,w4,w5,w6,w7,w8" "$(keys)"
    [[ $out == *"새로 들어감 2"* ]] && ok "재생: 4·5 만 새로 들어감" || bad "재생 결과: $(grep '재생:' <<<"$out")"
  else
    check "B 장부 (건수 번호수 min max)" "6 6 1 6" "$(ledger)"
    check "B 의 요청 순서 (4·5 잃음)" "w1,w2,w3,w6,w7,w8" "$(keys)"
  fi
}

scenario true  11111111-1111-4111-8111-111111111111
scenario false 22222222-2222-4222-8222-222222222222

echo; echo "결과: 통과 $pass · 실패 $fail"
[[ $fail == 0 ]]
