#!/usr/bin/env bash
# 두 클러스터의 Postgres·PgBouncer 파드에 kubectl exec 로 psql 을 보내는 공통 함수. 비밀번호는 파드 env(Secret)에서만 읽는다(여기 출력 없음).
# 주의: psql 변수(:'conn')는 -c 문자열에서는 치환되지 않는다(서버로 그대로 간다). CREATE SUBSCRIPTION 처럼 변수를 쓰는 SQL 은 echo … | psql 로 stdin 에 넣는다.
# -E: 함수·명령 치환 안의 실패에도 ERR trap(guard_on_error)이 걸리게 한다.
set -Eeuo pipefail
# 뒤에 붙인다: 앞에 두면 gcloud SDK 의 kubectl 이 PATH 의 다른 kubectl(시험용 tests/bin 포함)을 가린다.
export PATH="$PATH:/opt/homebrew/share/google-cloud-sdk/bin"
A_CTX="${A_CTX:-echo-dev-eks}"
B_CTX="${B_CTX:-gke_team-echo-final_asia-northeast3-a_echo-dev-gke}"
NS="${NS:-echo-data}"
# 각 클러스터 안에서 PgBouncer 가 자기 쪽 Postgres 를 부르는 주소. 백엔드가 이 값이면 "자기 쪽이 쓰기 담당".
A_LOCAL="${A_LOCAL:-echo-pg}"
B_LOCAL="${B_LOCAL:-echo-pg}"

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
-- 인프라 12.1(echo-infra#66): 어느 이전 계획의 실행인지, 정상 컷오버인지 승격인지, 승격 때 잃었을 수 있는 범위.
-- 칸 더하기는 복제되지 않는다. 이 표에 행을 쓰는 것은 이 스크립트들뿐이고 ensure 는 쓰기 전에 양쪽을 다 맞추므로
-- 한쪽에만 칸이 있는 동안 복제될 행이 생기지 않는다.
ALTER TABLE echo_ops.cutover_runs ADD COLUMN IF NOT EXISTS plan_id uuid;
ALTER TABLE echo_ops.cutover_runs ADD COLUMN IF NOT EXISTS mode text;
ALTER TABLE echo_ops.cutover_runs ADD COLUMN IF NOT EXISTS rpo_estimate_ms integer;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'echo_ops.cutover_runs'::regclass AND conname = 'cutover_runs_mode_check') THEN
    ALTER TABLE echo_ops.cutover_runs
      ADD CONSTRAINT cutover_runs_mode_check CHECK (mode IS NULL OR mode IN ('NORMAL', 'PROMOTE'));
  END IF;
END $$;
-- 같은 계획으로 같은 종류를 두 번 기록하지 않는다(멱등의 마지막 방어선).
CREATE UNIQUE INDEX IF NOT EXISTS cutover_runs_plan_kind
  ON echo_ops.cutover_runs (plan_id, kind) WHERE plan_id IS NOT NULL;
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
# record_run <CUTOVER|ROLLBACK> <from A|B> <to A|B> <t0 PAUSE> <tp 드레인 끝> <tc 따라잡기 끝> <t1 RESUME> [mode NORMAL|PROMOTE] [rpo_ms]
# PLAN_ID 가 있으면 함께 남긴다(echo-was 가 시간 창 대신 계획 id 로 찾는다).
record_run() {
  local kind=$1 from=$2 to=$3 t0=$4 tp=$5 tc=$6 t1=$7 mode=${8:-NORMAL} rpo=${9:-NULL} v total missing dup maxn id
  local plan_sql=NULL; [[ -n ${PLAN_ID:-} ]] && plan_sql="'$PLAN_ID'"
  v=$(pg "$to" -c "SELECT count(*), CASE WHEN count(*) = 0 THEN 0 ELSE (max(n) - min(n) + 1) - count(DISTINCT n) END, count(*) - count(DISTINCT n), COALESCE(max(n), 0) FROM demo.seq_write;" 2>/dev/null) \
    || { echo " [결과 표] 장부 대조 실패 — 기록하지 않음(컷오버·롤백 자체는 끝났다)"; return 0; }
  IFS='|' read -r total missing dup maxn <<<"$v"
  id=$(pg "$to" -c "INSERT INTO echo_ops.cutover_runs (kind, from_side, to_side, paused_at, resumed_at, write_pause_ms, drain_ms, catchup_ms, switch_ms, rows_total, missing_rows, duplicate_rows, max_n, plan_id, mode, rpo_estimate_ms) VALUES ('$kind', '$from', '$to', to_timestamp($t0), to_timestamp($t1), round(($t1 - $t0) * 1000), round(($tp - $t0) * 1000), round(($tc - $tp) * 1000), round(($t1 - $tc) * 1000), $total, $missing, $dup, $maxn, $plan_sql, '$mode', $rpo) RETURNING id;" 2>/dev/null | head -1) \
    || { echo " [결과 표] 기록 실패 — scripts/ops-table.sh 로 표를 만든 뒤 다시 하면 된다(컷오버·롤백 자체는 끝났다)"; return 0; }
  printf ' [결과 표] %s 에 기록: %s (장부 %s건, 누락 %s, 중복 %s) id=%s\n' "$to" "$kind" "$total" "$missing" "$dup" "$id"
}

