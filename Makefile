# 환경 하나를 명령 2개 이내로 세우고 지운다 (NFR-16).
#   make up               : AWS dev init + apply (plan 을 보여 주고 yes 를 물어본다)
#   make up CLOUD=gcp     : GCP dev
#   make down [CLOUD=gcp] : destroy (state 버킷은 남긴다)
#   make plan [CLOUD=gcp] : 바뀔 내용만 본다
#   make check            : fmt · validate · tflint
#   make loadgen-apply|loadgen-on|loadgen-off : 시연용 합성 트래픽 (GKE, entrypoint/loadgen)

CLOUD ?= aws
ROOT  := terraform/environments/$(CLOUD)/dev
export AWS_PROFILE ?= echo

.PHONY: up down plan check init loadgen-apply loadgen-on loadgen-off

init:
	@test -d $(ROOT) || { echo "$(ROOT) 없음: CLOUD 는 aws 또는 gcp"; exit 1; }
	@test -f $(ROOT)/backend.hcl || { echo "$(ROOT)/backend.hcl 없음: backend.hcl.example 을 복사해 채운다"; exit 1; }
	@test -f $(ROOT)/terraform.tfvars || { echo "$(ROOT)/terraform.tfvars 없음: terraform.tfvars.example 을 복사해 채운다"; exit 1; }
	terraform -chdir=$(ROOT) init -input=false -backend-config=backend.hcl

plan: init
	terraform -chdir=$(ROOT) plan -input=false

up: init
	terraform -chdir=$(ROOT) apply -input=false

down: init
	terraform -chdir=$(ROOT) destroy -input=false

check:
	bash scripts/check.sh

# ---------- 시연용 합성 트래픽 (GKE 안, 평소 0 개) ----------
LOADGEN_CTX ?= gke_team-echo-final_asia-northeast3-a_echo-dev-gke

loadgen-apply:
	kubectl --context $(LOADGEN_CTX) apply -k entrypoint/loadgen

loadgen-on: loadgen-apply
	kubectl --context $(LOADGEN_CTX) -n echo-loadgen scale deploy/loadgen --replicas=1
	kubectl --context $(LOADGEN_CTX) -n echo-loadgen rollout status deploy/loadgen --timeout=120s

loadgen-off:
	kubectl --context $(LOADGEN_CTX) -n echo-loadgen scale deploy/loadgen --replicas=0
