# GitHub Actions 가 장기 키 없이 plan 을 돌리는 역할. apply 권한은 주지 않는다.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# state 버킷 이름은 terraform/bootstrap/aws 와 같은 규칙으로 계산한다 (tfvars 에 다시 적지 않는다).
data "aws_caller_identity" "current" {}

locals {
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  # GitHub OIDC sub 는 두 형식이 온다: 이름 형식 repo:ORG/NAME:... 과 불변 ID 형식 repo:ORG@<id>/NAME@<id>:... (2026-11 조직 저장소에서 확인).
  # 둘 다 허용한다. ID 는 와일드카드로 두되 조직·저장소 이름은 고정한다.
  github_sub = { for r in distinct(concat([var.github_repository], var.ci_build_repositories)) : r => {
    main = [
      "repo:${r}:ref:refs/heads/main",
      "repo:${split("/", r)[0]}@*/${split("/", r)[1]}@*:ref:refs/heads/main",
    ]
    plan = [
      "repo:${r}:ref:refs/heads/main",
      "repo:${r}:pull_request",
      "repo:${split("/", r)[0]}@*/${split("/", r)[1]}@*:ref:refs/heads/main",
      "repo:${split("/", r)[0]}@*/${split("/", r)[1]}@*:pull_request",
    ]
  } }
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
          "token.actions.githubusercontent.com:sub" = local.github_sub[var.github_repository].plan
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

# ---------- 빌드 실행기: GitHub Actions → ECR push ----------
# echo-was 저장소의 main 브랜치 워크플로만 받는다. 같은 digest 를 GCP Artifact Registry 에도 넣는다(gcp 루트 ci_build).
resource "aws_iam_role" "ci_build" {
  name = "${local.name}-ci-build"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = flatten([for r in var.ci_build_repositories : local.github_sub[r].main])
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ci_build_ecr" {
  name = "ecr-push"
  role = aws_iam_role.ci_build.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = [for r in aws_ecr_repository.this : r.arn]
      },
    ]
  })
}

# ---------- 배포 실행기: GKE 위 echo-was 일꾼 → EKS ----------
# 일꾼은 관제탑 GSA 의 Google ID 토큰(audience=sts.amazonaws.com)으로 이 역할을 받는다(AssumeRoleWithWebIdentity).
# GKE 안에 AWS 키를 두지 않는다(NFR-17). 토큰은 GKE 메타데이터 서버 /instance/service-accounts/default/identity 에서 받는다.
resource "aws_iam_openid_connect_provider" "google" {
  count          = var.executor_google_service_account_id != "" ? 1 : 0
  url            = "https://accounts.google.com"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "executor" {
  count = var.executor_google_service_account_id != "" ? 1 : 0
  name  = "${local.name}-executor"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.google[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "accounts.google.com:aud" = "sts.amazonaws.com"
          "accounts.google.com:sub" = var.executor_google_service_account_id
        }
      }
    }]
  })
}

# kubeconfig 를 만들 때 클러스터 정보만 읽는다. 쿠버네티스 안 권한은 Access Entry 가 준다.
resource "aws_iam_role_policy" "executor_eks" {
  count = var.executor_google_service_account_id != "" ? 1 : 0
  name  = "eks-describe"
  role  = aws_iam_role.executor[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}

# 실행기는 서비스마다 네임스페이스를 만들고 지우므로 클러스터 범위 관리자 정책을 준다 (해커톤 범위).
# 좁히려면 네임스페이스 생성은 인프라가 미리 하고 AmazonEKSEditPolicy 를 네임스페이스 범위로 바꾼다.
resource "aws_eks_access_entry" "executor" {
  count         = var.executor_google_service_account_id != "" ? 1 : 0
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.executor[0].arn
}

resource "aws_eks_access_policy_association" "executor" {
  count         = var.executor_google_service_account_id != "" ? 1 : 0
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.executor[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.executor]
}
