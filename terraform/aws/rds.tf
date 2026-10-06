# ============================================================
# RDS (MariaDB). 클러스터 밖의 외부 자원이다.
# 비공개(VPC 안에서만 접속). 초기 DB는 만들지 않고, 테이블은 part3-infra/ddl.sql로 만든다
# ============================================================

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "this" {
  identifier = "${var.name}-db"

  engine         = "mariadb"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp2"
  storage_encrypted = true

  # 스냅샷에서 복원할 때는 사용자 이름을 지정할 수 없다 (스냅샷의 값을 쓴다)
  snapshot_identifier = var.db_snapshot_identifier
  username            = var.db_snapshot_identifier == null ? var.db_username : null
  password            = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.data.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 1
  skip_final_snapshot     = var.db_skip_final_snapshot
  # skip_final_snapshot=false일 때 destroy가 만들 마지막 스냅샷 이름
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${var.name}-db-final"

  apply_immediately = true

  lifecycle {
    # 비밀번호를 콘솔에서 바꿔도 다음 apply가 되돌리지 않게 한다
    ignore_changes = [password]
  }
}