# ── 멱등·쓰기 담당 확인 (인프라 12.1, echo-infra#66) ───────────────────────────────────────────────
# 종료 코드: 0 = 끝남(이번에 했거나 이미 되어 있음) · 1 = 바뀐 것 없음(쓰기 담당 그대로, RESUME 함)
#            2 = 부분 상태(사람이 확인해야 함. PgBouncer 가 PAUSE 로 남아 있을 수 있다)
# 일꾼·Job 은 0 이면 다음 단계, 1 이면 트래픽 롤백, 2 면 멈추고 사람을 부른다(echo-was API 서버 17).

# 구독이 켜져 있으면 1, 없거나 꺼져 있으면 0: sub_enabled <A|B> <구독 이름>
sub_enabled() { pg "$1" -c "SELECT count(*) FROM pg_subscription WHERE subname = '$2' AND subenabled;"; }

# PgBouncer 백엔드 host: pgb_backend <A|B>
pgb_backend() { local side=$1 ctx; [[ $side == A ]] && ctx=$A_CTX || ctx=$B_CTX
  kubectl --context "$ctx" -n "$NS" exec -i deploy/echo-pgbouncer -- \
    sed -n 's/^app = host=\([^ ]*\).*/\1/p' /etc/pgbouncer/pgbouncer.ini; }

# 지금 PgBouncer 백엔드를 ConfigMap 에도 적는다: persist_backend <A|B>
# ini 는 emptyDir 이고 파드가 다시 뜨면 copy-ini 가 ConfigMap 을 복사한다. repoint 만 하면 재시작 때 옛 백엔드로 돌아가
# 쓰기 담당이 둘이 될 수 있다(PR #45 리뷰). 쓰기 정지 창 밖에서 부르고, 이미 같으면 아무것도 하지 않는다.
# `f || …` 로 불리면 함수 안에서 set -e 가 꺼지므로, 실패할 수 있는 명령마다 직접 return 1 한다.
persist_backend() { local side=$1 ctx live ini new esc; [[ $side == A ]] && ctx=$A_CTX || ctx=$B_CTX
  live=$(pgb_backend "$side") && [[ -n $live ]] || return 1
  ini=$(kubectl --context "$ctx" -n "$NS" get configmap echo-pgbouncer-ini -o 'jsonpath={.data.pgbouncer\.ini}') || return 1
  [[ $(sed -n 's/^app = host=\([^ ]*\).*/\1/p' <<<"$ini") == "$live" ]] && return 0
  new=$(sed "s/^app = host=[^ ]*/app = host=$live/" <<<"$ini")
  esc=$(sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' <<<"$new" | awk '{printf "%s\\n", $0}')
  kubectl --context "$ctx" -n "$NS" patch configmap echo-pgbouncer-ini --type merge -p "{\"data\":{\"pgbouncer.ini\":\"$esc\"}}" >/dev/null || return 1
  echo " [ConfigMap] $side PgBouncer 백엔드를 $live 로 적었다(파드가 다시 떠도 유지)"
}

# RESUME 뒤 ConfigMap 을 맞춘다. 실패하면 쓰기 담당은 바뀌었지만 재시작에 약한 상태라 종료 2(다시 실행하면 preflight 가 맞춘다).
persist_after_switch() { local s
  for s in "$@"; do
    persist_backend "$s" || { echo "[주의] $s ConfigMap 을 맞추지 못했다 — PgBouncer 파드가 다시 뜨면 옛 백엔드로 돌아간다. 같은 명령을 다시 실행하면 맞춘다" >&2; exit 2; }
  done
}

# 지금 쓰기 담당: A · B · PARTIAL(…). 구독 방향과 두 PgBouncer 백엔드가 같은 쪽을 가리킬 때만 그쪽이다.
# - 구독: A 가 쓰기 담당이면 B 의 echo_sub 가 켜져 있고 A 에 echo_sub_rev 가 없다. B 면 그 반대(cutover.sh 뒤).
#   echo-was DataSyncChecker 의 TARGET_IS_WRITER 판정(#73)과 같은 사실을 본다.
# - PgBouncer: 쓰기 담당 쪽은 자기 쪽 Postgres(*_LOCAL)를, 반대쪽은 인터넷 너머를 백엔드로 둔다.
writer_side() {
  local fwd rev a_be b_be by_sub=? by_pgb=?
  fwd=$(sub_enabled B echo_sub); rev=$(sub_enabled A echo_sub_rev)
  if [[ $fwd == 1 && $rev == 0 ]]; then by_sub=A; elif [[ $fwd == 0 && $rev == 1 ]]; then by_sub=B; fi
  a_be=$(pgb_backend A); b_be=$(pgb_backend B)
  if [[ $a_be == "$A_LOCAL" && $b_be != "$B_LOCAL" ]]; then by_pgb=A
  elif [[ $b_be == "$B_LOCAL" && $a_be != "$A_LOCAL" ]]; then by_pgb=B; fi
  if [[ $by_sub != "?" && $by_sub == "$by_pgb" ]]; then echo "$by_sub"
  else echo "PARTIAL(구독=$by_sub, PgBouncer=$by_pgb, A 백엔드=$a_be, B 백엔드=$b_be)"; fi
}

# PLAN_ID(선택)는 uuid 여야 한다. SQL 에 그대로 들어가므로 형식을 먼저 막는다.
plan_id_check() {
  [[ -z ${PLAN_ID:-} || $PLAN_ID =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] && return 0
  echo "[중단] PLAN_ID 가 uuid 형식이 아니다 — 바뀐 것 없음" >&2; exit 1
}

# 이 계획으로 이미 기록한 실행 수: plan_runs <A|B> <CUTOVER|ROLLBACK>. PLAN_ID 가 없으면 0.
plan_runs() { [[ -z ${PLAN_ID:-} ]] && { echo 0; return; }
  pg "$1" -c "SELECT count(*) FROM echo_ops.cutover_runs WHERE plan_id = '$PLAN_ID' AND kind = '$2';"; }

# 시작 전 확인: 이미 끝났으면 exit 0, 판단할 수 없으면 exit 2. preflight <CUTOVER|ROLLBACK> <from> <to>
preflight() {
  local kind=$1 from=$2 to=$3 w n
  w=$(writer_side)
  case $w in
    A|B) persist_backend A; persist_backend B ;;   # 지난 실행이 ConfigMap 을 못 맞췄으면 여기서 맞춘다
    *)   echo "[중단] 쓰기 담당을 판단할 수 없다: $w — replication/k8s/README.md '부분 상태 복구'를 따른다" >&2; exit 2 ;;
  esac
  # 따로 대입한다: [[ $(…) ]] 안에서 조회가 실패하면 빈 값이 "기록 있음"으로 읽힌다.
  n=$(plan_runs "$to" "$kind")
  if [[ $n != 0 ]]; then
    echo "[건너뜀] ALREADY_DONE: 이 계획($PLAN_ID)의 $kind 기록이 이미 있다"; exit 0
  fi
  case $w in
    "$to")   echo "[건너뜀] ALREADY_WRITER: 쓰기 담당이 이미 $to 다"; exit 0 ;;
    "$from") echo "[확인] 쓰기 담당 $from → $to 로 옮긴다" ;;
    *)       echo "[중단] 쓰기 담당을 판단할 수 없다: $w — replication/k8s/README.md '부분 상태 복구'를 따른다" >&2; exit 2 ;;
  esac
}

