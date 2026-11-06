#!/usr/bin/env bash
# 컷오버 Job 권한·VAP 시험 (인프라 12.2, echo-infra#67 · 보안 #24 근거). Docker 로 k3s 한 대를 띄워 매니페스트를 그대로 적용하고
#  1) RBAC: kubectl auth can-i (Job KSA · EKS 그룹 · echo-was KSA)
#  2) VAP: echo-was 신원으로 Job 을 server dry-run 해서 허용/거부
#  3) 정상 Job 을 실제로 만들어 Job 컨트롤러가 만든 Pod 가 VAP 를 통과하는지
# 사용: replication/cutover-job/tests/policy-test.sh   (KEEP=1 이면 k3s 를 남긴다)
set -uo pipefail
cd "$(dirname "$0")/.."
C=echo-t-k3s
IMG='registry.local/echo/cutover@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
pass=0 fail=0
ok()  { echo "  ✅ $*"; pass=$((pass+1)); }
bad() { echo "  ❌ $*"; fail=$((fail+1)); }
k()   { docker exec -i "$C" kubectl "$@"; }
canI() { local want=$1; shift; local got; got=$(k auth can-i "$@" 2>/dev/null); [[ $got == "$want" ]] && ok "can-i $* → $got" || bad "can-i $*: 기대 $want, 실제 $got"; }
cleanup() { [[ ${KEEP:-} == 1 ]] || docker rm -f "$C" >/dev/null 2>&1; }
trap cleanup EXIT

echo "== 준비: k3s, 네임스페이스, 매니페스트 적용"
docker rm -f "$C" >/dev/null 2>&1
docker run -d --privileged --name "$C" rancher/k3s:v1.36.5-k3s1 server --disable traefik --disable metrics-server --disable servicelb >/dev/null
for i in $(seq 1 90); do k get --raw /readyz >/dev/null 2>&1 && break; sleep 1; done
k create namespace echo-data >/dev/null; k create namespace echo-was >/dev/null; k -n echo-was create serviceaccount echo-was >/dev/null
k apply -f - < manifests/echo-data-rbac.yaml >/dev/null
sed -e "s|__CUTOVER_GSA__|echo-dev-cutover@example.iam.gserviceaccount.com|" -e "s|__CUTOVER_IMAGE__|$IMG|" manifests/echo-ops.yaml | k apply -f - >/dev/null
k apply -f - < manifests/gke-binding.yaml >/dev/null
k apply -f - < manifests/eks-binding.yaml >/dev/null
sleep 3

echo "== 1. RBAC — 컷오버 Job 신원 (GKE: KSA echo-ops/echo-cutover)"
J=system:serviceaccount:echo-ops:echo-cutover
canI yes create pods --subresource=exec -n echo-data --as=$J
canI yes get pods -n echo-data --as=$J
canI yes patch configmaps/echo-pgbouncer-ini -n echo-data --as=$J
canI no  patch configmaps/other -n echo-data --as=$J
canI yes get services/echo-pg-external -n echo-data --as=$J
canI no  get secrets -n echo-data --as=$J
canI no  list secrets -n echo-data --as=$J
canI no  create pods --subresource=exec -n echo-was --as=$J
canI no  create pods --subresource=exec -n kube-system --as=$J
canI no  delete pods -n echo-data --as=$J
canI no  create jobs -n echo-ops --as=$J

echo "== 2. RBAC — 컷오버 신원 (EKS: access entry 그룹 echo-cutover)"
canI yes create pods --subresource=exec -n echo-data --as=echo-cutover-role --as-group=echo-cutover
canI no  get secrets -n echo-data --as=echo-cutover-role --as-group=echo-cutover
canI no  create pods --subresource=exec -n kube-system --as=echo-cutover-role --as-group=echo-cutover
canI no  get nodes --as=echo-cutover-role --as-group=echo-cutover

echo "== 3. RBAC — echo-was (Job 만들기·읽기만)"
W=system:serviceaccount:echo-was:echo-was
canI yes create jobs -n echo-ops --as=$W
canI yes get pods --subresource=log -n echo-ops --as=$W
canI no  create pods -n echo-ops --as=$W
canI no  delete jobs -n echo-ops --as=$W
echo "     (운영 GKE 에서 echo-was 는 프로젝트 단위 container.developer 라 이 Role 보다 넓다 → 실제 경계는 VAP, 권한 축소는 #24 후속)"

