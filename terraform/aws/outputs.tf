output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "kubeconfig_command" {
  description = "apply 후 kubectl이 이 클러스터를 보게 하는 명령"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name}"
}

output "efs_file_system_id" {
  description = "StorageClass efs-sc의 fileSystemId에 넣을 값 (part3-infra/efs-sc.yaml)"
  value       = aws_efs_file_system.this.id
}

output "rds_address" {
  description = "ExternalName Service mariadb(infra 네임스페이스)의 externalName에 넣을 값"
  value       = aws_db_instance.this.address
}

output "ecr_registry" {
  description = "이미지 주소의 앞부분. sns-chart의 global.imageRegistry와 각 서비스 build.gradle의 ECR 주소에 넣을 값"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "oidc_issuer" {
  description = "EFS CSI Role 신뢰 정책에 자동으로 들어간 OIDC 발급자 (수작업 4단계 함정을 코드가 대신 처리)"
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}
