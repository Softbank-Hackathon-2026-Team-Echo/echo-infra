#!/usr/bin/env bash
# Terraform 품질 게이트: fmt → validate → tflint. 커밋 전 훅과 사람이 같은 명령을 쓴다.
set -euo pipefail

cd "$(dirname "$0")/.."

# 루트마다 provider 를 따로 받지 않게 캐시를 같이 쓴다.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

roots=()
while IFS= read -r dir; do
  roots+=("$dir")
done < <(find terraform -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; | sort -u)

if [ ${#roots[@]} -eq 0 ]; then
  echo "check: .tf 파일 없음, 건너뜀"
  exit 0
fi

echo "check: terraform fmt"
terraform fmt -check -recursive terraform

for dir in "${roots[@]}"; do
  echo "check: terraform validate ${dir}"
  # backend 로 init 된 .terraform 을 쓰지 않는다. 검사는 클라우드 자격 증명 없이 돈다.
  # 루트별 고정 디렉터리(.gitignore)라 두 번째부터는 init 이 거의 바로 끝난다.
  data_dir="${dir}/.terraform-check"
  TF_DATA_DIR="$data_dir" terraform -chdir="$dir" init -backend=false -input=false -no-color >/dev/null
  TF_DATA_DIR="$data_dir" terraform -chdir="$dir" validate -no-color
done

if command -v tflint >/dev/null 2>&1; then
  echo "check: tflint"
  tflint --init >/dev/null
  tflint --recursive --config "$(pwd)/.tflint.hcl"
else
  echo "check: tflint 없음, 건너뜀 (README 빠른 시작 참고)"
fi
