#!/usr/bin/env bash
# 템플릿(manifests/)에 values.env 를 채워 클러스터별 적용 파일(deploy/<클러스터>/)을 만든다 (인프라 12.2).
# 적용 파일도 커밋한다 → 저장소만 보고 운영에 무엇이 올라가 있는지 알 수 있게.
# 사용: replication/cutover-job/deploy/render.sh          다시 만들기
#       replication/cutover-job/deploy/render.sh --check  커밋된 파일이 템플릿·값과 같은지만 확인(다르면 종료 1)
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source values.env
[[ $CUTOVER_IMAGE == *@sha256:* ]] || { echo "CUTOVER_IMAGE 는 @sha256 digest 여야 한다(VAP 가 태그 이미지를 막음)" >&2; exit 1; }

out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
mkdir -p "$out/gcp-seoul" "$out/aws-tokyo"
head="# 생성 파일 — 고치지 말고 manifests/ 나 values.env 를 고친 뒤 render.sh 를 돌린다."
for f in echo-data-rbac.yaml gke-binding.yaml; do { echo "$head"; cat "../manifests/$f"; } > "$out/gcp-seoul/$f"; done
{ echo "$head"; sed -e "s|__CUTOVER_GSA__|$CUTOVER_GSA|g" -e "s|__CUTOVER_IMAGE__|$CUTOVER_IMAGE|g" ../manifests/echo-ops.yaml; } > "$out/gcp-seoul/echo-ops.yaml"
for f in echo-data-rbac.yaml eks-binding.yaml; do { echo "$head"; cat "../manifests/$f"; } > "$out/aws-tokyo/$f"; done
cp gcp-seoul/kustomization.yaml "$out/gcp-seoul/" 2>/dev/null || true
cp aws-tokyo/kustomization.yaml "$out/aws-tokyo/" 2>/dev/null || true

if grep -rq "__CUTOVER_" "$out"; then echo "채워지지 않은 자리 표시가 남았다" >&2; exit 1; fi

if [[ ${1:-} == --check ]]; then
  diff -r "$out/gcp-seoul" gcp-seoul && diff -r "$out/aws-tokyo" aws-tokyo && echo "deploy/ = manifests/ + values.env" && exit 0
  echo "deploy/ 가 템플릿·값과 다르다 → render.sh 를 다시 돌려 커밋" >&2; exit 1
fi
for c in gcp-seoul aws-tokyo; do mkdir -p "$c"; cp "$out/$c"/*.yaml "$c/"; done
echo "만듦: deploy/gcp-seoul (echo-data-rbac · echo-ops · gke-binding), deploy/aws-tokyo (echo-data-rbac · eks-binding)"
