# AWS Load Balancer Controller 가 ALB 를 만들고 관리하는 데 쓰는 IAM 권한.
# 권한은 EKS Pod Identity 로 ServiceAccount 에 연결한다(IRSA 용 OIDC 공급자 불필요).
# 컨트롤러 자체(Helm 차트)는 이 모듈 범위 밖이다. README.md 참고.

# 정책 본문은 컨트롤러 공식 저장소 v3.6.2 의 docs/install/iam_policy.json 이다.
resource "aws_iam_policy" "this" {
  name   = var.policy_name
  policy = file("${path.module}/policy.json")
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}

resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn

  depends_on = [aws_iam_role_policy_attachment.this]
}
