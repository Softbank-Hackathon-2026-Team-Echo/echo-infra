#!/usr/bin/env bash
# echo-was DataSyncChecker(API 서버 8, DATA_SYNC_CHECK) 용 읽기 전용 계정 echo_monitor(pg_monitor) 를 A·B 양쪽에 만들고,
# 비밀번호를 GCP Secret Manager 에 넣는다. 비밀번호는 이 셸 안에서만 만들고 출력하지 않는다(저장소·이슈·Slack 에 0건).
# 사용: replication/k8s/scripts/monitor-user.sh            (데스크톱에서 1회)
# 선행: Secret Manager 껍데기 echo-dev-echo-was-pg-monitor-password 가 있어야 한다(terraform/environments/gcp/dev/control-plane.tf → apply).
# 다시 실행하면 비밀번호를 새로 만들어 양쪽 역할(ALTER ROLE)과 Secret Manager(새 version)에 같이 반영한다.
source "$(dirname "$0")/common.sh"
SECRET_ID="${SECRET_ID:-echo-dev-echo-was-pg-monitor-password}"
PROJECT="${PROJECT:-team-echo-final}"
GCLOUD_CFG="${GCLOUD_CFG:-echo}"
A_HOST="${A_HOST:-echo-dev-pg-a-cb5bc23aab2d0c23.elb.ap-northeast-1.amazonaws.com}"

gcloud secrets describe "$SECRET_ID" --project "$PROJECT" --configuration="$GCLOUD_CFG" >/dev/null 2>&1 \
  || { echo "Secret Manager 껍데기 $SECRET_ID 가 없다 → gcp dev terraform apply 먼저"; exit 1; }

pw=$(openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-32)

for side in A B; do
  pg $side >/dev/null <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'echo_monitor') THEN CREATE ROLE echo_monitor LOGIN; END IF;
END \$\$;
ALTER ROLE echo_monitor WITH LOGIN PASSWORD '$pw';
GRANT pg_monitor TO echo_monitor;
SQL
  echo "[$side] echo_monitor 준비됨 (pg_monitor)"
done

printf '%s' "$pw" | gcloud secrets versions add "$SECRET_ID" --project "$PROJECT" --configuration="$GCLOUD_CFG" --data-file=- >/dev/null
echo "[GCP] Secret Manager $SECRET_ID 에 새 version 추가"

# 확인: B 파드에서 echo_monitor 로 A(NLB·TLS)·B(클러스터 안)에 붙어 복제 상태를 읽는다. 비밀번호는 stdin 으로만 넘긴다.
printf '%s' "$pw" | kubectl --context "$B_CTX" -n "$NS" exec -i echo-pg-0 -c postgres -- sh -c \
  'PGPASSWORD=$(cat); export PGPASSWORD
   psql -X "host='"$A_HOST"' port=5432 dbname=app user=echo_monitor sslmode=require" -tAc "select '"'"'[A] ok: '"'"' || count(*) || '"'"' subscriber(s) streaming'"'"' from pg_stat_replication where state = '"'"'streaming'"'"';"
   psql -X "host=echo-pg port=5432 dbname=app user=echo_monitor" -tAc "select '"'"'[B] ok: '"'"' || count(*) || '"'"' subscription(s)'"'"' from pg_stat_subscription;"'
unset pw

cat <<MSG
echo-was 쪽 설정 힌트 (값 아님):
  DATA_SYNC_CHECKER_MODE=postgres
  DATA_SYNC_DATABASES=aws=$A_HOST:5432/echo_sub_rev,gcp=echo-pg.echo-data.svc.cluster.local:5432/echo_sub
  (형식: <환경>=<그 환경 DB host>:<port>/<그 환경이 가진 구독 이름>. aws(A)가 가진 구독 = echo_sub_rev, gcp(B)가 가진 구독 = echo_sub)
  사용자 echo_monitor · 비밀번호 Secret Manager $SECRET_ID (SecretSync 로 echo-was-env 에 넣는다) · A 는 sslmode=require
MSG
