# 컷오버 Job 전용 AWS 역할 (인프라 12.2, echo-infra#67 · 보안 #24 김형래 11/5 리뷰 2번).
# 서울 GKE 의 컷오버 GSA(gcp/dev/cutover.tf)가 Google ID 토큰으로 이 역할을 받고, EKS 에는 access entry 로 들어간다.
#  - 신뢰 정책은 컷오버 GSA 하나만(배포 실행기 역할과 따로)
#  - access entry 에는 클러스터 정책을 붙이지 않고 쿠버네티스 그룹 echo-cutover 만 준다
#    → 권한은 echo-data 네임스페이스 Role 하나(replication/cutover-job/manifests/echo-data-rbac.yaml + eks-binding.yaml)
# cutover_google_service_account_id 가 비어 있으면 아무것도 만들지 않는다(GCP 루트를 먼저 apply 한다).
locals {
  cutover_enabled = var.cutover_google_service_account_id != ""
}

resource "aws_iam_role" "cutover" {
  count = local.cutover_enabled ? 1 : 0

  name = "${local.name}-cutover"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.google.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # ci.tf executor 와 같은 규칙: aud = 토큰 azp(GSA 고유 ID), oaud = 메타데이터 서버에 준 audience.
          "accounts.google.com:aud"  = var.cutover_google_service_account_id
          "accounts.google.com:oaud" = "sts.amazonaws.com"
          "accounts.google.com:sub"  = var.cutover_google_service_account_id
        }
      }
    }]
  })
}

# aws eks update-kubeconfig 가 클러스터 주소·CA 를 읽는 데만 쓴다.
resource "aws_iam_role_policy" "cutover_eks" {
  count = local.cutover_enabled ? 1 : 0

  name = "eks-describe"
  role = aws_iam_role.cutover[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = aws_eks_cluster.this.arn
    }]
  })
}

resource "aws_eks_access_entry" "cutover" {
  count = local.cutover_enabled ? 1 : 0

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = aws_iam_role.cutover[0].arn
  kubernetes_groups = ["echo-cutover"]
  type              = "STANDARD"
}
