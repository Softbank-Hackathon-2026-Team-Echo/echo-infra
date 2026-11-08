#!/usr/bin/env bash
# 앱이 DB 슈퍼유저(demo) 대신 일반 계정(demo_app)으로 붙게 한다. 기기에서 sudo 로 한 번 돌린다(install.sh 밖).
#
# 왜: demo 는 postgres 이미지가 처음 만든 부트스트랩 슈퍼유저다. 앱 DATABASE_URL 이 이 계정이면 앱이나
#     앱 네임스페이스 Secret 을 읽을 수 있는 echo-was 실행기(echo-app-deployer)가 뚫렸을 때
#     COPY ... TO PROGRAM 으로 DB 파드 안 명령 실행, 구독에 저장된 복제 비밀번호 열람, 다른 DB 변경까지 이어진다.
#     11/8 운영 확인: demo-y6cz3jrc 의 두 앱 Secret 이 demo(rolsuper=t) 이고, 클러스터에 NetworkPolicy 가 없다.
# 무엇: demo_app(NOSUPERUSER·NOCREATEROLE·NOCREATEDB·NOREPLICATION·NOBYPASSRLS)을 만들고,
#       APP_DBS 의 사용자 스키마·표·뷰·독립 시퀀스 소유자를 demo_app 으로 옮긴다.
#       앱 시작 때 스키마 맞춤(AUTO_MIGRATE: CREATE SCHEMA/ALTER TABLE ... IF NOT EXISTS)이 DB CREATE 권한과 표 소유자 권한을 요구해서다.
#       echo-demo/demo-app 의 DATABASE_URL(Secret echo-demo/demo-db 의 database-url)도 demo_app 으로 바꾸고 다시 띄운다.
# 그대로 두는 것: PostgreSQL·PgBouncer 의 demo 계정(auth_user), 발행·구독, 복제·전환 스크립트(replication-source.sh,
#       onprem-b2/scripts/*). 구독은 표 소유자 권한으로 적용하는데, 구독 소유자 demo(슈퍼유저)가 그 역할로 바꿀 수 있다.
#       public 스키마와 그 안의 함수(gcpcopy 의 pgbouncer_user_lookup 등)도 옮기지 않는다.
# 바꾸지 않는 것: echo-was 가 만든 앱 네임스페이스의 Secret. echo-was 서비스 환경 변수에서 바꾼다(README "앱 DB 계정").
# 다시 돌려도 같은 결과다(비밀번호는 처음 한 번만 만든다). 비밀값은 화면에 찍지 않는다.
#
#   sudo bash onprem/app-db-role.sh                    # APP_DBS 기본: demo gcpcopy (없는 DB 는 건너뜀)
#   sudo APP_DBS="demo" bash onprem/app-db-role.sh
set -euo pipefail

APP_DBS="${APP_DBS:-demo gcpcopy}"
ROLE=demo_app
K="k3s kubectl -n echo-demo"

