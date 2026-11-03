# GitHub WIF 빌드 신원 main 전용 제한 SPEC

- 상태: 구현 완료, 적용 전
- 확인일: 2026-11-03
- 저장소: `echo-infra` · 브랜치 `fix/wif-build-main-only`
- 작성: 서동옥

## 1. 문제

GCP Workload Identity Pool provider가 `echo-infra`와 `echo-was` 모두에 `refs/pull/*`를 허용한다. `echo-was`의 `echo-dev-ci-build` 서비스 계정은 Artifact Registry 쓰기와 GKE 배포 권한을 가지므로 PR 신원이 provider를 통과할 필요가 없다.

## 2. 변경

- `echo-infra`: Terraform plan을 위해 `main`과 `refs/pull/*`를 유지한다.
- `echo-was`: 실제 배포가 실행되는 `refs/heads/main`만 허용한다.
- 서비스 계정의 저장소별 `workloadIdentityUser` 바인딩은 그대로 유지해 provider 조건과 SA 바인딩을 모두 통과해야 가장할 수 있게 한다.

## 3. 완료 조건

- `echo-was` main OIDC 토큰은 provider 조건을 통과한다.
- `echo-was` PR OIDC 토큰은 provider 조건에서 거부된다.
- `echo-infra` PR Terraform plan은 기존대로 동작한다.
- Terraform plan에서 Workload Identity provider 조건 한 건만 in-place 변경되고 리소스 생성·삭제는 없다.
