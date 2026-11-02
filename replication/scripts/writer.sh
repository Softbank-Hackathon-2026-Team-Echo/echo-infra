#!/usr/bin/env bash
# PgBouncer(현재 primary)로 단조 증가 n 을 계속 쓴다. Ctrl-C 로 멈춘다.
# n = max(n)+1 로 스스로 증가하므로 컷오버 후 B 에서도 끊김 없이 이어진다.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[writer] pgbouncer(6432) 로 쓰기 시작. 컷오버 중에는 잠깐 멈췄다 이어진다."
i=0
while true; do
  docker compose exec -T pg_a psql -q "host=pgbouncer port=6432 dbname=app user=postgres" \
    -c "INSERT INTO demo.seq_write(n) SELECT COALESCE(max(n),0)+1 FROM demo.seq_write;" >/dev/null
  i=$((i+1))
  if [ $((i % 20)) -eq 0 ]; then echo "[writer] $i 건 썼다"; fi
  sleep 0.1
done
