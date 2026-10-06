# 서비스 이미지 저장소. 저장소를 만들어도 이미지는 비어 있으므로 각 서비스에서 ./gradlew jib 로 push한다
resource "aws_ecr_repository" "this" {
  for_each = toset(var.ecr_repositories)

  name                 = each.value
  image_tag_mutability = "MUTABLE"
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = false
  }
}
