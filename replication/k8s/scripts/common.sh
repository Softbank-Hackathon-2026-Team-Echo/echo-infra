#!/usr/bin/env bash
# 두 클러스터의 Postgres·PgBouncer 파드에 kubectl exec 로 psql 을 보내는 공통 함수. 비밀번호는 파드 env(Secret)에서만 읽는다(여기 출력 없음).
# 주의: psql 변수(:'conn')는 -c 문자열에서는 치환되지 않는다(서버로 그대로 간다). CREATE SUBSCRIPTION 처럼 변수를 쓰는 SQL 은 echo … | psql 로 stdin 에 넣는다.
set -euo pipefail
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
A_CTX="${A_CTX:-echo-dev-eks}"
B_CTX="${B_CTX:-gke_team-echo-final_asia-northeast3-a_echo-dev-gke}"
NS="${NS:-echo-data}"

# psql on Postgres pod: pg <A|B> "<sql>" [-v var=val ...]
pg() { local side=$1; shift; local ctx; [[ $side == A ]] && ctx=$A_CTX || ctx=$B_CTX
  kubectl --context "$ctx" -n "$NS" exec -i echo-pg-0 -c postgres -- psql -X -v ON_ERROR_STOP=1 -U postgres -d app -tA "$@"; }
# pgbouncer admin console: pgb <A|B> "<cmd>". pgbouncer 이미지에 psql 이 없어 Postgres 파드에서 보낸다(비밀번호 = 파드 env PGB_AUTH_PASSWORD).
pgb() { local side=$1; local cmd=$2; local ctx; [[ $side == A ]] && ctx=$A_CTX || ctx=$B_CTX
  kubectl --context "$ctx" -n "$NS" exec -i echo-pg-0 -c postgres -- sh -c \
    'PGPASSWORD=$PGB_AUTH_PASSWORD psql -X -h echo-pgbouncer -p 6432 -U pgbouncer_auth -d pgbouncer -tAc "$0"' "$cmd"; }
# pgbouncer ini 의 백엔드 host 를 바꾸고 RELOAD: repoint <A|B> <new_host>
repoint() { local side=$1; local host=$2; local ctx; [[ $side == A ]] && ctx=$A_CTX || ctx=$B_CTX
  kubectl --context "$ctx" -n "$NS" exec -i deploy/echo-pgbouncer -- sh -c \
    'sed -i "s/^app = host=[^ ]*/app = host=$0/" /etc/pgbouncer/pgbouncer.ini && grep "^app = " /etc/pgbouncer/pgbouncer.ini' "$host" >/dev/null
  pgb "$side" "RELOAD;" >/dev/null; }
now() { date +%s.%N; }

# ── 컷오버·롤백 결과 표 (인프라 7.2, echo-infra#57) ───────────────────────────────────────────────
# cutover.sh·rollback.sh 가 RESUME 뒤 새 primary 에 결과 한 줄을 쓴다. echo-was 는 데이터 확인 단계와 같은
# echo_monitor 연결로 이 표를 읽기만 한다(API 서버 16, echo-was#63). 쓰기 토큰이 따로 필요 없다.
# - echo_pub 이 FOR ALL TABLES 라 이 표도 복제된다 → 표가 한쪽에만 있으면 구독 쪽 적용이 멈춰 복제 전체가 선다.
#   그래서 A·B 양쪽에 먼저 만들고, 이미 켜진 구독은 REFRESH PUBLICATION 으로 표를 더한다.
# - 키는 uuid: 논리 복제는 시퀀스를 넘기지 않아 bigserial 이면 롤백 때 A 가 같은 번호를 다시 내 충돌한다.
OPS_DDL=$(cat <<'SQL'
SET client_min_messages = warning;
CREATE SCHEMA IF NOT EXISTS echo_ops;
CREATE TABLE IF NOT EXISTS echo_ops.cutover_runs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind            text NOT NULL CHECK (kind IN ('CUTOVER', 'ROLLBACK')),
  from_side       text NOT NULL CHECK (from_side IN ('A', 'B')),
  to_side         text NOT NULL CHECK (to_side IN ('A', 'B')),
  paused_at       timestamptz NOT NULL,
  resumed_at      timestamptz NOT NULL,
  write_pause_ms  integer NOT NULL,
  drain_ms        integer,
  catchup_ms      integer,
  switch_ms       integer,
  rows_total      bigint,
  missing_rows    bigint,
  duplicate_rows  bigint,
  max_n           bigint,
  created_at      timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'echo_monitor') THEN
    GRANT USAGE ON SCHEMA echo_ops TO echo_monitor;
    GRANT SELECT ON echo_ops.cutover_runs TO echo_monitor;
  END IF;
END $$;
SQL
)

# 양쪽에 표·권한을 만들고(있으면 그대로), 켜진 구독 중 이 표가 빠진 것만 REFRESH 한다. 여러 번 돌려도 같다.
ops_table_ensure() {
  local s sub
  for s in B A; do pg "$s" <<<"$OPS_DDL" >/dev/null; done
  for s in A B; do
    for sub in $(pg "$s" -c "SELECT s.subname FROM pg_subscription s WHERE s.subenabled AND NOT EXISTS (SELECT 1 FROM pg_subscription_rel r WHERE r.srsubid = s.oid AND r.srrelid = 'echo_ops.cutover_runs'::regclass);"); do
      pg "$s" -c "ALTER SUBSCRIPTION $sub REFRESH PUBLICATION;" >/dev/null
      echo "[결과 표] $s: $sub 에 echo_ops.cutover_runs 를 더했다(REFRESH PUBLICATION)"
    done
  done
}

# RESUME 뒤 새 primary 에서 장부(demo.seq_write)를 대조하고 결과 한 줄을 쓴다. 실패해도 컷오버·롤백은 성공으로 둔다.
# record_run <CUTOVER|ROLLBACK> <from A|B> <to A|B> <t0 PAUSE> <tp 드레인 끝> <tc 따라잡기 끝> <t1 RESUME>
record_run() {
  local kind=$1 from=$2 to=$3 t0=$4 tp=$5 tc=$6 t1=$7 v total missing dup maxn id
  v=$(pg "$to" -c "SELECT count(*), CASE WHEN count(*) = 0 THEN 0 ELSE (max(n) - min(n) + 1) - count(DISTINCT n) END, count(*) - count(DISTINCT n), COALESCE(max(n), 0) FROM demo.seq_write;" 2>/dev/null) \
    || { echo " [결과 표] 장부 대조 실패 — 기록하지 않음(컷오버·롤백 자체는 끝났다)"; return 0; }
  IFS='|' read -r total missing dup maxn <<<"$v"
  id=$(pg "$to" -c "INSERT INTO echo_ops.cutover_runs (kind, from_side, to_side, paused_at, resumed_at, write_pause_ms, drain_ms, catchup_ms, switch_ms, rows_total, missing_rows, duplicate_rows, max_n) VALUES ('$kind', '$from', '$to', to_timestamp($t0), to_timestamp($t1), round(($t1 - $t0) * 1000), round(($tp - $t0) * 1000), round(($tc - $tp) * 1000), round(($t1 - $tc) * 1000), $total, $missing, $dup, $maxn) RETURNING id;" 2>/dev/null | head -1) \
    || { echo " [결과 표] 기록 실패 — scripts/ops-table.sh 로 표를 만든 뒤 다시 하면 된다(컷오버·롤백 자체는 끝났다)"; return 0; }
  printf ' [결과 표] %s 에 기록: %s (장부 %s건, 누락 %s, 중복 %s) id=%s\n' "$to" "$kind" "$total" "$missing" "$dup" "$id"
}
