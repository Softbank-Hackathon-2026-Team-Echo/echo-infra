#!/usr/bin/env bash
# 계획적 롤백 B→A: #7 컷오버를 방향만 바꿔 실행해 무손실로 primary 를 A 로 되돌린다(#8, NFR-05).
# 선행: scripts/reverse.sh 로 역방향 복제 B→A 가 가동 중이어야 한다.
# 측정 방식은 cutover.sh 와 같다 — 임계 구간(PAUSE→RESUME)을 pg_a 안 단일 exec·컨테이너 시계로 잰다.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[1] 역방향 복제 지연 측정 (정지 전, 창 밖)"
lagA=$(docker compose exec -T pg_a psql -tAq -U postgres -d app \
  -c "SELECT COALESCE(round(EXTRACT(EPOCH FROM (now() - last_msg_receipt_time))::numeric,3),0) FROM pg_stat_subscription WHERE subname='sub_rev';" || echo "n/a")
echo "    A 수신 지연 ~ ${lagA}s"

# ── 임계 구간: pg_a 안 단일 exec. cutover.sh 와 같은 방식으로 여기 안에서만 시간을 잰다. ──
out=$(docker compose exec -T pg_a bash -s <<'CRIT'
set -euo pipefail
PGB='host=pgbouncer port=6432 dbname=pgbouncer user=postgres'   # pgbouncer admin
AC='host=pg_a port=5432 dbname=app user=postgres'               # A (복귀 대상)
BC='host=pg_b port=5432 dbname=app user=postgres'               # B (현재 primary)
q(){ psql -tAq "$1" -c "$2"; }

t0=$(date +%s.%N)
q "$PGB" "PAUSE app;" >/dev/null                 # B 로의 쓰기 정지·진행 트랜잭션 드레인
tp=$(date +%s.%N)
maxB=$(q "$BC" "SELECT COALESCE(max(n),0) FROM demo.seq_write;")   # 드레인 후 B 최종값
until [ "$(q "$AC" "SELECT COALESCE(max(n),0) FROM demo.seq_write;")" = "$maxB" ]; do sleep 0.02; done
tc=$(date +%s.%N)                                # A 가 B 를 따라잡음 (역방향 복제)
q "$AC" "SELECT setval(pg_get_serial_sequence('demo.seq_write','id'), (SELECT COALESCE(max(id),0) FROM demo.seq_write)+1000);" >/dev/null  # 시퀀스 맞춤
q "$AC" "ALTER SUBSCRIPTION sub_rev DISABLE;" >/dev/null          # 역방향 구독 중지
sed -i 's/host=pg_b/host=pg_a/' /pgbouncer-conf/pgbouncer.ini     # repoint B→A
q "$PGB" "RELOAD;" >/dev/null
q "$PGB" "RESUME app;" >/dev/null                # 쓰기가 A 로
t1=$(date +%s.%N)

awk "BEGIN{
  printf \"MAXB %s\n\", $maxB
  printf \"RETURN %.3f\n\",  $t1-$t0
  printf \"PAUSE %.3f\n\",   $tp-$t0
  printf \"CATCHUP %.3f\n\", $tc-$tp
  printf \"POST %.3f\n\",    $t1-$tc
}"
CRIT
)
# ── 임계 구간 끝 ─────────────────────────────────────────────────────────────

val(){ printf '%s\n' "$out" | sed -n "s/^$1 //p"; }
rt=$(val RETURN); pz=$(val PAUSE); cu=$(val CATCHUP); po=$(val POST); maxB=$(val MAXB)

echo "[2] PAUSE → A 따라잡기(max(n)=$maxB) → 시퀀스 맞춤 → 구독 중지 → repoint(B→A) → RESUME 완료"
echo "======================================================"
echo " 복귀 시간 (PAUSE→RESUME): ${rt}s"
echo "   ├ PAUSE 드레인:   ${pz}s"
echo "   ├ A 따라잡기:     ${cu}s   (복귀 시점 역방향 복제 지연)"
echo "   └ 시퀀스·repoint·RESUME: ${po}s"
awk "BEGIN{ if ($rt+0 <= 60.0) print \" ✅ 복귀 ≤ 60s (NFR-05)\"; else print \" ⚠️ 복귀 > 60s (NFR-05) — 점검\" }"
echo " 이제 primary = A. scripts/verify.sh pg_a 로 누락·중복 확인."
echo "======================================================"
