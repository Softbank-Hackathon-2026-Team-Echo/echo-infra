#!/usr/bin/env bash
# 승격 뒤 A 다시 맞추기 (SPEC infra-12.3): 살아난 A 를 B 의 사본으로 되돌린다. 사람이 상태를 보고 돌린다(자동 실행하지 않는다).
#   A PgBouncer 백엔드를 B 로(도쿄 앱 쓰기도 B 로) → A 에만 남은 장부 행을 세어 기록 → B 의 옛 구독 echo_sub 정리(A 의 슬롯도 지움)
#   → A 의 복제 대상 표를 비움 → A 가 B 를 구독(echo_sub_rev, copy_data=true) → 초기 복사 끝날 때까지 기다림.
#   끝나면 컷오버 뒤와 같은 상태다(B 쓰기 담당, A 사본). 그 뒤 rollback.sh 로 A 복귀를 할 수 있다.
# 사용: B_HOST=<B LB IP> replication/k8s/scripts/resync-a.sh
# 주의: A 에만 있던 행(승격 전 B 로 복제되지 못한 쓰기)은 지워진다. 지우기 전 개수와 n 목록을 출력한다.
source "$(dirname "$0")/common.sh"
: "${B_HOST:?B_HOST=<gcp-seoul/30-expose.yaml 의 EXTERNAL-IP>}"
a_reachable || { echo "[중단] A 에 아직 닿지 않는다 — 바뀐 것 없음" >&2; exit 1; }
s=$(b_side_state)
[[ $s == WRITER ]] || { echo "[중단] B 가 쓰기 담당이 아니다($s) — 승격 뒤에만 쓴다" >&2; exit 1; }
if [[ $(sub_enabled A echo_sub_rev) == 1 ]]; then echo "[건너뜀] A 가 이미 B 를 따라간다(echo_sub_rev)"; exit 0; fi

echo "[1] A PgBouncer 를 B 로 (도쿄 쪽 쓰기도 B 로 간다)"
pgb A "PAUSE app;" >/dev/null || true
repoint A "$B_HOST"
pgb A "RESUME app;" >/dev/null || true

echo "[2] A 에만 남은 장부 행"
b_ns=$(pg B -c "SELECT COALESCE(string_agg(n::text, ','), '') FROM demo.seq_write;")
lost=$(pg A -c "SELECT COALESCE(string_agg(n::text, ',' ORDER BY n), '') FROM demo.seq_write WHERE n <> ALL ('{${b_ns}}'::bigint[]);")
lost_count=0; [[ -n $lost ]] && lost_count=$(tr ',' '\n' <<<"$lost" | wc -l | tr -d ' ')
echo "    ${lost_count}건 (n: ${lost:-없음}) — 승격 전에 B 로 복제되지 못한 쓰기. 지금 지운다"

echo "[3] B 의 옛 구독 echo_sub 정리 (A 의 슬롯 echo_sub 도 지운다)"
pg B -c "DROP SUBSCRIPTION IF EXISTS echo_sub;" >/dev/null

echo "[4] A 의 복제 대상 표를 비운다"
tables=$(pg B -c "SELECT string_agg(format('%I.%I', schemaname, tablename), ', ') FROM pg_publication_tables WHERE pubname = 'echo_pub';")
pg A <<<"$OPS_DDL" >/dev/null
pg A -c "TRUNCATE $tables;" >/dev/null

echo "[5] A 가 B 를 구독 (copy_data=true)"
kubectl --context "$A_CTX" -n "$NS" exec -i echo-pg-0 -c postgres -- sh -c \
  'echo "CREATE SUBSCRIPTION echo_sub_rev CONNECTION :'"'"'conn'"'"' PUBLICATION echo_pub WITH (copy_data = true);" | \
   psql -X -v ON_ERROR_STOP=1 -U postgres -d app -v conn="host=$0 port=5432 dbname=app user=repl_user password=$REPL_PASSWORD sslmode=require"' "$B_HOST" >/dev/null
for i in $(seq 1 120); do
  pending=$(pg A -c "SELECT count(*) FROM pg_subscription_rel r JOIN pg_subscription s ON s.oid = r.srsubid WHERE s.subname = 'echo_sub_rev' AND r.srsubstate <> 'r';")
  [[ $pending == 0 ]] && break; sleep 0.5
done
[[ $pending == 0 ]] || { echo "[주의] 초기 복사가 60초 안에 끝나지 않았다(남은 표 $pending). lag.sh 로 확인" >&2; exit 2; }
maxA=$(pg A -c "SELECT COALESCE(max(n),0) FROM demo.seq_write;"); maxB=$(pg B -c "SELECT COALESCE(max(n),0) FROM demo.seq_write;")
echo "다시 맞추기 완료. A 는 B 의 사본이다(max(n) A=$maxA B=$maxB). 지워진 A 전용 행 ${lost_count}건"
echo " 상태: $(writer_side)   A 로 복귀하려면: A_HOST=… replication/k8s/scripts/rollback.sh"
