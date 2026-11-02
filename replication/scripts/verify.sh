#!/usr/bin/env bash
# 컷오버/롤백 후 현재 primary 에서 순번 n 을 대조한다. 누락 0 · 중복 0 이면 무손실.
# 인자로 노드를 고른다: 기본 pg_b(컷오버 후), 롤백 후에는 `verify.sh pg_a`.
set -euo pipefail
cd "$(dirname "$0")/.."

node="${1:-pg_b}"
B(){ docker compose exec -T "$node" psql -tAq -U postgres -d app -c "$1"; }

total=$(B "SELECT count(*) FROM demo.seq_write;")
distinct=$(B "SELECT count(DISTINCT n) FROM demo.seq_write;")
minmax=$(B "SELECT min(n)||' ~ '||max(n) FROM demo.seq_write;")
gap=$(B "SELECT count(*) FROM generate_series((SELECT min(n) FROM demo.seq_write),(SELECT max(n) FROM demo.seq_write)) g LEFT JOIN demo.seq_write t ON t.n=g WHERE t.n IS NULL;")
dup=$(B "SELECT COALESCE(sum(c-1),0) FROM (SELECT count(*) c FROM demo.seq_write GROUP BY n HAVING count(*)>1) x;")

echo "=== $node (현재 primary) 대조 ==="
echo " 총 행수:     $total"
echo " distinct n:  $distinct"
echo " n 범위:      $minmax"
echo " 누락(gap):    $gap"
echo " 중복(dup):    $dup"
echo "---------------------------------"
if [ "$gap" = "0" ] && [ "$dup" = "0" ]; then
  echo " ✅ 누락 0 · 중복 0 — 무손실 (컷오버/롤백) 성공"
else
  echo " ❌ 누락/중복 발생 — 절차 점검 필요"
fi
