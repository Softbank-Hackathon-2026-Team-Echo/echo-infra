# 진입점 c (인프라 17, specs/infra-17-second-provider-entrypoint.md). AWS 서울에 GCP 진입점 a·b 와 **같은** Envoy 한 벌
# (Envoy · weights-api · journal · Prometheus · Grafana, entrypoint/ 디렉터리가 단일 출처)을 하나 더 둔다.
# 입구가 GCP 한 회사·한 리전이면 그것 자체가 락인이자 단일 장애점이라, 서울 안에서 회사를 하나 더 둔다.
#
#   Cloudflare Load Balancer (*.echoport.uk, 끄면 기존 A 레코드로 돌아감)
#     ├─ 풀 1 (우선): GCP NLB entry_lb → 진입점 a (b 는 NLB 의 장애 조치 백엔드)
#     └─ 풀 2 (페일오버): 이 파일의 EC2 c (EIP)
#
# 가중치는 c 가 a 의 /weights 를 2초마다 당겨 맞춘다(b 와 같은 SYNC_FROM). echo-was 는 지금처럼 a 만 PUT 한다.
# 요청 기록(journal)은 c 에서 늘 꺼 둔다(b 와 같음, SPEC infra-12.4 D-11). remote write 수신도 끈다(a 만 받는다).
#
# 설정 파일은 user_data 16KB 한도를 넘어(entrypoint/ 약 61KB) S3 버킷에 올리고, VM 이 부팅마다 받아 compose up 한다.
# 비밀값은 Terraform 이 만들지 않는다: 가중치 토큰은 적용 절차가 GCP Secret Manager 값을 SSM SecureString 에 파이프로 넣고,
# Grafana 비밀번호는 VM 이 처음 켤 때 만들어 VM 안(0600)에만 둔다. state·저장소에 비밀값 0.
# var.entrypoint_c_enabled = false(기본)면 아무것도 만들지 않는다.

locals {
  entry_c_enabled = var.entrypoint_c_enabled
  entry_c_name    = "${local.name}-entry-c"

  # GCP gcp/dev/entrypoint.tf 의 entry_files 와 같은 허용 목록이다(바꾸면 두 곳을 같이 바꾼다). .env·README·시험은 싣지 않는다.
  entry_c_src = "${path.module}/../../../../entrypoint"
  entry_c_files = local.entry_c_enabled ? {
    for p in setunion(
      fileset(local.entry_c_src, "docker-compose.yml"),
      fileset(local.entry_c_src, "weights-api/*"),
      fileset(local.entry_c_src, "journal/Dockerfile"),
      fileset(local.entry_c_src, "journal/app.py"),
      fileset(local.entry_c_src, "config/**"),
      fileset(local.entry_c_src, "scripts/render-prometheus-web.sh"),
    ) : p => file("${local.entry_c_src}/${p}")
  } : {}

  # VM 의 .env 중 비밀이 아닌 값. 바꾸면 apply 뒤 VM 에서 sudo systemctl start echo-entry-c-sync (SSM) 로 다시 맞춘다.
  entry_c_settings = join("\n", [
    "UPSTREAMS=${join(",", [for env, hp in var.entrypoint_c_upstreams : "${env}=${hp}"])}",
    "DEFAULT_WEIGHTS=${join(",", [for env, w in var.entrypoint_c_default_weights : "${env}=${w}"])}",
    "SYNC_FROM=${var.entrypoint_c_sync_from}",
    "JOURNAL_ENABLED=false",
    "PROMETHEUS_REMOTE_WRITE_FLAG=no-web.enable-remote-write-receiver",
    "",
  ])
}

# ---------- 자리: 서울 기본 VPC (온프레 시연 기기 onprem-demo 와 같은 VPC, 새 VPC·NAT 비용 없음) ----------
data "aws_vpc" "entry_c" {
  count    = local.entry_c_enabled ? 1 : 0
  provider = aws.seoul
  default  = true
}

data "aws_subnet" "entry_c" {
  count             = local.entry_c_enabled ? 1 : 0
  provider          = aws.seoul
  vpc_id            = data.aws_vpc.entry_c[0].id
  availability_zone = "${var.entrypoint_c_region}${var.entrypoint_c_az_suffix}"
  default_for_az    = true
}

