#!/usr/bin/env bash
# macOS 기기를 온프레로 쓸 때: Lima 리눅스 VM(Ubuntu 24.04) 하나를 만들고 그 안에서 install.sh 를 돌린다.
# 노트북을 들고 가서 "이 노트북이 온프레"라고 보여 줄 때 쓴다. CPU 는 맥 그대로(arm64)다.
#
#   brew install lima
#   onprem/hosts/lima.sh                                   # VM 이름 echo-onprem
#   DEMO_HOST=... CF_TUNNEL_CREDENTIALS_FILE=~/tunnel.json onprem/hosts/lima.sh
#   limactl delete -f echo-onprem                          # 지우기
#
# 환경 변수는 install.sh 와 같다. LIMA_VM(기본 echo-onprem)·LIMA_CPUS(2)·LIMA_MEMORY(4, GiB)·LIMA_DISK(20, GiB).
set -euo pipefail

ONPREM="$(cd "$(dirname "$0")/.." && pwd)"
VM="${LIMA_VM:-echo-onprem}"
command -v limactl >/dev/null || {
  echo "limactl 없음: brew install lima" >&2
  exit 1
}

if ! limactl list -q 2>/dev/null | grep -qx "$VM"; then
  limactl create --name "$VM" --tty=false \
    --cpus "${LIMA_CPUS:-2}" --memory "${LIMA_MEMORY:-4}" --disk "${LIMA_DISK:-20}" \
    template:ubuntu-24.04
fi
[ "$(limactl list --format '{{.Status}}' "$VM")" = "Running" ] || limactl start --tty=false "$VM"

# 맥 쪽 파일을 VM 안으로 복사한다(홈 공유 설정에 기대지 않는다).
limactl shell "$VM" -- bash -c 'rm -rf /tmp/echo-onprem && mkdir -p /tmp/echo-onprem'
limactl copy -r "$ONPREM/install.sh" "$ONPREM/manifests" "$VM:/tmp/echo-onprem/"
creds=""
if [ -n "${CF_TUNNEL_CREDENTIALS_FILE:-}" ]; then
  limactl copy "$CF_TUNNEL_CREDENTIALS_FILE" "$VM:/tmp/echo-onprem/tunnel.json"
  creds=/tmp/echo-onprem/tunnel.json
fi

pass=()
for v in K3S_VERSION DEMO_IMAGE DEMO_HOST ECHO_ENVIRONMENT SWAP_SIZE_MB; do
  [ -n "${!v:-}" ] && pass+=("$v=${!v}")
done
[ -n "$creds" ] && pass+=("CF_TUNNEL_CREDENTIALS_FILE=$creds")

# 자격 증명 사본은 설치가 끝나면(실패해도) 지운다. 클러스터 Secret 에만 남는다.
# ${pass[@]+...}: macOS 기본 bash 3.2 는 빈 배열을 set -u 에서 오류로 본다.
limactl shell "$VM" -- sudo env ${pass[@]+"${pass[@]}"} bash -c 'trap "rm -f /tmp/echo-onprem/tunnel.json" EXIT; bash /tmp/echo-onprem/install.sh'
