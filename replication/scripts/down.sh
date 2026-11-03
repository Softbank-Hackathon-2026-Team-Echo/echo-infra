#!/usr/bin/env bash
# 전부 내리고 pgbouncer 백엔드를 A 로 되돌린다(다음 실행이 깨끗하게 시작되도록).
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose down -v
sed -i 's/host=pg_b/host=pg_a/' pgbouncer/pgbouncer.ini
echo "[down] 정리 완료 (pgbouncer → pg_a 복원)"
