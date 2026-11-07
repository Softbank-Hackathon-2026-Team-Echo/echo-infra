#!/usr/bin/env bash
# 컷오버 Job 진입점 (인프라 12.2, echo-infra#67).
# 1) kubeconfig 에 두 컨텍스트를 만든다: B = 이 GKE 클러스터(in-cluster SA 토큰), A = EKS(Google ID 토큰 → AWS 역할 → EKS 토큰)
# 2) A·B Postgres 외부 주소를 각 클러스터의 Service echo-pg-external 에서 읽는다
# 3) KIND 에 맞는 스크립트로 넘어간다(exec: 신호가 스크립트에 바로 가서 쓰기 정지 중이면 RESUME 한다)
# 입력(Job 환경 변수, VAP 가 이 셋만 허용): KIND=cutover|rollback|promote · PLAN_ID=<uuid>(선택) · ALLOW_PROMOTE=true|false
# 종료 코드는 스크립트의 것을 그대로 쓴다(0 끝남 · 1 바뀐 것 없음 · 2 부분 상태). 진입 단계 실패는 1(아무것도 바꾸지 않음).
# 로그에는 토큰·자격 증명·접속 문자열을 찍지 않는다(set -x 금지).
set -euo pipefail
S=/opt/echo/scripts
case ${KIND:-} in
  cutover) script=cutover.sh ;;
  rollback) script=rollback.sh ;;
  promote) script=promote.sh ;;
  *) echo "[진입] KIND 는 cutover · rollback · promote 중 하나다" >&2; exit 1 ;;
esac
SA=/var/run/secrets/kubernetes.io/serviceaccount
umask 077

# B: 기본은 이 클러스터(in-cluster SA 토큰). 토큰은 파일 경로로만 넘긴다(kubeconfig 에 값을 적지 않음, 회전돼도 그대로).
# 이미지에 B_GKE_CLUSTER(projects/<p>/locations/<l>/clusters/<c>)가 있으면 DB(echo-data)가 다른 GKE 클러스터에 있다
# (인프라 16 고객 클러스터 분리, echo-infra#94) → 이 KSA 에 묶인 GSA 의 액세스 토큰으로 GKE API 에서 주소·CA 를 읽어 그 클러스터를 B 로 쓴다.
# GSA 권한: 프로젝트 container.clusterViewer(주소 읽기·인증) + 그 클러스터 echo-data 의 RoleBinding(User) 뿐.
B_SERVER="https://kubernetes.default.svc"; B_CA="${SA}/ca.crt"; B_TOKEN_FILE="${SA}/token"
if [[ -n ${B_GKE_CLUSTER:-} ]]; then
  B_CA=/tmp/b-ca.crt; B_TOKEN_FILE=/tmp/b-token
  curl -fsS --max-time 5 -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | jq -r .access_token > "$B_TOKEN_FILE" \
    || { echo "[진입] B 클러스터용 Google 토큰을 받지 못했다 — 바뀐 것 없음" >&2; exit 1; }
  printf 'Authorization: Bearer %s\n' "$(cat "$B_TOKEN_FILE")" > /tmp/b-auth
  b_info=$(curl -fsS --max-time 10 -H @/tmp/b-auth "https://container.googleapis.com/v1/${B_GKE_CLUSTER}") \
    || { echo "[진입] B 클러스터($B_GKE_CLUSTER) 정보를 읽지 못했다 — 바뀐 것 없음" >&2; exit 1; }
  rm -f /tmp/b-auth
  B_SERVER="https://$(jq -r .endpoint <<<"$b_info")"
  jq -r .masterAuth.clusterCaCertificate <<<"$b_info" | base64 -d > "$B_CA"
  echo "[진입] B = 다른 GKE 클러스터 ${B_GKE_CLUSTER##*/}"
fi
cat > "$KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${B_CTX}
    cluster: { server: "${B_SERVER}", certificate-authority: "${B_CA}" }
users:
  - name: ${B_CTX}
    user: { tokenFile: "${B_TOKEN_FILE}" }
contexts:
  - name: ${B_CTX}
    context: { cluster: "${B_CTX}", user: "${B_CTX}" }
current-context: ${B_CTX}
EOF

# A: GKE 메타데이터 서버가 이 KSA 에 묶인 GSA 의 ID 토큰을 준다 → AWS STS 로 cutover 전용 역할을 받는다.
# 도쿄가 죽어 있으면 여기서 실패할 수 있다. 그때는 A 컨텍스트 없이 계속 간다 → 스크립트의 a_reachable 이 "닿지 않음"으로 본다.
a_context() {
  [[ -n ${AWS_ROLE_ARN:-} ]] || { echo "[진입] AWS_ROLE_ARN 이 이미지에 없다" >&2; return 1; }
  local tok creds
  tok=$(curl -fsS --max-time 5 -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=sts.amazonaws.com&format=full") || return 1
  creds=$(aws sts assume-role-with-web-identity --role-arn "$AWS_ROLE_ARN" --role-session-name "echo-cutover-${PLAN_ID:-manual}" \
    --web-identity-token "$tok" --duration-seconds 3600 \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>/dev/null) || return 1
  read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$creds"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION" --alias "$A_CTX" >/dev/null 2>&1 || return 1
  kubectl config use-context "$B_CTX" >/dev/null
}
if a_context; then echo "[진입] A($A_CTX) 컨텍스트 준비"; a_ok=1
else echo "[진입] A($A_CTX) 에 붙지 못했다(도쿄 장애이거나 자격 증명 문제)"; a_ok=0; fi

svc_addr() {  # svc_addr <ctx> <jsonpath 키 ip|hostname>
  kubectl --request-timeout=10s --context "$1" -n "$NS" get svc echo-pg-external -o "jsonpath={.status.loadBalancer.ingress[0].$2}"
}
B_HOST=$(svc_addr "$B_CTX" ip) || { echo "[진입] B 주소를 읽지 못했다 — 바뀐 것 없음" >&2; exit 1; }
A_HOST=""
if [[ $a_ok == 1 ]]; then A_HOST=$(svc_addr "$A_CTX" hostname || true); fi
export B_HOST A_HOST A_CTX B_CTX NS
export ALLOW_PROMOTE=${ALLOW_PROMOTE:-false}

case $KIND in
  rollback) [[ -n $A_HOST ]] || { echo "[진입] 롤백은 A 가 살아 있어야 한다(A 주소 없음) — 바뀐 것 없음" >&2; exit 1; } ;;
esac
echo "[진입] KIND=$KIND PLAN_ID=${PLAN_ID:-없음} ALLOW_PROMOTE=$ALLOW_PROMOTE → $script"
exec "$S/$script"
