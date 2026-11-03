#!/usr/bin/env bash
# AWS EC2(terraform/environments/aws/onprem-demo)를 온프레로 쓸 때: SSM Run Command 로 install.sh 를 보내 실행한다.
# 기기에 들어오는 포트가 없어도 된다(SSM 은 기기가 AWS 로 나가는 연결).
#
#   onprem/hosts/ec2-ssm.sh <instance-id>                       # 터널 없이
#   DEMO_HOST=demo-onprem-xxxxxxxx.echoport.uk onprem/hosts/ec2-ssm.sh <instance-id> --tunnel
#
# --tunnel: 터널 자격 증명 JSON 을 SSM SecureString(Terraform 출력 tunnel_credentials_parameter)에서 기기가 직접 읽는다.
#           명령 기록에 비밀값이 남지 않게, 이 스크립트는 값을 넘기지 않고 파라미터 이름만 넘긴다.
#           값 넣기(한 번): aws ssm put-parameter --type SecureString --name <이름> --value file://tunnel.json
# AWS 자격 증명은 호출하는 셸의 것을 쓴다(예: AWS_PROFILE). 리전은 AWS_REGION(기본 ap-northeast-2).
set -euo pipefail

ONPREM="$(cd "$(dirname "$0")/.." && pwd)"
IID="${1:?사용: ec2-ssm.sh <instance-id> [--tunnel]}"
TUNNEL="${2:-}"
REGION="${AWS_REGION:-ap-northeast-2}"
PARAM="${TUNNEL_PARAMETER:-/echo/onprem-demo/cf-tunnel-credentials}"

# install.sh·manifests 를 묶어 명령 안에 싣는다(기기는 비공개 저장소를 받을 수 없다).
payload="$(tar -C "$ONPREM" -czf - install.sh manifests | base64 | tr -d '\n')"

envs=""
for v in K3S_VERSION DEMO_IMAGE DEMO_HOST ECHO_ENVIRONMENT SWAP_SIZE_MB; do
  if [ -n "${!v:-}" ]; then
    [[ "${!v}" =~ ^[A-Za-z0-9./:@_+-]+$ ]] || {
      echo "$v 값에 쓸 수 없는 글자가 있다" >&2
      exit 1
    }
    envs+="$v=${!v} "
  fi
done

script=$(
  cat <<EOF
set -euo pipefail
rm -rf /opt/echo-onprem && mkdir -p /opt/echo-onprem && cd /opt/echo-onprem
trap 'rm -f /opt/echo-onprem/tunnel.json' EXIT
echo '$payload' | base64 -d | tar -xzf -
creds=""
if [ "$TUNNEL" = "--tunnel" ]; then
  # SSM 실행 환경에는 HOME 이 없다. 없으면 snap 의 aws CLI 가 아무것도 출력하지 않고 0 으로 끝난다.
  export HOME="\${HOME:-/root}"
  command -v aws >/dev/null || snap install aws-cli --classic >/dev/null
  install -m 600 /dev/null /opt/echo-onprem/tunnel.json
  # snap 의 aws CLI 는 출력을 파일로 바로 넘기면 0 바이트가 된다(파이프는 정상). cat 을 거친다.
  aws ssm get-parameter --region $REGION --name '$PARAM' --with-decryption --query Parameter.Value --output text | cat > /opt/echo-onprem/tunnel.json
  [ -s /opt/echo-onprem/tunnel.json ] || { echo "터널 자격 증명을 읽지 못했다: $PARAM" >&2; exit 1; }
  creds="CF_TUNNEL_CREDENTIALS_FILE=/opt/echo-onprem/tunnel.json"
fi
env $envs \$creds bash /opt/echo-onprem/install.sh 2>&1
EOF
)

# AWS-RunShellScript 는 sh(dash)로 돈다. 본문을 파일로 쓴 뒤 bash 로 실행한다.
wrapped="cat > /root/echo-onprem-run.sh <<'ECHO_RUN_EOF'
$script
ECHO_RUN_EOF
bash /root/echo-onprem-run.sh; rc=\$?; rm -f /root/echo-onprem-run.sh; exit \$rc"
params="$(python3 -I -c 'import json,sys; print(json.dumps({"commands": [sys.stdin.read()], "executionTimeout": ["1800"]}))' <<<"$wrapped")"
cid="$(aws ssm send-command --region "$REGION" --instance-ids "$IID" --document-name AWS-RunShellScript \
  --comment "echo onprem install.sh" --parameters "$params" --query Command.CommandId --output text)"
echo "SSM 명령 $cid 보냄. 끝날 때까지 기다린다(최대 30분)."

while :; do
  st="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$IID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$st" in
    Pending | InProgress | Delayed) sleep 10 ;;
    *) break ;;
  esac
done
aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$IID" \
  --query '[StandardOutputContent,StandardErrorContent]' --output text
echo "상태: $st"
[ "$st" = "Success" ]
