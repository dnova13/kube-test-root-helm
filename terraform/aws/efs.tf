# Image Server의 업로드 파일을 저장하는 EFS (StorageClass efs-sc가 이 파일 시스템을 쓴다)
resource "aws_efs_file_system" "this" {
  creation_token   = "${var.name}-efs"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"

  tags = {
    Name = "${var.name}-efs-volume"
  }
}

# 서브넷(AZ)마다 마운트 대상이 있어야 그 AZ의 노드가 마운트한다
resource "aws_efs_mount_target" "this" {
  for_each = toset(data.aws_subnets.default.ids)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [aws_security_group.data.id]
}