# Canonical Ubuntu 24.04 LTS(amd64) 최신 AMI. SSM 에이전트가 들어 있어 22 를 열지 않고 Session Manager 로 들어간다.
data "aws_ssm_parameter" "entry_c_ubuntu" {
  count    = local.entry_c_enabled ? 1 : 0
  provider = aws.seoul
  name     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ---------- 설정 버킷 (entrypoint/ 파일 + 비밀 아닌 .env 값) ----------
resource "aws_s3_bucket" "entry_c" {
  count    = local.entry_c_enabled ? 1 : 0
  provider = aws.seoul
  bucket   = "${local.entry_c_name}-${data.aws_caller_identity.current.account_id}"

  # 설정 파일만 있다(데이터 없음). 되돌리기(enabled=false) 때 비우고 지울 수 있게 한다.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "entry_c" {
  count    = local.entry_c_enabled ? 1 : 0
  provider = aws.seoul
  bucket   = aws_s3_bucket.entry_c[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "entry_c_files" {
  for_each = local.entry_c_files
  provider = aws.seoul
  bucket   = aws_s3_bucket.entry_c[0].id
  key      = "entrypoint/${each.key}"
  content  = each.value
}

resource "aws_s3_object" "entry_c_settings" {
  count    = local.entry_c_enabled ? 1 : 0
  provider = aws.seoul
  bucket   = aws_s3_bucket.entry_c[0].id
  key      = "settings.env"
  content  = local.entry_c_settings
}

# ---------- 네트워크: 80·443 은 Cloudflare 대역에서만, 그 밖 들어오는 규칙 없음 ----------
# Cloudflare 대역 15개를 관리형 접두사 목록 하나로 묶어 규칙 2개로 건다(대역이 바뀌면 변수만 고친다).
resource "aws_ec2_managed_prefix_list" "entry_c_cloudflare" {
  count          = local.entry_c_enabled ? 1 : 0
  provider       = aws.seoul
  name           = "${local.entry_c_name}-cloudflare"
  address_family = "IPv4"
  max_entries    = length(var.entrypoint_c_ingress_cidrs)

  dynamic "entry" {
    for_each = var.entrypoint_c_ingress_cidrs
    content {
      cidr        = entry.value
      description = "cloudflare"
    }
  }

  tags = { Name = "${local.entry_c_name}-cloudflare" }
}

resource "aws_security_group" "entry_c" {
  count       = local.entry_c_enabled ? 1 : 0
  provider    = aws.seoul
  name        = local.entry_c_name
  description = "entrypoint c: 80/443 from Cloudflare only, no SSH (SSM), all outbound"
  vpc_id      = data.aws_vpc.entry_c[0].id

  tags = { Name = local.entry_c_name }
}

resource "aws_vpc_security_group_ingress_rule" "entry_c" {
  for_each          = local.entry_c_enabled ? toset(["80", "443"]) : toset([])
  provider          = aws.seoul
  security_group_id = aws_security_group.entry_c[0].id
  description       = "cloudflare proxy and load balancer health monitor"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  prefix_list_id    = aws_ec2_managed_prefix_list.entry_c_cloudflare[0].id
}

# 나가는 길: 업스트림(닻 ALB·GKE 외부 LB :80), a 의 가중치 API(:8080), 이미지·패키지, SSM·S3.
resource "aws_vpc_security_group_egress_rule" "entry_c" {
  count             = local.entry_c_enabled ? 1 : 0
  provider          = aws.seoul
  security_group_id = aws_security_group.entry_c[0].id
  description       = "all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------- 신원: SSM 접속 + 설정 버킷 읽기 + 토큰 파라미터 읽기 ----------
data "aws_iam_policy_document" "entry_c_assume" {
  count = local.entry_c_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "entry_c" {
  count              = local.entry_c_enabled ? 1 : 0
  provider           = aws.seoul
  name               = local.entry_c_name
  assume_role_policy = data.aws_iam_policy_document.entry_c_assume[0].json
}

# SSM 에이전트 통신(Session Manager·Run Command)에 필요한 동작만 인라인으로 준다.
# 관리형 정책 AmazonSSMManagedInstanceCore 는 ssm:GetParameter(s) 가 Resource "*" 라 다른 파라미터까지 읽을 수 있어 쓰지 않는다(PR #97 검증 지적 1).
# 아래 동작들은 리소스 단위 제한을 지원하지 않거나(ssmmessages·ec2messages) 파라미터 값을 읽지 않는다(UpdateInstanceInformation).
data "aws_iam_policy_document" "entry_c_ssm_agent" {
  count = local.entry_c_enabled ? 1 : 0

  statement {
    sid       = "SsmAgentRegister"
    actions   = ["ssm:UpdateInstanceInformation"]
    resources = ["*"]
  }

  statement {
    sid = "SsmSessionChannels"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  statement {
    sid = "SsmAgentMessages"
    actions = [
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "entry_c_ssm_agent" {
  count    = local.entry_c_enabled ? 1 : 0
  provider = aws.seoul
  name     = "entry-c-ssm-agent"
  role     = aws_iam_role.entry_c[0].id
  policy   = data.aws_iam_policy_document.entry_c_ssm_agent[0].json
}

data "aws_iam_policy_document" "entry_c" {
  count = local.entry_c_enabled ? 1 : 0

  statement {
    sid       = "ReadConfigBucket"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.entry_c[0].arn}/*"]
  }

  statement {
    sid       = "ListConfigBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.entry_c[0].arn]
  }

  # SecureString 은 AWS 관리형 키(aws/ssm)로 암호화한다 — 키 정책이 계정 안 SSM 경유 복호화를 허용하므로 kms 권한을 따로 주지 않는다.
  statement {
    sid       = "ReadWeightsToken"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.entrypoint_c_region}:${data.aws_caller_identity.current.account_id}:parameter${var.entrypoint_c_token_parameter}"]
  }
}

resource "aws_iam_role_policy" "entry_c" {
  count    = local.entry_c_enabled ? 1 : 0
  provider = aws.seoul
  name     = "entry-c-config"
  role     = aws_iam_role.entry_c[0].id
  policy   = data.aws_iam_policy_document.entry_c[0].json
}

resource "aws_iam_instance_profile" "entry_c" {
  count    = local.entry_c_enabled ? 1 : 0
  provider = aws.seoul
  name     = local.entry_c_name
  role     = aws_iam_role.entry_c[0].name
}

# ---------- VM ----------
resource "aws_instance" "entry_c" {
  count                       = local.entry_c_enabled ? 1 : 0
  provider                    = aws.seoul
  ami                         = data.aws_ssm_parameter.entry_c_ubuntu[0].insecure_value
  instance_type               = var.entrypoint_c_instance_type
  subnet_id                   = data.aws_subnet.entry_c[0].id
  vpc_security_group_ids      = [aws_security_group.entry_c[0].id]
  iam_instance_profile        = aws_iam_instance_profile.entry_c[0].name
  associate_public_ip_address = true

  # 부트스트랩은 버킷 이름·리전·파라미터 이름만 담아 거의 바뀌지 않는다. 설정은 S3 에서 부팅마다 받는다.
  user_data = templatefile("${path.module}/entrypoint-c-bootstrap.sh.tftpl", {
    bucket          = aws_s3_bucket.entry_c[0].id
    region          = var.entrypoint_c_region
    token_parameter = var.entrypoint_c_token_parameter
  })

  # t3 기본값(unlimited)은 CPU 크레딧을 넘으면 추가 요금이 붙는다 (onprem-demo 와 같음).
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = { Name = local.entry_c_name }

  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [
    aws_s3_object.entry_c_files,
    aws_s3_object.entry_c_settings,
    aws_iam_role_policy.entry_c,
    aws_iam_role_policy.entry_c_ssm_agent,
  ]
}

# ---------- 고정 공인 IP ----------
# Cloudflare LB 풀 2 의 엔드포인트, 닻 ALB inbound-cidrs, GKE 외부 LB loadBalancerSourceRanges,
# GCP 진입점 a 방화벽(entrypoint_weights_sync_cidrs, 8080)이 모두 이 IP/32 를 쓴다. 기기를 멈췄다 켜도 바뀌지 않게 EIP.
resource "aws_eip" "entry_c" {
  count    = local.entry_c_enabled ? 1 : 0
  provider = aws.seoul
  domain   = "vpc"

  tags = { Name = local.entry_c_name }
}

resource "aws_eip_association" "entry_c" {
  count         = local.entry_c_enabled ? 1 : 0
  provider      = aws.seoul
  instance_id   = aws_instance.entry_c[0].id
  allocation_id = aws_eip.entry_c[0].id
}
