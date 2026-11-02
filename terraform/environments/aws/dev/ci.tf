# GitHub Actions 가 장기 키 없이 plan 을 돌리는 역할. apply 권한은 주지 않는다.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# state 버킷 이름은 terraform/bootstrap/aws 와 같은 규칙으로 계산한다 (tfvars 에 다시 적지 않는다).
data "aws_caller_identity" "current" {}

locals {
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_iam_role" "ci_plan" {
  name = "${local.name}-ci-plan"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        # main 브랜치와 PR 에서만 받는다. 다른 브랜치 push 로는 역할을 못 받는다.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_repository}:ref:refs/heads/main",
            "repo:${var.github_repository}:pull_request",
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ci_plan_read" {
  role       = aws_iam_role.ci_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# plan 은 state 를 읽고 잠금 파일(.tflock)을 쓰고 지운다.
resource "aws_iam_role_policy" "ci_plan_state" {
  name = "terraform-state"
  role = aws_iam_role.ci_plan.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${local.state_bucket}"
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${local.state_bucket}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${local.state_bucket}/*.tflock"
      },
    ]
  })
}
