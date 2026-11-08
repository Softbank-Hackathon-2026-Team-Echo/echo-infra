#!/usr/bin/env bash
# 리눅스 기기 한 대를 Echo 온프레 환경으로 만든다(이슈 #2).
#   k3s + 관리 대상 앱(echo-demo-app + PostgreSQL 17 + PgBouncer) + (선택) Cloudflare Tunnel 커넥터
#
# 기기 종류(EC2·맥 안 리눅스 VM·사무실 PC)와 CPU(amd64·arm64)를 가리지 않는다. 기기마다 다른 준비는 hosts/ 에 있다.
# 들어오는 포트를 열지 않는다. 공개 주소는 기기가 Cloudflare 로 나가는 연결(터널)로만 받는다.
# 다시 돌려도 같은 결과가 된다: 있는 것은 그대로 두고 바뀐 값만 반영한다(DB 비밀번호는 처음 한 번만 만든다).
#
#   sudo ./install.sh                                              # 터널 없이(기기 안에서만 확인)
#   sudo DEMO_HOST=demo-onprem-xxxxxxxx.echoport.uk \
#        CF_TUNNEL_CREDENTIALS_FILE=/path/tunnel.json ./install.sh  # 터널로 공개
#
# 환경 변수 (모두 선택)
#   K3S_VERSION                 k3s 버전 (기본 아래 값)
#   DEMO_IMAGE                  앱 이미지. digest 로 고정한다 (echo-demo-app 의 image 워크플로가 GHCR 에 게시)
#   DEMO_HOST                   앱 주소(Ingress host). 터널의 공개 주소와 같아야 한다
#   ECHO_ENVIRONMENT            앱 화면에 보일 환경 이름 (기본 onprem)
#   CF_TUNNEL_CREDENTIALS_FILE  `cloudflared tunnel create` 가 만든 자격 증명 JSON. 없으면 터널을 설치하지 않는다
#   K3S_API_HOST                k3s 창구 공개 주소(터널). 주면 echo-was 실제 실행기가 이 주소로 배포한다(README "echo-was 실행기 연결")
#   SWAP_SIZE_MB                메모리가 3GB 미만이고 스왑이 없으면 만들 크기 (0 이면 만들지 않음)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
K3S_VERSION="${K3S_VERSION:-v1.36.5+k3s1}"
DEMO_IMAGE="${DEMO_IMAGE:-ghcr.io/softbank-hackathon-2026-team-echo/echo-demo-app@sha256:3a8211ce82191fdee4da70d736f4946bf8be84c052bf889f7f5c2e6b596405bd}"
DEMO_HOST="${DEMO_HOST:-demo.onprem.localhost}"
ECHO_ENVIRONMENT="${ECHO_ENVIRONMENT:-onprem}"
CF_TUNNEL_CREDENTIALS_FILE="${CF_TUNNEL_CREDENTIALS_FILE:-}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"
K3S_API_HOST="${K3S_API_HOST:-}"

log() { printf '[onprem] %s\n' "$*"; }
die() {
  printf '[onprem] 오류: %s\n' "$*" >&2
  exit 1
}
kc() { k3s kubectl "$@"; }

# ---------- 0. 기기 확인 ----------
[ "$(id -u)" -eq 0 ] || die "root 로 실행한다 (sudo)"
[ "$(uname -s)" = "Linux" ] || die "리눅스 전용이다. macOS 는 hosts/lima.sh 로 리눅스 VM 을 만든다"
case "$(uname -m)" in
  x86_64 | amd64 | aarch64 | arm64) ;;
  *) die "지원하지 않는 CPU: $(uname -m) (amd64·arm64 만)" ;;
esac
command -v systemctl >/dev/null || die "systemd 가 필요하다 (k3s 서비스)"
command -v curl >/dev/null || die "curl 이 필요하다"

