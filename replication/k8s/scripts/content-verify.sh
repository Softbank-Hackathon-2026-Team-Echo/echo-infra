#!/usr/bin/env bash
# 행 내용·스키마 지문 대조 검증기 (인프라 25, echo-infra#150). 조회만 한다.
#
# 등록한 표마다 출발(SRC)·도착(DST) DB 의 다음 네 가지를 따로 비교해 MATCH / MISMATCH / UNKNOWN 을 낸다.
#   행 수 · 기본 키 집합 지문 · 행 내용 지문 · 스키마 지문
# 결과는 표준 출력에 JSON 한 개, 사람이 읽는 요약은 표준 오류에 쓴다. 행 원문·접속 비밀은 어디에도 쓰지 않는다(지문만).
# 기존 장부 검사(verify.sh, record_run)와 쓰기 전환 순서·운영 설정은 바꾸지 않는다. 이 결과로 전환을 막거나 허용하지 않는다.
#
# 사용:
#   TABLES="demo.seq_write shop.items" replication/k8s/scripts/content-verify.sh
#   SRC=B DST=A SLOT=echo_sub_rev TABLES=... content-verify.sh        # 역방향
# 환경 변수
#   SRC, DST         A|B (기본 A→B). 접속은 common.sh 의 컨텍스트·네임스페이스로 Postgres 파드 안 psql(로컬 소켓)
#   TABLES           공백으로 나눈 schema.table 목록 (기본 demo.seq_write). 소문자·숫자·_ 만
#   VERIFY_USER      조회 계정 (기본 echo_verify, verify-user.sh 가 만든다: 등록 표 SELECT 만, 기본 읽기 전용 트랜잭션)
#   VERIFY_DB        DB 이름 (기본 app)
#   SLOT             출발 쪽 논리 복제 슬롯 이름. 주면 도착이 출발 시점까지 따라잡았는지 확인한다(아니면 UNKNOWN)
#   CATCHUP_WAIT     따라잡기를 기다리는 최대 초 (기본 10)
#   MAX_ROWS         표당 행 상한. 넘으면 지문을 만들지 않고 UNKNOWN(ROW_LIMIT) (기본 200000)
#   QUERY_TIMEOUT_MS 한 쪽 조회의 문장 시간 상한 (기본 20000)
#   PLAN_ID          이전 계획 id(UUID). 주면 결과 JSON 의 planId 로 남긴다(컷오버 결과 표 echo_ops.cutover_runs 와 같은 키)
# 종료 코드: 0 = 모두 MATCH, 1 = MISMATCH 가 하나라도, 2 = MISMATCH 없이 UNKNOWN 이 하나라도, 3 = 입력 오류
#
# 비교 시점(같은 상태를 읽었다고 보는 조건) — 「출발 → 도착 → 출발」 샌드위치:
#   S1 출발 지문(트랜잭션 하나, REPEATABLE READ) → (SLOT 이 있으면) 슬롯 confirmed_flush_lsn ≥ S1 의 LSN 까지 대기
#   → T 도착 지문 → S2 출발 지문. 표마다 S1 = S2 일 때만 판정하고, 다르면 그 표는 UNKNOWN(SOURCE_CHANGED).
#   S1·S2 사이에 출발 표가 바뀌지 않았고 도착이 S1 시점까지 따라잡았으면 T 는 같은 상태여야 한다.
#   한계: 그 사이에 바뀌었다가 정확히 되돌아온 경우(ABA)는 구분하지 못한다. SLOT 이 없으면 따라잡기는 확인하지 않는다.
#
# 지문 규칙(METHOD_VERSION 이 바뀌면 지문을 서로 비교하지 않는다):
#   행 내용   md5( to_jsonb(행)::text 를 기본 키 순서로 줄바꿈 연결 ) — jsonb 는 키(열 이름)를 정렬하므로 열 순서와 무관,
#             NULL(null)과 빈 문자열("")을 구분한다. 세션 고정: TimeZone=UTC, DateStyle=ISO, IntervalStyle=iso_8601,
#             bytea_output=hex, extra_float_digits=1
#   기본 키   md5( ROW(기본 키 열)::text 를 같은 순서로 연결 ). 순서 = ROW(기본 키)::text COLLATE "C" (정렬 규칙과 무관)
#   스키마    md5( 열 이름·format_type·NOT NULL 을 이름 순(COLLATE "C")으로 + 기본 키 열 목록 ). 기본값·identity·인덱스·
#             제약·트리거·권한은 넣지 않는다(구독자 쪽에서 다를 수 있어서)
#   지원 타입 아래 SUPPORTED 목록만. 그 밖의 타입이 있으면 UNKNOWN(UNSUPPORTED_TYPE). 기본 키가 없으면 UNKNOWN(NO_PRIMARY_KEY)
source "$(dirname "$0")/common.sh"
set +eE; trap - ERR   # 실패는 아래에서 UNKNOWN 으로 바꿔 끝까지 결과를 낸다

