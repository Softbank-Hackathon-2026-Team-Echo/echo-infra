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
| `ci_build_service_account` | **빌드 실행기**: echo-was 저장소 GitHub Actions(main)가 `google-github-actions/auth` 로 가장해 AR push | `echo-dev-ci-build@…` | 코드 (11/3) |
| `control_plane_service_account_unique_id` | AWS 루트 변수 `executor_google_service_account_id` (배포 실행기의 EKS 접근) | `1003830…` | 코드 (11/3) |

## 고정 진입점 (Envoy VM, `entrypoint.tf`)

| 출력값 | 받는 쪽 | 예 | 상태 |
|---|---|---|---|
| `entrypoint_ip` | **도영(Cloudflare DNS)**: `*.echoport.uk` 고객 앱 주소를 이 IP 로 | `34.x.x.x` | 코드 (11/2) |
| `entrypoint_weights_internal_url` | **echo-was 실행기**(GKE 안, 같은 VPC): `PUT /weights`·`GET /counters`·`GET /summary`, Bearer 토큰. 토큰이 인터넷을 안 탄다 | `http://10.60.0.6:8080` | 코드 (11/3) |
| `entrypoint_weights_url` | 운영자 점검용 공인 주소(`entrypoint_admin_cidrs` 에서만) | `http://<ip>:8080` | 코드 (11/2) |
| `entrypoint_token_secret` | 운영자: `gcloud secrets versions access latest --secret=<값>` | `echo-dev-entry-weights-token` | 코드 (11/2) |
| `entrypoint_grafana_url` | 데모 근거 화면(환경별 요청 수·5xx·p95·가중치·healthy 수) | `http://<ip>:3000` | 코드 (11/2) |

업스트림(`entrypoint_upstreams`)은 환경별 인그레스 `host:port` 다(AWS ALB, GKE 인그레스). 각 환경 인그레스는 환경별 주소뿐 아니라 고정 호스트 `{서비스}.echoport.uk` 도 받아야 한다(Host 헤더를 그대로 넘긴다). 동작 원리와 로컬 실행은 [entrypoint/README.md](../entrypoint/README.md).

## 관제탑 (echo-was, `control-plane.tf`)

AWS 도쿄 장애 중에도 이전을 지시하고 상태를 보여야 하므로 echo-was API·Worker·관리용 DB는 GCP 서울 GKE에 둔다. 프론트는 Cloudflare Pages를 그대로 쓴다.

| 출력값 | 받는 쪽 | 사용법 | 상태 |
|---|---|---|---|
| `control_plane_ip` | 지민·DNS 담당 | Cloudflare `api.echoport.uk` A 레코드. 인증서가 ACTIVE가 될 때까지 DNS only | 코드 (11/2) |
| `control_plane_certificate_name` | echo-was GKE Ingress | `ingress.gcp.kubernetes.io/pre-shared-cert` annotation | 코드 (11/2) |
| `control_plane_service_account` | echo-was KSA | `iam.gke.io/gcp-service-account` annotation | 코드 (11/2) |
| `control_plane_kubernetes_identity` | API 배포 | namespace `echo-was`, KSA `echo-was` | 코드 (11/2) |
| `control_plane_secret_ids` | API 배포 | SecretSync로 DB URL·GitHub App 비밀값 전달 | 코드 (11/2) |

Terraform은 비밀값의 **껍데기만** 만들며 version은 만들지 않는다. 값 입력과 Kubernetes 객체는 API 담당 범위다. GSA는 위 세 secret만 읽고 프로젝트의 다른 secret은 읽지 못한다.

GKE Ingress에는 다음 출력값을 연결한다.

```yaml
metadata:
  annotations:
    kubernetes.io/ingress.global-static-ip-name: echo-dev-echo-was
    ingress.gcp.kubernetes.io/pre-shared-cert: echo-dev-echo-was
```

KSA에는 `control_plane_service_account` 출력값을 연결한다.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: echo-was
  namespace: echo-was
  annotations:
    iam.gke.io/gcp-service-account: <control_plane_service_account>
```

Google 관리형 인증서가 발급되려면 `api.echoport.uk`가 위 고정 IP를 직접 가리켜야 한다. Cloudflare 프록시를 먼저 켜면 검증이 지연될 수 있으므로, 인증서 상태가 `ACTIVE`가 될 때까지 레코드는 **DNS only**로 둔다.

bootstrap 출력값: `state_bucket`(GCP 루트의 `backend.hcl`), `region`.

## echo-was 환경 등록

| 환경 이름 | kind | config |
|---|---|---|
| `aws-tokyo` | `aws` | `region=ap-northeast-1`, `cluster_name=echo-dev-eks` |
| `gcp-seoul` | `gcp` | `project_id`, `region=asia-northeast3`, `cluster_name=echo-dev-gke` |
