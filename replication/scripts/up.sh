#!/usr/bin/env bash
# A·B·PgBouncer 를 띄우고 스키마 + 논리 복제(publication/subscription)를 건다.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[up] 컨테이너 기동"
docker compose up -d

echo "[up] postgres 준비 대기"
until docker compose exec -T pg_a pg_isready -U postgres -d app >/dev/null 2>&1; do sleep 1; done
until docker compose exec -T pg_b pg_isready -U postgres -d app >/dev/null 2>&1; do sleep 1; done

echo "[up] 스키마 적용 (A, B)"
docker compose exec -T pg_a psql -v ON_ERROR_STOP=1 -U postgres -d app -f - < sql/schema.sql
docker compose exec -T pg_b psql -v ON_ERROR_STOP=1 -U postgres -d app -f - < sql/schema.sql

echo "[up] publication (A)"
docker compose exec -T pg_a psql -v ON_ERROR_STOP=1 -U postgres -d app -f - < sql/a-publication.sql

echo "[up] subscription (B → A)"
docker compose exec -T pg_b psql -v ON_ERROR_STOP=1 -U postgres -d app -f - < sql/b-subscription.sql

echo "[up] 완료. A=localhost:55441  B=localhost:55442  pgbouncer=localhost:6432(→pg_a)"
echo "     다음: 터미널 하나에서 scripts/writer.sh, 몇 초 뒤 scripts/cutover.sh"