METHOD_VERSION="content-verify/1"
SRC="${SRC:-A}"; DST="${DST:-B}"
TABLES="${TABLES:-demo.seq_write}"
VERIFY_USER="${VERIFY_USER:-echo_verify}"; VERIFY_DB="${VERIFY_DB:-app}"
SLOT="${SLOT:-}"; CATCHUP_WAIT="${CATCHUP_WAIT:-10}"
MAX_ROWS="${MAX_ROWS:-200000}"; QUERY_TIMEOUT_MS="${QUERY_TIMEOUT_MS:-20000}"
PLAN_ID="${PLAN_ID:-}"
SUPPORTED="'int2','int4','int8','numeric','float4','float8','bool','text','varchar','bpchar','uuid','date','time','timestamp','timestamptz','interval','jsonb','bytea'"

die() { echo "content-verify: $*" >&2; exit 3; }
[[ $SRC == A || $SRC == B ]] && [[ $DST == A || $DST == B ]] && [[ $SRC != "$DST" ]] || die "SRC·DST 는 A·B 중 서로 다른 값"
[[ $VERIFY_USER =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "VERIFY_USER 형식"
[[ $VERIFY_DB =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "VERIFY_DB 형식"
[[ -z $SLOT || $SLOT =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "SLOT 형식"
[[ -z $PLAN_ID || $PLAN_ID =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] || die "PLAN_ID 는 uuid 형식"
for n in "$CATCHUP_WAIT" "$MAX_ROWS" "$QUERY_TIMEOUT_MS"; do [[ $n =~ ^[0-9]{1,9}$ ]] || die "숫자 설정 형식: $n"; done
TBL=()
for t in $TABLES; do
  [[ $t =~ ^[a-z_][a-z0-9_]{0,62}\.[a-z_][a-z0-9_]{0,62}$ ]] || die "표 이름 형식(schema.table, 소문자·숫자·_): $t"
  TBL+=("$t")
done
[[ ${#TBL[@]} -gt 0 && ${#TBL[@]} -le 50 ]] || die "TABLES 는 1~50 개"

ms() { python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo $(( $(date +%s) * 1000 )); }
T_START=$(ms)
# 조회 계정으로 파드 안 psql(로컬 소켓). SQL 은 표준 입력. 칸 구분은 \x1f(빈 칸이 합쳐지지 않게). 오류 원문은 남기지 않는다(행 값이 섞일 수 있어서) — 종류만 고른다.
# vq 는 명령 치환($(…)) 안에서 불리므로 오류 종류를 변수가 아니라 파일(VQ_ERR_FILE)로 넘긴다. vq_err 로 읽는다.
VQ_ERR_FILE=$(mktemp); trap 'rm -f "$VQ_ERR_FILE"' EXIT
vq() { local side=$1 err rc out kind=""
  err=$(mktemp); out=$(kubectl --context "$(ctx_of "$side")" -n "$NS" exec -i echo-pg-0 -c postgres -- \
    psql -X -q -v ON_ERROR_STOP=1 -U "$VERIFY_USER" -d "$VERIFY_DB" -tA -F $'\x1f' 2>"$err"); rc=$?
  if [[ $rc -ne 0 ]]; then
    if grep -q 'statement timeout' "$err"; then kind=TIMEOUT
    elif grep -qi 'permission denied' "$err"; then kind=PERMISSION_DENIED
    else kind=QUERY_FAILED; fi
  fi
  rm -f "$err"; printf '%s' "$kind" > "$VQ_ERR_FILE"
  [[ $rc -eq 0 ]] || return 1
  printf '%s\n' "$out"; }
vq_err() { local k; k=$(cat "$VQ_ERR_FILE" 2>/dev/null); printf '%s' "${k:-QUERY_FAILED}"; }

# ── 1. 카탈로그: 표 존재 · 스키마 지문 · 기본 키 열 · 지원 밖 타입 ─────────────────────────────
catalog_sql() { local t
  for t in "${TBL[@]}"; do cat <<SQL
SELECT '$t',
  (to_regclass('$t') IS NOT NULL)::int,
  coalesce((SELECT string_agg(quote_ident(a.attname), ',' ORDER BY array_position(i.indkey::int2[], a.attnum))
            FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
            WHERE i.indrelid = to_regclass('$t') AND i.indisprimary), ''),
  md5(coalesce((SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod) || CASE WHEN a.attnotnull THEN ' not null' ELSE '' END,
                                  ',' ORDER BY a.attname COLLATE "C")
                FROM pg_attribute a WHERE a.attrelid = to_regclass('$t') AND a.attnum > 0 AND NOT a.attisdropped), '')
      || '|pk=' ||
      coalesce((SELECT string_agg(a.attname, ',' ORDER BY array_position(i.indkey::int2[], a.attnum))
                FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
                WHERE i.indrelid = to_regclass('$t') AND i.indisprimary), '')),
  coalesce((SELECT string_agg(DISTINCT ty.typname, ',') FROM pg_attribute a JOIN pg_type ty ON ty.oid = a.atttypid
            WHERE a.attrelid = to_regclass('$t') AND a.attnum > 0 AND NOT a.attisdropped
              AND ty.typname NOT IN ($SUPPORTED)), '');
SQL
  done; }

# 카탈로그 결과를 줄 단위 변수로 둔다(bash 3.2: 연관 배열 없음 → 표 순서 인덱스로)
declare -a C_EXISTS_S C_PK_S C_SCHEMA_S C_UNSUP_S C_EXISTS_D C_PK_D C_SCHEMA_D C_UNSUP_D
load_catalog() { local side=$1 out i=0 t ex pk sc un
  out=$(catalog_sql | vq "$side") || return 1
  while IFS=$'\x1f' read -r t ex pk sc un; do
    [[ $t == "${TBL[$i]}" ]] || return 1
    if [[ $side == "$SRC" ]]; then C_EXISTS_S[$i]=$ex C_PK_S[$i]=$pk C_SCHEMA_S[$i]=$sc C_UNSUP_S[$i]=$un
    else C_EXISTS_D[$i]=$ex C_PK_D[$i]=$pk C_SCHEMA_D[$i]=$sc C_UNSUP_D[$i]=$un; fi
    i=$((i+1))
  done <<< "$out"
  [[ $i -eq ${#TBL[@]} ]]; }

CAT_ERR_S="" CAT_ERR_D=""
load_catalog "$SRC" || CAT_ERR_S=$(vq_err)
load_catalog "$DST" || CAT_ERR_D=$(vq_err)

# 지문을 만들 표: 양쪽에 있고, 기본 키가 있고, 지원 타입만 쓰고, 양쪽 기본 키 열이 같은 것
declare -a ELIG PRE_RESULT PRE_REASON
for i in "${!TBL[@]}"; do
  ELIG[$i]=0 PRE_RESULT[$i]="" PRE_REASON[$i]=""
  if [[ -n $CAT_ERR_S || -n $CAT_ERR_D ]]; then PRE_RESULT[$i]=UNKNOWN PRE_REASON[$i]="CATALOG_${CAT_ERR_S:-$CAT_ERR_D}"; continue; fi
  if [[ ${C_EXISTS_S[$i]} != 1 ]]; then PRE_RESULT[$i]=UNKNOWN PRE_REASON[$i]=SOURCE_TABLE_MISSING; continue; fi
  if [[ ${C_EXISTS_D[$i]} != 1 ]]; then PRE_RESULT[$i]=MISMATCH PRE_REASON[$i]=TARGET_TABLE_MISSING; continue; fi
  if [[ -n ${C_UNSUP_S[$i]} || -n ${C_UNSUP_D[$i]} ]]; then PRE_RESULT[$i]=UNKNOWN PRE_REASON[$i]=UNSUPPORTED_TYPE; continue; fi
  if [[ -z ${C_PK_S[$i]} || -z ${C_PK_D[$i]} ]]; then PRE_RESULT[$i]=UNKNOWN PRE_REASON[$i]=NO_PRIMARY_KEY; continue; fi
  if [[ ${C_SCHEMA_S[$i]} != "${C_SCHEMA_D[$i]}" ]]; then PRE_RESULT[$i]=MISMATCH PRE_REASON[$i]=SCHEMA; continue; fi
  ELIG[$i]=1
done

# ── 2. 지문: 한 쪽을 트랜잭션 하나(REPEATABLE READ READ ONLY)로 읽는다 ───────────────────────
fp_sql() { local i t pk
  cat <<SQL
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL statement_timeout = $QUERY_TIMEOUT_MS;
SET LOCAL TimeZone = 'UTC'; SET LOCAL DateStyle = 'ISO, YMD'; SET LOCAL IntervalStyle = 'iso_8601';
SET LOCAL bytea_output = 'hex'; SET LOCAL extra_float_digits = 1;
SELECT '#lsn', CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END;
SQL
  for i in "${!TBL[@]}"; do
    [[ ${ELIG[$i]} == 1 ]] || continue
    t=${TBL[$i]} pk=${C_PK_S[$i]}
    cat <<SQL
WITH c AS (SELECT count(*) AS n FROM $t)
SELECT '$t', c.n,
  CASE WHEN c.n > $MAX_ROWS THEN 'ROW_LIMIT' ELSE
    (SELECT md5(coalesce(string_agg(ROW($pk)::text, E'\n' ORDER BY ROW($pk)::text COLLATE "C"), '')) || ' ' ||
            md5(coalesce(string_agg(to_jsonb(r)::text, E'\n' ORDER BY ROW($pk)::text COLLATE "C"), ''))
     FROM $t AS r) END
FROM c;
SQL
  done
  echo "COMMIT;"; }

# read_fp <side> <접두사>: 변수 <접두사>_LSN, 배열 <접두사>_ROWS/<접두사>_FP(인덱스 = 표 순서), 실패 시 <접두사>_ERR
read_fp() { local side=$1 p=$2 out t n f i lsn=""
  eval "${p}_ROWS=(); ${p}_FP=(); ${p}_ERR=''; ${p}_LSN=''"
  out=$(fp_sql | vq "$side") || { eval "${p}_ERR=\$(vq_err)"; return 1; }
  while IFS=$'\x1f' read -r t n f; do
    [[ -z $t ]] && continue
    if [[ $t == '#lsn' ]]; then lsn=$n; continue; fi
    for i in "${!TBL[@]}"; do [[ ${TBL[$i]} == "$t" ]] && { eval "${p}_ROWS[$i]=\$n; ${p}_FP[$i]=\$f"; break; }; done
  done <<< "$out"
  eval "${p}_LSN=\$lsn"; }

ANY_ELIG=0; for i in "${!TBL[@]}"; do [[ ${ELIG[$i]} == 1 ]] && ANY_ELIG=1; done
CAUGHT_UP=null WAITED_MS=0
if [[ $ANY_ELIG == 1 ]]; then
  read_fp "$SRC" S1
  if [[ -n $SLOT && -z $S1_ERR ]]; then
    w0=$(ms); CAUGHT_UP=false
    for _ in $(seq 0 $((CATCHUP_WAIT * 4))); do
      r=$(printf "SELECT coalesce((SELECT (confirmed_flush_lsn >= '%s'::pg_lsn)::int FROM pg_replication_slots WHERE slot_name = '%s'), -1);\n" "$S1_LSN" "$SLOT" | vq "$SRC")
      [[ $r == 1 ]] && { CAUGHT_UP=true; break; }
      [[ $r == -1 ]] && { CAUGHT_UP=slot_missing; break; }
      sleep 0.25
    done
    WAITED_MS=$(( $(ms) - w0 ))
  fi
  read_fp "$DST" T
  read_fp "$SRC" S2
fi

# ── 3. 판정 ─────────────────────────────────────────────────────────────────────────────
json_s() { [[ -z $1 ]] && printf 'null' || printf '"%s"' "$1"; }   # 값은 모두 검사한 형식(표 이름·hex·숫자·코드)뿐
json_n() { [[ $1 =~ ^[0-9]+$ ]] && printf '%s' "$1" || printf 'null'; }
match=0 mismatch=0 unknown=0 rows_json=""
for i in "${!TBL[@]}"; do
  t=${TBL[$i]} result=${PRE_RESULT[$i]} reason=${PRE_REASON[$i]}
  sr="" tr="" spk="" tpk="" srow="" trow=""
  if [[ ${ELIG[$i]} == 1 ]]; then
    s1n=${S1_ROWS[$i]:-} s1f=${S1_FP[$i]:-} tn=${T_ROWS[$i]:-} tf=${T_FP[$i]:-} s2n=${S2_ROWS[$i]:-} s2f=${S2_FP[$i]:-}
    sr=$s1n tr=$tn
    [[ $s1f == *' '* ]] && { spk=${s1f%% *}; srow=${s1f#* }; }
    [[ $tf == *' '* ]] && { tpk=${tf%% *}; trow=${tf#* }; }
    if   [[ -n $S1_ERR ]]; then result=UNKNOWN reason="SOURCE_$S1_ERR"
    elif [[ -n $T_ERR ]];  then result=UNKNOWN reason="TARGET_$T_ERR"
    elif [[ -n $S2_ERR ]]; then result=UNKNOWN reason="SOURCE_$S2_ERR"
    elif [[ $CAUGHT_UP == false ]]; then result=UNKNOWN reason=NOT_CAUGHT_UP
    elif [[ $CAUGHT_UP == slot_missing ]]; then result=UNKNOWN reason=SLOT_MISSING
    elif [[ $s1f == ROW_LIMIT || $tf == ROW_LIMIT || $s2f == ROW_LIMIT ]]; then result=UNKNOWN reason=ROW_LIMIT
    elif [[ "$s1n $s1f" != "$s2n $s2f" ]]; then result=UNKNOWN reason=SOURCE_CHANGED
    elif [[ $s1n != "$tn" ]]; then result=MISMATCH reason=ROW_COUNT
    elif [[ $spk != "$tpk" ]]; then result=MISMATCH reason=PRIMARY_KEYS
    elif [[ $srow != "$trow" ]]; then result=MISMATCH reason=ROW_CONTENT
    else result=MATCH reason=""; fi
  fi
  case $result in MATCH) match=$((match+1));; MISMATCH) mismatch=$((mismatch+1));; *) unknown=$((unknown+1));; esac
  printf '%-28s %-8s %s\n' "$t" "$result" "${reason:--}" >&2
  [[ -n $rows_json ]] && rows_json+=","
  rows_json+=$(printf '{"table":"%s","result":"%s","reason":%s,"rows":{"source":%s,"target":%s},"fingerprints":{"schema":{"source":%s,"target":%s},"primaryKeys":{"source":%s,"target":%s},"rows":{"source":%s,"target":%s}}}' \
    "$t" "$result" "$(json_s "$reason")" "$(json_n "$sr")" "$(json_n "$tr")" \
    "$(json_s "${C_SCHEMA_S[$i]:-}")" "$(json_s "${C_SCHEMA_D[$i]:-}")" "$(json_s "$spk")" "$(json_s "$tpk")" "$(json_s "$srow")" "$(json_s "$trow")")
done
case $CAUGHT_UP in true) caught_json=true ;; null) caught_json=null ;; *) caught_json=false ;; esac
printf '{"method":"%s","planId":%s,"checkedAt":"%s","source":{"side":"%s","db":"%s","lsn":%s},"target":{"side":"%s","db":"%s","lsn":%s},"alignment":{"rule":"source-target-source","slot":%s,"caughtUp":%s,"waitedMs":%s},"limits":{"maxRows":%s,"queryTimeoutMs":%s},"tables":[%s],"summary":{"match":%s,"mismatch":%s,"unknown":%s},"elapsedMs":%s}\n' \
  "$METHOD_VERSION" "$(json_s "$(printf '%s' "$PLAN_ID" | tr 'A-F' 'a-f')")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SRC" "$VERIFY_DB" "$(json_s "${S1_LSN:-}")" "$DST" "$VERIFY_DB" "$(json_s "${T_LSN:-}")" \
  "$(json_s "$SLOT")" "$caught_json" "$WAITED_MS" "$MAX_ROWS" "$QUERY_TIMEOUT_MS" "$rows_json" "$match" "$mismatch" "$unknown" "$(( $(ms) - T_START ))"
echo "요약: MATCH $match · MISMATCH $mismatch · UNKNOWN $unknown" >&2
[[ $mismatch -gt 0 ]] && exit 1
[[ $unknown -gt 0 ]] && exit 2
exit 0