# 실패한 단계에 맞춰 끝낸다. 스크립트가 GUARD_PHASE 를 precheck → paused → switching → done 으로 옮긴다.
# - paused: PAUSE 했지만 아직 아무것도 바꾸지 않음 → 양쪽 RESUME, 쓰기 담당 그대로(1)
# - switching: 구독·백엔드를 바꾸는 중 → 옛 쪽에 쓰면 복제되지 않으므로 RESUME 하지 않고 멈춘다(2)
GUARD_PHASE=precheck
guard_on_error() {
  local rc=$?; trap - ERR
  case $GUARD_PHASE in
    precheck)  echo "[중단] 시작 전 확인 실패(rc=$rc) — 바뀐 것 없음" >&2; exit 1 ;;
    paused)    echo "[중단] 쓰기 정지 중 실패(rc=$rc) — 쓰기 담당 그대로, 양쪽 RESUME" >&2
               pgb A "RESUME app;" >/dev/null 2>&1 || true; pgb B "RESUME app;" >/dev/null 2>&1 || true; exit 1 ;;
    switching) echo "[중단] 전환 도중 실패(rc=$rc) — 부분 상태. PgBouncer 는 PAUSE 로 둔다. replication/k8s/README.md '부분 상태 복구'를 따른다" >&2; exit 2 ;;
    *)         exit "$rc" ;;
  esac
}

# ── 원본 장애 시 승격 (인프라 12.3, echo-infra#68) ───────────────────────────────────────────────
# A Postgres 에 닿는가(최대 3회). 재난 때 EKS API 가 오래 매달리지 않게 요청 제한 시간을 둔다.
a_reachable() { local i
  for i in 1 2 3; do
    kubectl --request-timeout=5s --context "$A_CTX" -n "$NS" exec -i echo-pg-0 -c postgres -- \
      psql -X -U postgres -d app -tAc "SELECT 1" >/dev/null 2>&1 && return 0
    [[ $i == 3 ]] || sleep 1
  done
  return 1
}

# A 를 보지 않고 B 만으로 본 상태: WRITER(B 가 쓰기 담당) · REPLICA(B 가 A 를 따라감) · PARTIAL(…)
b_side_state() { local fwd be
  fwd=$(sub_enabled B echo_sub); be=$(pgb_backend B)
  if [[ $fwd == 0 && $be == "$B_LOCAL" ]]; then echo WRITER
  elif [[ $fwd == 1 && $be != "$B_LOCAL" ]]; then echo REPLICA
  else echo "PARTIAL(B echo_sub 켜짐=$fwd, B 백엔드=$be)"; fi
}
