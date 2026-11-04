# AWS Load Balancer Controller 권한 (공유 문 ALB, cluster-addons/eks/anchor-ingress.yaml).
# 11/2 에 CLI 로 먼저 만든 역할·정책·Pod Identity 연결을 import 로 가져온다(인프라 11 재구축 리허설에서 발견: 코드 밖이면 재구축 때 빠진다).
# 컨트롤러 자체(helm chart aws-load-balancer-controller 3.6.2)는 cluster-addons/README.md 의 명령으로 올린다. 권한은 Pod Identity 로
# kube-system/aws-load-balancer-controller 서비스 계정에만 간다(노드 역할엔 없음).
# 이름: dev 는 기존 이름(echo-was-lbc)을 tfvars 로 유지해 재생성을 피한다. 새 환경은 비워 두면 <cluster>-lbc.
locals {
  lbc_role_name   = var.lbc_role_name != "" ? var.lbc_role_name : "${local.cluster_name}-lbc"
  lbc_policy_name = var.lbc_policy_name != "" ? var.lbc_policy_name : "${local.cluster_name}-lbc-policy"
}

# 정책 문서는 컨트롤러 공식 iam_policy.json(v2.x) 그대로(policies/aws-load-balancer-controller.json).
resource "aws_iam_policy" "lbc" {
  name   = local.lbc_policy_name
  policy = file("${path.module}/policies/aws-load-balancer-controller.json")
}

resource "aws_iam_role" "lbc" {
  name = local.lbc_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn

  depends_on = [aws_eks_addon.this] # eks-pod-identity-agent 애드온
}