log() { printf '[app-db-role] %s\n' "$*"; }
die() {
  printf '[app-db-role] 오류: %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || die "root 로 실행한다 (sudo)"
for db in $APP_DBS; do
  [[ "$db" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DB 이름 형식이 아니다: $db"
done
$K get statefulset demo-db >/dev/null || die "echo-demo/demo-db 가 없다 (install.sh 먼저)"

psql_su() { # psql_su <db> : 표준 입력의 SQL 을 demo(슈퍼유저)로 실행한다
  $K exec -i demo-db-0 -c postgres -- psql -X -q -v ON_ERROR_STOP=1 -U demo -d "$1"
}

# ---------- 1. 비밀번호 (처음 한 번) ----------
if ! $K get secret demo-db-app >/dev/null 2>&1; then
  log "demo_app 비밀번호 생성 (Secret echo-demo/demo-db-app)"
  pw="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf %s "$pw" | $K create secret generic demo-db-app --from-file=password=/dev/stdin >/dev/null
  unset pw
fi
pw="$($K get secret demo-db-app -o jsonpath='{.data.password}' | base64 -d)"
[[ "$pw" =~ ^[0-9a-f]{64}$ ]] || die "Secret echo-demo/demo-db-app 의 password 형식이 아니다"

# ---------- 2. 역할 ----------
log "역할 $ROLE (슈퍼유저 아님)"
{
  printf "DO \$\$BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='%s') THEN CREATE ROLE %s LOGIN; END IF; END\$\$;\n" "$ROLE" "$ROLE"
  printf "ALTER ROLE %s LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '%s';\n" "$ROLE" "$pw"
} | psql_su postgres

# ---------- 3. DB 별 권한·소유자 ----------
for db in $APP_DBS; do
  if [ -z "$($K exec demo-db-0 -c postgres -- psql -XAt -U demo -d postgres -c "SELECT 1 FROM pg_database WHERE datname='$db'")" ]; then
    log "DB $db 없음 — 건너뜀"
    continue
  fi
  log "DB $db: CONNECT·CREATE 권한, 사용자 스키마·표 소유자 → $ROLE"
  psql_su "$db" <<SQL
GRANT CONNECT, CREATE, TEMPORARY ON DATABASE $db TO $ROLE;
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN SELECT nspname FROM pg_namespace
           WHERE nspname NOT LIKE 'pg\_%' AND nspname NOT IN ('information_schema', 'public')
             AND nspowner <> '$ROLE'::regrole LOOP
    EXECUTE format('ALTER SCHEMA %I OWNER TO $ROLE', r.nspname);
  END LOOP;
  FOR r IN SELECT n.nspname, c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema'
             AND c.relkind IN ('r', 'p', 'v', 'm') AND c.relowner <> '$ROLE'::regrole LOOP
    EXECUTE format('ALTER %s %I.%I OWNER TO $ROLE',
                   CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
                   r.nspname, r.relname);
  END LOOP;
  -- 표에 딸린 시퀀스(identity·serial)는 위 ALTER TABLE 이 같이 옮긴다. 여기서는 독립 시퀀스만.
  FOR r IN SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE c.relkind = 'S' AND n.nspname NOT LIKE 'pg\_%' AND c.relowner <> '$ROLE'::regrole
             AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass
                             AND d.objid = c.oid AND d.deptype IN ('a', 'i')) LOOP
    EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO $ROLE', r.nspname, r.relname);
  END LOOP;
END
\$\$;
-- 운영 스크립트가 demo 로 새로 만드는 표(예: pg_dump -s 로 스키마 다시 넣기)도 앱이 읽고 쓸 수 있게 한다.
-- 그 표에 앱의 ALTER TABLE 이 필요하면 이 스크립트를 다시 돌려 소유자를 옮긴다.
ALTER DEFAULT PRIVILEGES FOR ROLE demo GRANT ALL ON TABLES TO $ROLE;
ALTER DEFAULT PRIVILEGES FOR ROLE demo GRANT ALL ON SEQUENCES TO $ROLE;
SQL
done

# ---------- 4. echo-demo/demo-app 전환 ----------
# install.sh 는 Secret demo-db 를 처음 한 번만 만들므로 다시 돌려도 이 값을 덮지 않는다.
log "echo-demo/demo-app DATABASE_URL → $ROLE, 다시 띄움"
url="postgresql://${ROLE}:${pw}@demo-pgbouncer:6432/demo"
$K patch secret demo-db --type merge -p "{\"data\":{\"database-url\":\"$(printf %s "$url" | base64 -w0)\"}}" >/dev/null
unset url pw
$K rollout restart deploy/demo-app >/dev/null
$K rollout status deploy/demo-app --timeout=180s

# ---------- 5. 확인 ----------
super="$($K exec demo-db-0 -c postgres -- psql -XAt -U demo -d postgres -c "SELECT rolsuper FROM pg_roles WHERE rolname='$ROLE'")"
[ "$super" = f ] || die "$ROLE 이 슈퍼유저로 보인다 (rolsuper=$super)"
log "완료: $ROLE rolsuper=f"
log "남은 일: echo-was 서비스 환경 변수 DATABASE_URL 을 $ROLE 로 바꾼다 (README \"앱 DB 계정\")"
