# 시연에서 "온프레"로 간주하는 리눅스 기기 한 대 (이슈 #2).
# 클라우드라서 특별히 하는 일은 없다: 실제 온프레처럼 들어오는 포트가 없고, 설치는 onprem/install.sh 가 한다.
# 접속은 SSM(나가는 연결), 공개 주소는 Cloudflare Tunnel(나가는 연결). 공인 IP 는 나가는 길(NAT 대신)로만 쓴다.

locals {
  name = "${var.project}-${var.environment}"
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "host" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "${var.region}${var.availability_zone_suffix}"
  default_for_az    = true
}

# Canonical 이 공개하는 Ubuntu 24.04 LTS(amd64) 최신 AMI. 한 번 만든 뒤 AMI 가 바뀌어도 기기를 다시 만들지 않는다.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ---------- 네트워크: 들어오는 규칙 없음 ----------
resource "aws_security_group" "host" {
  name        = "${local.name}-host"
  description = "onprem demo host: no inbound, all outbound (SSM, Cloudflare Tunnel, image pulls)"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${local.name}-host"
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.host.id
  description       = "all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------- 신원: SSM 접속 + 터널 자격 증명 읽기 ----------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name               = "${local.name}-host"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "params" {
  statement {
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_parameter_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "params" {
  name   = "read-onprem-params"
  role   = aws_iam_role.host.id
  policy = data.aws_iam_policy_document.params.json
}

resource "aws_iam_instance_profile" "host" {
  name = "${local.name}-host"
  role = aws_iam_role.host.name
}

# ---------- 기기 ----------
resource "aws_instance" "host" {
  ami                         = data.aws_ssm_parameter.ubuntu.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.host.id
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = true

  # t3 기본값(unlimited)은 CPU 크레딧을 넘으면 추가 요금이 붙는다. 시연 기기는 standard 로 묶는다.
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  tags = {
    Name = local.name
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

# ---------- 고정 공인 IP (인프라 9) ----------
# 진입점 Prometheus remote write(9090) 방화벽이 이 IP/32 만 연다(GCP dev 루트 entrypoint_remote_write_cidrs).
# 자동 할당 IP 는 기기를 멈췄다 켜면 바뀌어 9090 이 막히므로 EIP 로 고정한다. 들어오는 규칙은 그대로 0개다.
# associate_public_ip_address 는 바꾸지 않는다(바꾸면 기기를 다시 만든다). 연결하면 자동 IP 는 EIP 로 바뀐다.
resource "aws_eip" "host" {
  domain = "vpc"

  tags = {
    Name = local.name
  }
}

resource "aws_eip_association" "host" {
  instance_id   = aws_instance.host.id
  allocation_id = aws_eip.host.id
}
