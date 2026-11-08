# EKS 클러스터 하나 (관리용·앱용을 나누지 않는다, SPEC infra-1 결정 2).
# 인증은 Access Entry(API 모드)만 쓰고, 만든 사람에게 자동 관리자 권한을 주지 않는다.

resource "aws_iam_role" "cluster" {
  name = "${local.cluster_name}-cluster"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# 컨트롤 플레인 로그(누가 무엇을 했는지). 그룹을 먼저 만들어 보존 기간을 정한다.
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 14
}

resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  version  = var.eks_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  vpc_config {
    subnet_ids              = [for s in aws_subnet.private : s.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.eks_public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  # 표준 지원이 끝나도 유료 연장 지원으로 넘어가지 않게 한다.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.eks,
  ]
}

resource "aws_eks_access_entry" "admin" {
  for_each      = toset(var.eks_admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = toset(var.eks_admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# 노드

resource "aws_iam_role" "node" {
  name = "${local.cluster_name}-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# IMDSv2 만 허용하고 hop limit 1 로 파드가 노드 역할 자격 증명을 빌리지 못하게 한다.
# 파드에 AWS 권한이 필요하면 Pod Identity 로 준다.
resource "aws_launch_template" "node" {
  name_prefix = "${local.cluster_name}-node-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.cluster_name}-node" }
  }
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [for s in aws_subnet.private : s.id]
  instance_types  = var.node_instance_types
  capacity_type   = "ON_DEMAND"

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_route_table_association.private,
  ]
}

# 애드온. 버전은 EKS 가 이 쿠버네티스 버전의 기본값을 고른다.
resource "aws_eks_addon" "this" {
  for_each     = toset(["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent"])
  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.value

  # #140: 노드는 사설 서브넷 + NAT 1개라 노드 SNAT 이 필요 없다. 노드 SNAT(기본)을 켜 두면
  # 보조 ENI 에 붙은 파드가 "ClusterIP → VPC 밖 IP 끝점"(db-writer-manual = 서울 B LB)으로 보낼 때
  # kube-proxy DNAT 가 nat PREROUTING 에서 먼저 끝나 CNI connmark(0x80)가 안 붙고, 보조 ENI 로
  # 주 ENI 주소(SNAT)를 달고 나가 VPC 가 버린다(SYN 응답 없음 → PgBouncer connect timeout 15s).
  # 외부 SNAT 으로 두면 파드 IP 그대로 자기 ENI → NAT(공인 IP 18.180.171.76 그대로)로 나간다.
  # 운영에는 11/8 04:17 KST 에 aws eks update-addon 으로 같은 값을 먼저 넣었다(plan 미실행).
  configuration_values = each.value == "vpc-cni" ? jsonencode({
    env = { AWS_VPC_K8S_CNI_EXTERNALSNAT = "true" }
  }) : null

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # coredns 는 노드가 있어야 Active 가 된다.
  depends_on = [aws_eks_node_group.default]
}

# EBS CSI 드라이버. 이게 없으면 PVC(예: 클러스터 안 PostgreSQL)가 디스크를 못 받아 Pending 에 머문다.
# 권한은 Pod Identity 로 컨트롤러 서비스 계정에만 준다. gp3 기본 StorageClass 는 애드온이 만든다.
resource "aws_iam_role" "ebs_csi" {
  name = "${local.cluster_name}-ebs-csi"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "aws-ebs-csi-driver"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    defaultStorageClass = { enabled = true }
  })

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi,
    aws_eks_addon.this,
  ]
}
