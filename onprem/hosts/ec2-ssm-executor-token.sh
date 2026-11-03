#!/usr/bin/env bash
# EC2 온프레의 echo-was 실행기 토큰(echo-system/echo-executor-token)을 SSM 으로 꺼낸다.
# 토큰은 만료가 없어서 SSM 명령 출력(AWS 에 남는다)에 평문으로 두지 않는다.
# 기기에서 무작위 키로 토큰을 암호화하고, 그 키는 호출자의 RSA 공개키로 암호화해 둘 다 출력한다.
# 평문은 호출자 쪽 개인키로만 풀린다.
#
#   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out k.pem && openssl pkey -in k.pem -pubout -out k.pub
#   onprem/hosts/ec2-ssm-executor-token.sh <instance-id> k.pub > sealed.txt
#   onprem/hosts/ec2-ssm-executor-token.sh --open k.pem < sealed.txt | gcloud secrets versions add <비밀> --data-file=-
#   rm -f k.pem k.pub sealed.txt
set -euo pipefail

if [ "${1:-}" = "--open" ]; then
  KEY_PEM="${2:?사용: --open <개인키.pem> < sealed.txt}"
  sealed="$(cat)"
  key_b64="$(sed -n 's/^SEALED_KEY=//p' <<<"$sealed")"
  data_b64="$(sed -n 's/^SEALED_DATA=//p' <<<"$sealed")"
  [ -n "$key_b64" ] && [ -n "$data_b64" ] || { echo "SEALED_KEY·SEALED_DATA 줄이 없다" >&2; exit 1; }
  pass="$(base64 -d <<<"$key_b64" | openssl pkeyutl -decrypt -inkey "$KEY_PEM" -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256)"
  base64 -d <<<"$data_b64" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "pass:$pass"
  exit 0
fi

IID="${1:?사용: ec2-ssm-executor-token.sh <instance-id> <공개키.pem>}"
PUB="${2:?공개키 파일(PEM)}"
REGION="${AWS_REGION:-ap-northeast-2}"
pub_b64="$(base64 <"$PUB" | tr -d '\n')"

script=$(
  cat <<EOF
set -euo pipefail
d=\$(mktemp -d); trap 'rm -rf "\$d"' EXIT
echo '$pub_b64' | base64 -d > "\$d/pub.pem"
openssl rand -hex 32 | tr -d '\n' > "\$d/pass"
k3s kubectl -n echo-system get secret echo-executor-token -o jsonpath='{.data.token}' | base64 -d > "\$d/tok"
[ -s "\$d/tok" ] || { echo "토큰이 비었다(install.sh 3-b 확인)" >&2; exit 1; }
echo "SEALED_KEY=\$(openssl pkeyutl -encrypt -pubin -inkey "\$d/pub.pem" -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -in "\$d/pass" | base64 -w0)"
echo "SEALED_DATA=\$(openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass file:"\$d/pass" -in "\$d/tok" | base64 -w0)"
EOF
)
wrapped="cat > /root/echo-token-run.sh <<'ECHO_RUN_EOF'
$script
ECHO_RUN_EOF
bash /root/echo-token-run.sh; rc=\$?; rm -f /root/echo-token-run.sh; exit \$rc"
params="$(python3 -I -c 'import json,sys; print(json.dumps({"commands": [sys.stdin.read()]}))' <<<"$wrapped")"
cid="$(aws ssm send-command --region "$REGION" --instance-ids "$IID" --document-name AWS-RunShellScript \
  --comment "echo executor token (sealed)" --parameters "$params" --query Command.CommandId --output text)"
while :; do
  st="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$IID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$st" in Pending | InProgress | Delayed) sleep 3 ;; *) break ;; esac
done
[ "$st" = "Success" ] || { aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$IID" --query StandardErrorContent --output text >&2; exit 1; }
aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$IID" --query StandardOutputContent --output text | grep '^SEALED_'
