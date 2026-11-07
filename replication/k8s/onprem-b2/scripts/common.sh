# 온프레 → B2 장애 전환 스크립트 공통 (인프라 18). source 해서 쓴다.
set -euo pipefail
# GKE 인증 도구(gke-gcloud-auth-plugin). replication/k8s/scripts/common.sh 와 같이 뒤에 붙인다.
export PATH="$PATH:/opt/homebrew/share/google-cloud-sdk/bin"

GCP_CTX="${GCP_CTX:-gke_team-echo-final_asia-northeast3-a_echo-dev-customer-gke}"
AWS_CTX="${AWS_CTX:-echo-dev-eks}"
NS=echo-data-onprem
# 장애 시 올릴 B2 (TARGET=gcp 기본 | aws). 다른 쪽 B2 는 온프레 마지막 상태 증인이 된다.
TARGET="${TARGET:-gcp}"
case $TARGET in
  gcp) TARGET_CTX=$GCP_CTX WITNESS_CTX=$AWS_CTX SUB=echo_onprem_sub WITNESS=AWS ;;
  aws) TARGET_CTX=$AWS_CTX WITNESS_CTX=$GCP_CTX SUB=echo_onprem_sub_aws WITNESS=GCP ;;
  *) echo "TARGET 은 gcp|aws" >&2; exit 2 ;;
esac
TLABEL=$(echo "$TARGET" | tr a-z A-Z)
ONPREM_REGION=ap-northeast-2
export AWS_PROFILE="${AWS_PROFILE:-echo}"

# 온프레 기기 instance id (태그 Name=echo-onprem-demo)
onprem_id() {
  aws ec2 describe-instances --region "$ONPREM_REGION" \
    --filters "Name=tag:Name,Values=echo-onprem-demo" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# 온프레 기기에서 bash 스크립트 실행(SSM). stdin 의 스크립트를 base64 로 넘긴다. 표준 출력만 돌려준다.
onprem_sh() {
  local iid b cid st
  iid=$(onprem_id); b=$(base64 | tr -d '\n')
  cid=$(aws ssm send-command --region "$ONPREM_REGION" --instance-ids "$iid" --document-name AWS-RunShellScript \
    --parameters "commands=[\"echo $b | base64 -d | bash\"]" --query Command.CommandId --output text)
  for _ in $(seq 1 60); do
    sleep 1
    st=$(aws ssm get-command-invocation --region "$ONPREM_REGION" --command-id "$cid" --instance-id "$iid" --query Status --output text 2>/dev/null || true)
    case $st in Success|Failed|Cancelled|TimedOut) break ;; esac
  done
  aws ssm get-command-invocation --region "$ONPREM_REGION" --command-id "$cid" --instance-id "$iid" --query StandardOutputContent --output text
  [[ $st == Success ]]
}

# B2 에 psql (ctx 는 TARGET_CTX·WITNESS_CTX 등)
b2() { local ctx=$1; shift; kubectl --context "$ctx" -n "$NS" exec -i onprem-pg-0 -c postgres --request-timeout=30s -- psql -XAt -v ON_ERROR_STOP=1 -U demo -d demo "$@"; }

# 행 수 · 마지막 id · 전체 행 md5
SNAP_SQL="select count(*)||' '||coalesce(max(id),0)||' '||md5(coalesce(string_agg(t::text,'|' order by id),'')) from demo.seq_write t"