job() {  # job <이름> [sed 식…] → Job YAML
  local name=$1; shift
  sed -e "s|__CUTOVER_IMAGE__|$IMG|" -e "s|echo-cutover-11111111-1|$name|" "$@" job.example.yaml
}
vap() {  # vap <allow|deny> <설명> <이름> [sed 식…]
  local want=$1 why=$2; shift 2; local out rc
  out=$(job "$@" | k create --dry-run=server --as=$W -f - 2>&1); rc=$?
  if [[ $want == allow && $rc == 0 ]]; then ok "허용: $why"
  elif [[ $want == deny && $rc != 0 && $out == *ValidatingAdmissionPolicy* ]]; then ok "거부: $why — $(grep -o "denied request: .*" <<<"$out" | head -1 | cut -c1-80)"
  else bad "$why: 기대 $want, rc=$rc $(head -c 200 <<<"$out")"; fi
}

echo "== 4. VAP — echo-was 가 만드는 Job 모양 (server dry-run)"
vap allow "정상 Job (cutover)" ok-1
vap allow "정상 Job (promote, ALLOW_PROMOTE=true)" ok-2 -e 's|value: cutover|value: promote|' -e 's|value: "false"|value: "true"|'
vap deny  "다른 이미지" bad-image -e "s|@sha256:0123|@sha256:9999|"
vap deny  "태그 이미지(digest 아님)" bad-tag -e "s|image: .*|image: registry.local/echo/cutover:latest|"
vap deny  "다른 SA" bad-sa -e "s|serviceAccountName: echo-cutover|serviceAccountName: default|"
vap deny  "환경 변수 추가" bad-env -e 's|- { name: KIND, value: cutover }|- { name: KIND, value: cutover }\n            - { name: B_HOST, value: 1.2.3.4 }|'
vap deny  "KIND 다른 값" bad-kind -e 's|value: cutover|value: drop|'
vap deny  "ALLOW_PROMOTE 다른 값" bad-allow -e 's|value: "false"|value: "yes"|'
vap deny  "PLAN_ID 가 uuid 아님" bad-plan -e "s|value: 11111111-1111-4111-8111-111111111111|value: \"x' OR 1=1\"|"
vap deny  "command 덮어쓰기" bad-cmd -e 's|          image: \(.*\)|          image: \1\n          command: [sh, -c, "kubectl get secrets -A"]|'
vap deny  "envFrom(Secret)" bad-envfrom -e 's|          env:|          envFrom: [{ secretRef: { name: echo-pg } }]\n          env:|'
vap deny  "valueFrom(Secret)" bad-valuefrom -e 's|- { name: PLAN_ID, value: 11111111-1111-4111-8111-111111111111 }|- { name: PLAN_ID, valueFrom: { secretKeyRef: { name: echo-pg, key: x } } }|'
vap deny  "hostPath 볼륨" bad-hostpath -e 's|      containers:|      volumes: [{ name: h, hostPath: { path: / } }]\n      containers:|'
vap deny  "initContainer" bad-init -e 's|      containers:|      initContainers: [{ name: i, image: busybox }]\n      containers:|'
vap deny  "privileged" bad-priv -e 's|allowPrivilegeEscalation: false|allowPrivilegeEscalation: true\n            privileged: true|' -e 's|capabilities: { drop: \[ALL\] }|capabilities: { drop: [] }|'
vap deny  "hostNetwork" bad-hostnet -e 's|      restartPolicy: Never|      restartPolicy: Never\n      hostNetwork: true|'

echo "== 5. 정상 Job 을 실제로 만들면 Job 컨트롤러의 Pod 도 VAP 를 통과한다 (SA 토큰 볼륨만)"
job real-1 | k create --as=$W -f - >/dev/null 2>&1 && ok "Job 생성" || bad "Job 생성 실패"
for i in $(seq 1 30); do n=$(k -n echo-ops get pods -l job-name=real-1 --no-headers 2>/dev/null | wc -l); [[ $n -ge 1 ]] && break; sleep 1; done
[[ ${n:-0} -ge 1 ]] && ok "Pod 생성됨 (이미지는 가짜라 Pull 실패는 정상)" || bad "Pod 가 생기지 않음: $(k -n echo-ops describe job real-1 | grep -iE 'denied|error' | head -2)"
out=$(sed -e "s|__CUTOVER_IMAGE__|registry.local/evil@sha256:0000000000000000000000000000000000000000000000000000000000000000|" job.example.yaml | \
  python -I -c 'import sys; print(sys.stdin.read())' | k create --dry-run=server -f - 2>&1)
[[ $out == *ValidatingAdmissionPolicy* ]] && ok "관리자라도 다른 이미지 Job 은 거부" || bad "관리자 우회: $out"

echo; echo "결과: 통과 $pass · 실패 $fail"
[[ $fail == 0 ]]
