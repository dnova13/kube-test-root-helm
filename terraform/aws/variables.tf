variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "name" {
  description = "리소스 이름 접두사. 클러스터는 <name>-cluster, DB는 <name>-db가 된다. 이미 같은 이름의 리소스가 있으면 충돌하므로, 기존 스택과 나란히 시험할 때는 다른 값(예: sns-tf)을 쓴다"
  type        = string
  default     = "sns"
}

# ---------- EKS ----------
variable "kubernetes_version" {
  description = "EKS Kubernetes 버전. 현재 클러스터는 1.36. 지원 버전은 시점에 따라 달라 plan/apply로 확인한다"
  type        = string
  default     = "1.36"
}

variable "node_instance_type" {
  description = "관리형 노드 그룹 인스턴스 유형. Free Tier 계정은 t3.medium이 막혀 c7i-flex.large를 쓴다"
  type        = string
  default     = "c7i-flex.large"
}

variable "node_desired_size" {
  description = "노드 수. CPU 예약이 빠듯해 3대가 기본이다 (현재 클러스터는 실험으로 6대)"
  type        = number
  default     = 3
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 6
}

# ---------- RDS ----------
variable "db_password" {
  description = "RDS 마스터 비밀번호. 제한: 8~41자, 공백과 / ' \" @ 문자는 쓸 수 없다(그 외 출력 가능한 ASCII만, 한글 불가). 이것은 마스터 계정(admin)의 비밀번호이고, 서비스가 쓰는 애플리케이션 계정(sns-server, mysql-secret)과는 별개다. 마스터 비밀번호는 복원·계정 생성 때 쓰므로 잊지 않게 따로 보관한다. 파일에 쓰지 말고 환경변수로 넘긴다: export TF_VAR_db_password='...' (terraform.tfstate에도 기록되므로 state를 git에 올리지 않는다)"
  type        = string
  sensitive   = true
}

variable "db_username" {
  description = "RDS 마스터 사용자. 스냅샷에서 복원할 때는 무시된다"
  type        = string
  default     = "admin"
}

variable "db_engine_version" {
  description = "MariaDB 버전. 현재 11.8.8"
  type        = string
  default     = "11.8.8"
}

variable "db_instance_class" {
  description = "db.t4g.micro는 max_connections가 약 28~30이라 서비스의 DB 연결 풀을 3으로 제한해야 한다"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_snapshot_identifier" {
  description = "이 값을 주면 해당 스냅샷에서 RDS를 복원해 데이터를 살린다. 비우면 빈 DB(이후 ddl.sql 적용)"
  type        = string
  default     = null
}

variable "db_skip_final_snapshot" {
  description = "destroy 때 마지막 스냅샷을 만들지 않는다. 학습용이라 true. 데이터를 남기려면 false로 두고 final snapshot을 만든다"
  type        = bool
  default     = true
}

# ---------- 접근 ----------
variable "admin_cidr" {
  description = "내 PC에서 RDS(3306)에 직접 접속하려고 허용할 공인 IP (예: 1.2.3.4/32). 비우면 열지 않는다. 코드에 IP를 적지 말고 terraform.tfvars(git 제외)에 둔다. RDS는 비공개라 열어도 접속되지 않을 수 있다"
  type        = string
  default     = null
}

variable "ecr_repositories" {
  description = "만들 ECR 저장소 목록"
  type        = list(string)
  default = [
    "feed-server",
    "user-server",
    "image-server",
    "timeline-server",
    "notification-batch",
    "sns-frontend",
  ]
}

variable "ecr_force_delete" {
  description = "true면 이미지가 들어 있어도 destroy로 저장소를 지운다. 이미지는 jib로 다시 만들 수 있어 기본 true"
  type        = bool
  default     = true
}
