# ============================================================
# EKS 클러스터 (Auto Mode) + 관리형 노드 그룹 + 애드온
# ============================================================

resource "aws_eks_cluster" "this" {
  name     = "${var.name}-cluster"
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # Auto Mode는 기본 애드온(coredns, kube-proxy, vpc-cni)을 직접 깔지 않으므로 false가 필요하다.
  # 아래 aws_eks_addon으로 현재 클러스터와 같게 따로 설치한다
  bootstrap_self_managed_addons = false

  # API 인증(Access Entry). 클러스터를 만든 사용자(terraform을 실행한 IAM 사용자)에게
  # 관리자 권한이 자동으로 붙어서 수작업 때의 create-access-entry가 필요 없다
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = data.aws_subnets.default.ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # Auto Mode: 노드 풀 general-purpose, system
  compute_config {
    enabled       = true
    node_pools    = ["general-purpose", "system"]
    node_role_arn = aws_iam_role.auto_node.arn
  }

  # Auto Mode의 블록 스토리지와 로드밸런서(ALB 자동 구성)
  storage_config {
    block_storage {
      enabled = true
    }
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# ---------- 관리형 노드 그룹 (Auto Mode와 별개로 서비스가 올라가는 노드) ----------
resource "aws_eks_node_group" "sns" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-node"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = data.aws_subnets.default.ids

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = [var.node_instance_type]
  disk_size      = 20

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  # 노드 수를 kubectl/콘솔로 조정해도 다음 apply가 되돌리지 않게 한다
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  # 네트워크 애드온(vpc-cni, kube-proxy)이 먼저 있어야 노드가 Ready가 된다.
  # 이 순서가 없으면 노드가 합류하지 못해 NodeCreationFailure가 난다
  depends_on = [
    aws_iam_role_policy_attachment.node_group,
    aws_eks_addon.early,
  ]
}

# ---------- 애드온 ----------
# kubecost 애드온은 Marketplace 구독이 필요해 CREATE_FAILED였으므로 코드화하지 않는다.
# 버전은 고정하지 않는다(현재 클러스터도 기본값). 고정하려면 addon_version을 추가한다
locals {
  # 노드가 뜨기 전에 있어야 하는 애드온(DaemonSet이라 노드 없이도 만들어진다)
  early_addons = ["vpc-cni", "kube-proxy", "eks-pod-identity-agent"]

  # Pod를 실행할 노드가 있어야 Ready가 되는 애드온(Deployment). 노드 그룹 뒤에 만든다
  late_addons = {
    "coredns"            = null
    "metrics-server"     = null
    "aws-efs-csi-driver" = aws_iam_role.efs_csi.arn # IRSA Role 연결
  }
}

resource "aws_eks_addon" "early" {
  for_each = toset(local.early_addons)

  cluster_name = aws_eks_cluster.this.name
  addon_name   = each.key

  # 이미 있는 설정과 충돌하면 애드온 쪽 값으로 덮어쓴다
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "late" {
  for_each = local.late_addons

  cluster_name             = aws_eks_cluster.this.name
  addon_name               = each.key
  service_account_role_arn = each.value

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.sns,
    aws_iam_role_policy_attachment.efs_csi,
  ]
}
