#!/usr/bin/env bash
# AI 샌드박스 VM 준비 (부팅마다 돌아도 안전하다). 러너 코드·키·토큰은 여기서 다루지 않는다.
#   1) Docker   2) git·Trivy — 승인된 패치를 적용·빌드·스캔하는 반영 실행(echo-ai-agent #19, AI 에이전트 5)에 필요
#   3) 러너 사용자(echo-runner)를 docker 그룹에 — 러너가 빌드·스캔 컨테이너를 띄운다.
#      docker 그룹은 이 VM 의 root 와 같다. VM 은 운영과 연결 없는 VPC·역할 0개 SA 라 영향은 VM 안에 갇힌다.
set -euo pipefail

# 나가는 연결은 443 만 열려 있어 apt 저장소를 https 로 받는다.
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  if [ -f "$f" ]; then
    sed -i -e 's|http://deb.debian.org|https://deb.debian.org|g' \
      -e 's|http://security.debian.org|https://security.debian.org|g' "$f"
  fi
done

need_update=1
apt_install() {
  if [ "$need_update" = 1 ]; then apt-get update -qq; need_update=0; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@"
}

# 1) Docker
if ! command -v docker >/dev/null 2>&1; then
  apt_install docker.io
  systemctl enable --now docker
fi

# 2) git · Trivy (Aqua 공식 apt 저장소, https)
command -v git >/dev/null 2>&1 || apt_install git ca-certificates
if ! command -v trivy >/dev/null 2>&1; then
  apt_install ca-certificates curl gnupg
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor --yes -o /usr/share/keyrings/trivy.gpg
  echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" > /etc/apt/sources.list.d/trivy.list
  need_update=1
  apt_install trivy
fi

# 3) 러너 사용자 docker 권한 (러너가 깔린 뒤에만; 바뀌면 러너 재시작)
if id echo-runner >/dev/null 2>&1 && ! id -nG echo-runner | tr ' ' '\n' | grep -qx docker; then
  usermod -aG docker echo-runner
  systemctl try-restart echo-precheck-runner.service || true
fi
