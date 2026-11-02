# 참고·가져온 코드 기록

다른 저장소에서 가져온 코드와 참고한 자료를 남긴다. 규칙은 [terraform-conventions §6](../.claude/rules/terraform-conventions.md).

## 가져온 코드

| 이 저장소 경로 | 원본 저장소@커밋 | 원본 경로 | 바꾼 점 | 허락 |
|---|---|---|---|---|
| (아직 없음) | | | | |

## 참고 저장소

| 저장소 | 성격 | 기준 커밋 | 메모 |
|---|---|---|---|
| `2026-softbank-1/iris-infra` | 예선 Team Iris 인프라. LICENSE 없음 | `8b4e2a8` (2026-10-04) | 가져오기 전에 원작자 허락. bootstrap(state)·OIDC·VPC·EKS 모듈이 후보 |

## 공식 문서

| 주제 | 출처 |
|---|---|
| S3 backend `use_lockfile` | Terraform 공식 문서, S3 backend |
| EKS 엔드포인트 접근 제어 | AWS EKS 사용자 가이드 |
| AWS Budgets | AWS Cost Management 사용자 가이드 |
| GitHub OIDC 로 AWS 역할 받기 | GitHub Docs, Configuring OpenID Connect in AWS |
