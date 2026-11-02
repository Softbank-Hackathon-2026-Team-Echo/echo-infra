# echo-was(API 서버) 진입점인 ALB 를 만드는 AWS Load Balancer Controller 의 IAM 권한.
# 11/2 에 손으로 만든 리소스(태그 managed-by=jimin-manual)를 Terraform 관리로 옮긴다.
# 컨트롤러 설치(Helm)는 modules/alb-controller-iam/README.md 참고.

locals {
  alb_controller_cluster_name = "echo-dev-eks"
}

module "alb_controller_iam" {
  source = "../../../modules/alb-controller-iam"

  cluster_name = local.alb_controller_cluster_name
  role_name    = "echo-was-lbc"
  policy_name  = "echo-was-lbc-policy"
}

# 이미 있는 리소스를 state 로 가져온다. 첫 apply 한 번이면 끝나므로 그 뒤에 이 블록들은 지워도 된다.
# plan 에서 "4 to import" 이고 바뀌는 것이 태그(managed-by)뿐인지 확인한 뒤 apply 한다.
import {
  to = module.alb_controller_iam.aws_iam_policy.this
  id = "arn:aws:iam::706878591119:policy/echo-was-lbc-policy"
}

import {
  to = module.alb_controller_iam.aws_iam_role.this
  id = "echo-was-lbc"
}

import {
  to = module.alb_controller_iam.aws_iam_role_policy_attachment.this
  id = "echo-was-lbc/arn:aws:iam::706878591119:policy/echo-was-lbc-policy"
}

import {
  to = module.alb_controller_iam.aws_eks_pod_identity_association.this
  id = "echo-dev-eks,a-oft2qy6efx5upkol0"
}
