# 이미지는 digest 로만 배포한다(echo-was 계약). 태그는 덮어쓰지 못하게 한다.
resource "aws_ecr_repository" "this" {
  for_each             = toset(var.ecr_repositories)
  name                 = "${var.project}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # make down 으로 이미지째 지운다 (해커톤 dev)

  image_scanning_configuration {
    scan_on_push = true
  }
}
