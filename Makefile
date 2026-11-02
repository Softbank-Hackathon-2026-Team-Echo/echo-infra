# 환경 하나를 명령 2개 이내로 세우고 지운다 (NFR-16).
#   make up    : init + apply (plan 을 보여 주고 yes 를 물어본다)
#   make down  : destroy (state 버킷은 남긴다)
#   make plan  : 바뀔 내용만 본다
#   make check : fmt · validate · tflint

AWS_DEV := terraform/environments/aws/dev
export AWS_PROFILE ?= echo

.PHONY: up down plan check init

init:
	@test -f $(AWS_DEV)/backend.hcl || { echo "$(AWS_DEV)/backend.hcl 없음: backend.hcl.example 을 복사해 채운다"; exit 1; }
	@test -f $(AWS_DEV)/terraform.tfvars || { echo "$(AWS_DEV)/terraform.tfvars 없음: terraform.tfvars.example 을 복사해 채운다"; exit 1; }
	terraform -chdir=$(AWS_DEV) init -input=false -backend-config=backend.hcl

plan: init
	terraform -chdir=$(AWS_DEV) plan -input=false

up: init
	terraform -chdir=$(AWS_DEV) apply -input=false

down: init
	terraform -chdir=$(AWS_DEV) destroy -input=false

check:
	bash scripts/check.sh
