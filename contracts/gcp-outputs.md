# GCP 출력값 계약

`terraform/environments/gcp/dev` 의 출력값 이름이다. 다른 파트는 이 이름으로 값을 받는다. 이름을 바꾸면 PR 체크리스트에 적고 받는 쪽에 알린다. 대역 표는 [aws-outputs.md](aws-outputs.md) 의 「환경별 주소 대역」이 단일 출처다.

| 출력값 | 받는 쪽 | 예 | 상태 |
|---|---|---|---|
| `project_id` | 빌드·배포, Argo CD | `echo-final-…` | 코드 (11/2) |
| `region` | echo-was `gcp` 환경 config | `asia-northeast3` | 코드 (11/2) |
| `zone` | 운영자 | `asia-northeast3-a` | 코드 (11/2) |
| `gke_cluster_name` | echo-was `gcp` 환경 config, Argo CD | `echo-dev-gke` | 코드 (11/2) |
| `gke_cluster_endpoint` | Argo CD, AI 에이전트(읽기) | `https://…` | 코드 (11/2) |
| `network_name` | 복제·VPN | `echo-dev` | 코드 (11/2) |
| `subnet_cidr` / `pods_cidr` / `services_cidr` | 복제·VPN (겹침 확인) | `10.60.0.0/20` / `10.61.0.0/16` / `10.62.0.0/20` | 코드 (11/2) |
| `nat_ip` | **AWS 쪽 PostgreSQL 복제 허용 목록(보안 그룹)** | `34.x.x.x` | 코드 (11/2) |
| `artifact_registry_urls` | 빌드·배포(ECR 사본), 앱 | `{ app = "asia-northeast3-docker.pkg.dev/<project>/echo/app" }` | 코드 (11/2) |
| `ci_plan_service_account` | GitHub Actions `google-github-actions/auth` | `echo-dev-ci-plan@…` | 코드 (11/2) |
| `ci_workload_identity_provider` | GitHub Actions `google-github-actions/auth` | `projects/…/providers/github` | 코드 (11/2) |

고정 진입점(Envoy)·관측 출력값은 `entrypoint.tf` 가 들어오면 여기에 더한다.

bootstrap 출력값: `state_bucket`(GCP 루트의 `backend.hcl`), `region`.

## echo-was 환경 등록

| 환경 이름 | kind | config |
|---|---|---|
| `aws-tokyo` | `aws` | `region=ap-northeast-1`, `cluster_name=echo-dev-eks` |
| `gcp-seoul` | `gcp` | `project_id`, `region=asia-northeast3`, `cluster_name=echo-dev-gke` |
