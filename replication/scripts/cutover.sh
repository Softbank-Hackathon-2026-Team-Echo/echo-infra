#!/usr/bin/env bash
# 무손실 컷오버: 쓰기 정지 → B 따라잡기 → 시퀀스 맞춤 → 구독 중지 → pgbouncer A→B → 재개.
# 쓰기 정지 시간을 측정해 출력한다 (#7 완료 기준, NFR-03).
#
# 측정 창 좁히기: 임계 구간(PAUSE→RESUME)을 '단일 docker exec' 안에서 돌린다.
# 각 단계를 별도 docker exec 로 호출하면 컨테이너 기동(≈0.5~1s)이 매 단계에 붙어
# 쓰기 정지 시간이 부풀려진다(초기 PoC 8.86s). 임계 구간을 pg_a 안 bash 한 번으로 모으면
# 각 단계가 로컬 도커 네트워크 psql(ms)이 되어, 실제 배포(직접 psql·영속 연결)의
# 쓰기 정지 창에 가까운 값이 나온다. t0/t1 도 컨테이너 안 시계로 재 exec 오버헤드를 뺀다.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[1] 복제 지연 측정 (정지 전, 창 밖)"
lagB=$(docker compose exec -T pg_b psql -tAq -U postgres -d app \
  -c "SELECT COALESCE(round(EXTRACT(EPOCH FROM (now() - last_msg_receipt_time))::numeric,3),0) FROM pg_stat_subscription WHERE subname='sub_demo';" || echo "n/a")
echo "    B 수신 지연 ~ ${lagB}s"

# ── 임계 구간: pg_a 안 단일 exec. 여기 안에서만 시간을 잰다. ──────────────────
out=$(docker compose exec -T pg_a bash -s <<'CRIT'
set -euo pipefail
PGB='host=pgbouncer port=6432 dbname=pgbouncer user=postgres'   # pgbouncer admin
AC='host=pg_a port=5432 dbname=app user=postgres'               # A (원본)
BC='host=pg_b port=5432 dbname=app user=postgres'               # B (대상)
q(){ psql -tAq "$1" -c "$2"; }

t0=$(date +%s.%N)
q "$PGB" "PAUSE app;" >/dev/null                 # A 로의 쓰기 정지·진행 트랜잭션 드레인

tp=$(date +%s.%N)
maxA=$(q "$AC" "SELECT COALESCE(max(n),0) FROM demo.seq_write;")   # 드레인 후 A 최종값
until [ "$(q "$BC" "SELECT COALESCE(max(n),0) FROM demo.seq_write;")" = "$maxA" ]; do sleep 0.02; done
tc=$(date +%s.%N)                                # B 가 A 를 따라잡음

q "$BC" "SELECT setval(pg_get_serial_sequence('demo.seq_write','id'), (SELECT COALESCE(max(id),0) FROM demo.seq_write)+1000);" >/dev/null  # 시퀀스 맞춤
q "$BC" "ALTER SUBSCRIPTION sub_demo DISABLE;" >/dev/null         # 구독 중지
sed -i 's/host=pg_a/host=pg_b/' /pgbouncer-conf/pgbouncer.ini     # repoint
q "$PGB" "RELOAD;" >/dev/null
q "$PGB" "RESUME app;" >/dev/null                # 쓰기가 B 로
t1=$(date +%s.%N)

awk "BEGIN{
  printf \"MAXA %s\n\", $maxA
  printf \"WRITESTOP %.3f\n\", $t1-$t0
  printf \"PAUSE %.3f\n\",     $tp-$t0
  printf \"CATCHUP %.3f\n\",   $tc-$tp
  printf \"POST %.3f\n\",      $t1-$tc
}"
CRIT
)
# ── 임계 구간 끝 ─────────────────────────────────────────────────────────────

val(){ printf '%s\n' "$out" | sed -n "s/^$1 //p"; }
ws=$(val WRITESTOP); pz=$(val PAUSE); cu=$(val CATCHUP); po=$(val POST); maxA=$(val MAXA)

echo "[2] PAUSE → 따라잡기(max(n)=$maxA) → 시퀀스 맞춤 → 구독 중지 → repoint → RESUME 완료"
echo "======================================================"
echo " 쓰기 정지 시간 (PAUSE→RESUME): ${ws}s"
echo "   ├ PAUSE 드레인:   ${pz}s"
echo "   ├ B 따라잡기:     ${cu}s   (컷오버 시점 복제 지연 ≈ 이 값, NFR-03 ≤1s)"
echo "   └ 시퀀스·repoint·RESUME: ${po}s"
awk "BEGIN{ if ($ws+0 <= 1.0) print \" ✅ 쓰기 정지 ≤ 1s\"; else print \" ⚠️ 쓰기 정지 > 1s — 점검\";
            if ($cu+0 <= 1.0) print \" ✅ 컷오버 복제 지연 ≤ 1s (NFR-03)\"; else print \" ⚠️ 복제 지연 > 1s (NFR-03) — 점검\" }"
echo " 이제 primary = B. scripts/verify.sh 로 누락·중복 확인."
echo "======================================================"
