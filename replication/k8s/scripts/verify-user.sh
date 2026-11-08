#!/usr/bin/env bash
# content-verify.sh(인프라 25) 용 조회 계정 echo_verify 를 A·B 에 만든다. 다시 돌려도 같은 결과다.
#   - 슈퍼유저·복제·쓰기 권한 없음. 등록한 표(TABLES)에만 SELECT, 그 스키마에만 USAGE
#   - 기본 트랜잭션 읽기 전용(default_transaction_read_only = on)
#   - 비밀번호 없음: Postgres 파드 안 로컬 소켓(kubectl exec)으로만 쓴다. 네트워크 접속(scram)은 비밀번호가 없어 로그인할 수 없다
# 사용: TABLES="demo.seq_write shop.items" replication/k8s/scripts/verify-user.sh    (SIDES 기본 "A B")
# 운영 DB 에 역할을 더하는 변경이다. 적용 전에 승인을 받는다(이 PR 은 스크립트만 더한다).
source "$(dirname "$0")/common.sh"
TABLES="${TABLES:-demo.seq_write}"
SIDES="${SIDES:-A B}"
VERIFY_USER="${VERIFY_USER:-echo_verify}"; VERIFY_DB="${VERIFY_DB:-app}"
[[ $VERIFY_USER =~ ^[a-z_][a-z0-9_]{0,62}$ && $VERIFY_DB =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || { echo "VERIFY_USER·VERIFY_DB 형식" >&2; exit 3; }
grants=""
for t in $TABLES; do
  [[ $t =~ ^[a-z_][a-z0-9_]{0,62}\.[a-z_][a-z0-9_]{0,62}$ ]] || { echo "표 이름 형식: $t" >&2; exit 3; }
  grants+="GRANT USAGE ON SCHEMA ${t%%.*} TO $VERIFY_USER; GRANT SELECT ON TABLE $t TO $VERIFY_USER;"$'\n'
done
for side in $SIDES; do
  pg "$side" >/dev/null <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$VERIFY_USER') THEN CREATE ROLE $VERIFY_USER LOGIN; END IF;
END \$\$;
ALTER ROLE $VERIFY_USER WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD NULL;
ALTER ROLE $VERIFY_USER SET default_transaction_read_only = on;
GRANT CONNECT ON DATABASE $VERIFY_DB TO $VERIFY_USER;
$grants
SQL
  echo "[$side] $VERIFY_USER 준비됨 (SELECT: $TABLES)"
done
