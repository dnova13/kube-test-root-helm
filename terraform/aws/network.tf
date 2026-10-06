# 기본 VPC와 서브넷을 읽어서 쓴다 (새로 만들지 않는다)
data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# ALB(Ingress)가 올라갈 서브넷을 찾는 데 쓰는 태그. 기본 서브넷에는 이미 있을 수 있다
# (주의: destroy하면 이 태그가 지워진다. 기본 VPC를 다른 용도로 쓴다면 이 블록을 지운다)
resource "aws_ec2_tag" "subnet_elb" {
  for_each    = toset(data.aws_subnets.default.ids)
  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}

# RDS와 EFS가 함께 쓰는 전용 보안 그룹. 기본 보안 그룹은 고치지 않는다
resource "aws_security_group" "data" {
  name        = "${var.name}-data"
  # AWS는 이 필드에 ASCII만 허용한다 (한글을 쓰면 InvalidParameterValue)
  description = "Allow RDS 3306 and EFS 2049 access"
  vpc_id      = data.aws_vpc.default.id
}

# 클러스터(노드, Pod)에서 오는 MySQL 접속
resource "aws_vpc_security_group_ingress_rule" "mysql_from_cluster" {
  security_group_id            = aws_security_group.data.id
  description                  = "MySQL from EKS cluster"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

# 내 PC에서 직접 접속 (admin_cidr을 줬을 때만)
resource "aws_vpc_security_group_ingress_rule" "mysql_from_admin" {
  count             = var.admin_cidr == null ? 0 : 1
  security_group_id = aws_security_group.data.id
  description       = "MySQL from admin PC"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
  cidr_ipv4         = var.admin_cidr
}

# VPC 안에서 오는 NFS(EFS 마운트)
resource "aws_vpc_security_group_ingress_rule" "nfs_from_vpc" {
  security_group_id = aws_security_group.data.id
  description       = "NFS from VPC"
  ip_protocol       = "tcp"
  from_port         = 2049
  to_port           = 2049
  cidr_ipv4         = data.aws_vpc.default.cidr_block
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.data.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