# 값이 매니페스트에 그대로 들어가므로 모양을 먼저 검사한다.
[[ "$DEMO_HOST" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "DEMO_HOST 형식이 아니다: $DEMO_HOST"
[[ "$ECHO_ENVIRONMENT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "ECHO_ENVIRONMENT 형식이 아니다: $ECHO_ENVIRONMENT"
[ -z "$K3S_API_HOST" ] || [[ "$K3S_API_HOST" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "K3S_API_HOST 형식이 아니다: $K3S_API_HOST"
[ -z "$K3S_API_HOST" ] || [ -n "$CF_TUNNEL_CREDENTIALS_FILE" ] || die "K3S_API_HOST 는 터널(CF_TUNNEL_CREDENTIALS_FILE)과 같이 쓴다"
[[ "$DEMO_IMAGE" =~ ^[a-z0-9./_:-]+@sha256:[0-9a-f]{64}$ ]] || die "DEMO_IMAGE 는 digest 로 고정한다 (<이미지>@sha256:...): $DEMO_IMAGE"
if [ -n "$CF_TUNNEL_CREDENTIALS_FILE" ]; then
  [ -r "$CF_TUNNEL_CREDENTIALS_FILE" ] || die "CF_TUNNEL_CREDENTIALS_FILE 을 읽을 수 없다: $CF_TUNNEL_CREDENTIALS_FILE"
  TUNNEL_ID="$(sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([0-9a-f-]\{36\}\)".*/\1/p' "$CF_TUNNEL_CREDENTIALS_FILE")"
  [ -n "$TUNNEL_ID" ] || die "자격 증명 JSON 에 TunnelID 가 없다"
fi

# ---------- 1. 스왑 (작은 기기) ----------
mem_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
if [ "$mem_mb" -lt 3000 ] && [ "$SWAP_SIZE_MB" -gt 0 ] && [ -z "$(swapon --show --noheadings)" ]; then
  log "메모리 ${mem_mb}MB, 스왑 ${SWAP_SIZE_MB}MB 를 만든다 (/swapfile)"
  fallocate -l "${SWAP_SIZE_MB}M" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# ---------- 2. k3s ----------
if command -v k3s >/dev/null && k3s --version | head -n1 | grep -qF "$K3S_VERSION"; then
  log "k3s $K3S_VERSION 이미 있음"
else
  log "k3s $K3S_VERSION 설치"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="server --write-kubeconfig-mode=0600" sh -
fi

wait_for() { # wait_for <설명> <초> <명령...>
  local what="$1" secs="$2"
  shift 2
  for _ in $(seq 1 "$secs"); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "$what 을(를) ${secs}초 안에 확인하지 못했다"
}
# shellcheck disable=SC2016 # 안쪽 셸에서 펼친다
wait_for "노드 등록" 120 sh -c '[ -n "$(k3s kubectl get nodes -o name)" ]'
kc wait --for=condition=Ready node --all --timeout=180s >/dev/null
wait_for "Traefik 인그레스 배치" 300 k3s kubectl -n kube-system get deploy/traefik
kc -n kube-system rollout status deploy/traefik --timeout=180s >/dev/null
log "k3s 준비됨: $(kc get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion} {.items[0].status.nodeInfo.architecture}')"

# ---------- 3. 관리 대상 앱 ----------
render() { # 자리표시를 값으로 바꾼다 (값은 위에서 형식 검사함)
  sed -e "s|__DEMO_IMAGE__|${DEMO_IMAGE}|g" \
    -e "s|__DEMO_HOST__|${DEMO_HOST}|g" \
    -e "s|__ECHO_ENVIRONMENT__|${ECHO_ENVIRONMENT}|g" \
    -e "s|__TUNNEL_ID__|${TUNNEL_ID:-}|g" \
    -e "s|__CONFIG_HASH__|${CONFIG_HASH:-}|g" "$1"
}

# 터널 설정의 창구 규칙 자리(# __K3S_API_RULE__)를 채우거나 지운다.
api_rule() {
  if [ -z "$K3S_API_HOST" ]; then
    grep -v '# __K3S_API_RULE__'
    return
  fi
  awk -v host="$K3S_API_HOST" '
    /# __K3S_API_RULE__/ {
      print "      - hostname: " host
      print "        service: https://kubernetes.default.svc.cluster.local:443"
      print "        originRequest:"
      print "          caPool: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
      print "          originServerName: kubernetes.default.svc.cluster.local"
      next
    }
    { print }'
}

kc apply -f "$HERE/manifests/namespaces.yaml" >/dev/null

# DB 비밀번호는 처음 한 번만 만든다. 이미 초기화된 PostgreSQL 의 비밀번호와 어긋나지 않게 다시 만들지 않는다.
if ! kc -n echo-demo get secret demo-db >/dev/null 2>&1; then
  log "DB 비밀번호 생성 (Secret echo-demo/demo-db)"
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  pw="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  {
    echo "password=${pw}"
    echo "database-url=postgresql://demo:${pw}@demo-pgbouncer:6432/demo"
  } >"$tmp"
  kc -n echo-demo create secret generic demo-db --from-env-file="$tmp" >/dev/null
  rm -f "$tmp"
  unset pw
fi

log "앱 적용: $DEMO_IMAGE ($ECHO_ENVIRONMENT, host $DEMO_HOST)"
render "$HERE/manifests/demo-app.yaml" | kc apply -f - >/dev/null
kc -n echo-demo rollout status statefulset/demo-db --timeout=300s
kc -n echo-demo rollout status deploy/demo-pgbouncer --timeout=180s
kc -n echo-demo rollout status deploy/demo-app --timeout=300s

# ---------- 3-b. echo-was 실행기 신원·권한 (manifests/echo-executor.yaml) ----------
# 정책(ValidatingAdmissionPolicy)을 먼저 받아들이게 한 뒤 토큰이 채워질 때까지 기다린다. 토큰은 화면에 찍지 않는다.
log "echo-was 실행기 신원·권한 적용 (echo-system/echo-executor, 네임스페이스 라벨 정책)"
kc apply -f "$HERE/manifests/echo-executor.yaml" >/dev/null
# 앱 네임스페이스 파드가 노드 권한(privileged·host 네임스페이스·hostPath)을 얻지 못하게 막는다 (manifests/app-pod-guard.yaml)
kc apply -f "$HERE/manifests/app-pod-guard.yaml" >/dev/null
# 앱 네임스페이스 Service 는 ClusterIP 만, externalIPs 없이 (manifests/app-service-guard.yaml)
kc apply -f "$HERE/manifests/app-service-guard.yaml" >/dev/null
# shellcheck disable=SC2016 # 안쪽 셸에서 펼친다
wait_for "실행기 토큰 채움" 60 sh -c '[ -n "$(k3s kubectl -n echo-system get secret echo-executor-token -o jsonpath="{.data.token}")" ]'

# ---------- 4. Cloudflare Tunnel 커넥터 (선택) ----------
if [ -n "$CF_TUNNEL_CREDENTIALS_FILE" ]; then
  log "터널 커넥터 적용 (터널 $TUNNEL_ID)"
  kc -n cloudflared create secret generic tunnel-credentials \
    --from-file=credentials.json="$CF_TUNNEL_CREDENTIALS_FILE" --dry-run=client -o yaml | kc apply -f - >/dev/null
  # 자격 증명이나 설정이 바뀌면 파드를 다시 띄우도록 해시를 파드 주석에 넣는다.
  CONFIG_HASH="$({
    sha256sum "$CF_TUNNEL_CREDENTIALS_FILE"
    sha256sum "$HERE/manifests/cloudflared.yaml"
    echo "$K3S_API_HOST"
  } | sha256sum | cut -c1-16)"
  if [ -n "$K3S_API_HOST" ]; then
    log "터널에 k3s 창구 주소 추가: $K3S_API_HOST → kubernetes.default.svc (클러스터 CA 로 검증)"
  fi
  render "$HERE/manifests/cloudflared.yaml" | api_rule | kc apply -f - >/dev/null
  kc -n cloudflared rollout status deploy/cloudflared --timeout=180s
else
  log "CF_TUNNEL_CREDENTIALS_FILE 없음: 터널은 설치하지 않는다 (기기 안에서만 접속)"
fi

# ---------- 5. 확인 ----------
check() { # check <경로> : Traefik(기기 80 포트)을 거쳐 앱을 부른다
  curl -fsS --max-time 5 -H "Host: ${DEMO_HOST}" "http://127.0.0.1$1"
}
# 앱은 DB 보다 먼저 뜰 수 있다(/healthz 는 DB 를 보지 않음). /readyz 는 PgBouncer 를 거쳐 DB 까지 확인한다.
wait_for "인그레스 경유 /healthz" 60 check /healthz
wait_for "인그레스 경유 /readyz (DB)" 120 check /readyz
info="$(check /api/info)"
log "기기 안 확인: /healthz·/readyz 통과, /api/info $info"
if [ -n "$K3S_API_HOST" ]; then
  # 터널 안쪽 확인: 커넥터가 창구에 닿는지(토큰 없이 부르면 401 이 정상). 바깥 확인은 README.
  log "k3s 창구 공개 주소: https://${K3S_API_HOST}  (DNS: 'cloudflared tunnel route dns ${TUNNEL_ID} ${K3S_API_HOST}')"
fi
if [ -n "$CF_TUNNEL_CREDENTIALS_FILE" ]; then
  log "공개 주소: https://${DEMO_HOST}  (DNS 는 관리 기기에서 'cloudflared tunnel route dns ${TUNNEL_ID} ${DEMO_HOST}', README 참고)"
fi
log "완료"
