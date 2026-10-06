# ============================================================
# IAM: 클러스터 Role, 노드 Role 2개, EFS CSI Role, OIDC 공급자
# 값은 현재 클러스터에서 조회한 구성(docs/현재_AWS_구성_요약.md)을 따른다.
# 이름은 수작업 때의 철자 오류(rule, Amazone)를 버리고 <name>-* 로 새로 짓는다.
# ============================================================

locals {
  # EC2가 맡는 노드 Role의 공통 신뢰 정책
  ec2_assume_role = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  node_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]

  cluster_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
  ]
}

# ---------- 클러스터 Role ----------
# sts:TagSession이 없으면 Auto Mode에서 ALB(Ingress)를 만들 때 실패한다
resource "aws_iam_role" "cluster" {
  name = "${var.name}-eks-cluster-role"
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
  for_each   = toset(local.cluster_policies)
  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# ---------- Auto Mode 노드 Role ----------
resource "aws_iam_role" "auto_node" {
  name               = "${var.name}-eks-auto-node-role"
  assume_role_policy = local.ec2_assume_role
}

resource "aws_iam_role_policy_attachment" "auto_node" {
  for_each   = toset(local.node_policies)
  role       = aws_iam_role.auto_node.name
  policy_arn = each.value
}

# ---------- 관리형 노드 그룹 Role ----------
# Auto Mode 노드 Role과 반드시 달라야 한다 (같이 쓰면 Access Entry 타입이 충돌해
# NodeCreationFailure: Instances failed to join 이 난다)
resource "aws_iam_role" "node_group" {
  name               = "${var.name}-eks-node-role"
  assume_role_policy = local.ec2_assume_role
}

resource "aws_iam_role_policy_attachment" "node_group" {
  for_each   = toset(local.node_policies)
  role       = aws_iam_role.node_group.name
  policy_arn = each.value
}

# ---------- OIDC 공급자 ----------
# 새 클러스터는 OIDC 발급자 주소가 새로 생긴다. 수작업에서는 이것을 놓치기 쉽지만
# 여기서는 클러스터 값을 그대로 참조하므로 자동으로 맞는다
resource "aws_iam_openid_connect_provider" "eks" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  oidc_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# ---------- EFS CSI 드라이버 Role (IRSA) ----------
resource "aws_iam_role" "efs_csi" {
  name = "${var.name}-efs-csi-driver-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "${local.oidc_host}:sub" = "system:serviceaccount:kube-system:efs-csi-*"
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}
