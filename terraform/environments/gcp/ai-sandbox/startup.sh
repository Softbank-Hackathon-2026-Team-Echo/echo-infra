#!/usr/bin/env bash
# AI 샌드박스 VM 첫 준비: Docker 만 설치한다. 러너 코드·키·토큰은 여기서 다루지 않는다.
set -euo pipefail

if command -v docker >/dev/null 2>&1; then
  exit 0
fi

# 나가는 연결은 443 만 열려 있어 apt 저장소를 https 로 받는다.
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  if [ -f "$f" ]; then
    sed -i -e 's|http://deb.debian.org|https://deb.debian.org|g' \
      -e 's|http://security.debian.org|https://security.debian.org|g' "$f"
  fi
done

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker.io
systemctl enable --now docker
