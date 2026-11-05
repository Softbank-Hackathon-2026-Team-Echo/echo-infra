# GitHub Actions 와 실행기가 장기 키 없이 쓰는 자격 증명. 절차와 받는 쪽은 contracts/executor-credentials.md.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# 어떤 GitHub 저장소가 어떤 역할을 받는지는 두 클라우드가 같은 목록을 본다.
module "github" {
  source = "../../../modules/github-repos"
}

# state 버킷 이름은 terraform/bootstrap/aws 와 같은 규칙으로 계산한다 (tfvars 에 다시 적지 않는다).
data "aws_caller_identity" "current" {}

locals {
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  # GitHub OIDC sub 는 두 형식이 온다: 이름 형식 repo:ORG/NAME:… 과 불변 ID 형식 repo:ORG@<id>/NAME@<id>:… (2026-11 조직 저장소에서 확인).
  # 둘 다 허용한다. ID 는 와일드카드로 두되 조직·저장소 이름은 고정한다.
  github_sub_prefix = { for r in distinct(concat([module.github.plan_repository], module.github.build_repositories)) :
    r => ["repo:${r}", "repo:${replace(r, "/", "@*/")}@*"]
  }

  # 신뢰 정책은 sub 목록만 다르다.
  github_trust = { for k, subs in {
    plan  = flatten([for p in local.github_sub_prefix[module.github.plan_repository] : ["${p}:ref:refs/heads/main", "${p}:pull_request"]])
    build = flatten([for r in module.github.build_repositories : [for p in local.github_sub_prefix[r] : "${p}:ref:refs/heads/main"]])
    } : k => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
          StringLike   = { "token.actions.githubusercontent.com:sub" = subs }
        }
      }]
  }) }
}

# ---------- plan: echo-infra 저장소 main·PR, 읽기 전용 ----------
resource "aws_iam_role" "ci_plan" {
  name               = "${local.name}-ci-plan"
  assume_role_policy = local.github_trust.plan
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

# ---------- 빌드 실행기: 빌드 저장소 main 의 GitHub Actions → ECR push ----------
resource "aws_iam_role" "ci_build" {
  name               = "${local.name}-ci-build"
  assume_role_policy = local.github_trust.build
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

# ---------- 배포 실행기: 관제탑 GSA 의 Google ID 토큰으로 받는 역할 (contracts/executor-credentials.md §2) ----------
# Google 공급자는 계정에 하나다. 역할이 늘어도 이 리소스는 그대로 쓴다.
#
# Google ID 토큰은 azp(= 서비스 계정 고유 ID)가 있어서, AWS STS 는 키 accounts.google.com:aud 를
# 토큰의 azp 로 채우고 토큰의 진짜 aud 는 accounts.google.com:oaud 로 넘긴다(IAM 조건 키 문서
# "accounts.google.com:aud"). 공급자 client_id_list 도 azp 와 맞아야 한다. 맞지 않으면 STS 는
# 400 InvalidIdentityToken("could not be validated")을 낸다(11/4 운영 실제 실행기 첫 배포에서 확인).
resource "aws_iam_openid_connect_provider" "google" {
  url = "https://accounts.google.com"
  # 컷오버 GSA(cutover.tf)도 같은 공급자를 쓴다. 비어 있으면 넣지 않는다.
  client_id_list = compact(["sts.amazonaws.com", var.executor_google_service_account_id, var.cutover_google_service_account_id])
}

resource "aws_iam_role" "executor" {
  name = "${local.name}-executor"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.google.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # aud = 토큰 azp(서비스 계정 고유 ID), oaud = 토큰 aud(메타데이터 서버에 준 audience).
          "accounts.google.com:aud"  = var.executor_google_service_account_id
          "accounts.google.com:oaud" = "sts.amazonaws.com"
          "accounts.google.com:sub"  = var.executor_google_service_account_id
        }
      }
    }]
  })
}

# kubeconfig 를 만들 때 클러스터 정보만 읽는다. 쿠버네티스 안 권한은 Access Entry 가 준다.
resource "aws_iam_role_policy" "executor_eks" {
  name = "eks-describe"
  role = aws_iam_role.executor.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = aws_eks_cluster.this.arn
    }]
  })
}

# 실행기는 서비스마다 네임스페이스를 만들고 지우므로 클러스터 범위 관리자 정책을 준다 (해커톤 범위).
# GKE 쪽(container.developer)과 비대칭이다. 맞추려면 두 클러스터에 같은 ClusterRole 매니페스트를 적용하고 여기는 kubernetes_groups 만 준다.
resource "aws_eks_access_entry" "executor" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.executor.arn
}

resource "aws_eks_access_policy_association" "executor" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.executor.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# 11/3 처음엔 변수가 비면 안 만드는 count 였다. GCP 출력값이 단일 출처라 분기를 없앴다.
moved {
  from = aws_iam_openid_connect_provider.google[0]
  to   = aws_iam_openid_connect_provider.google
}

moved {
  from = aws_iam_role.executor[0]
  to   = aws_iam_role.executor
}

moved {
  from = aws_iam_role_policy.executor_eks[0]
  to   = aws_iam_role_policy.executor_eks
}

moved {
  from = aws_eks_access_entry.executor[0]
  to   = aws_eks_access_entry.executor
}

moved {
  from = aws_eks_access_policy_association.executor[0]
  to   = aws_eks_access_policy_association.executor
}
