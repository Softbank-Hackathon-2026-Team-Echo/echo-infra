# AWS 출력값 계약

`terraform/environments/aws/dev` 의 출력값 이름이다. 다른 파트는 이 이름으로 값을 받는다. 이름을 바꾸면 PR 체크리스트에 적고 받는 쪽에 알린다.

| 출력값 | 받는 쪽 | 예 | 상태 |
|---|---|---|---|
| `region` | echo-was `AwsEnvironmentConfig.region` | `ap-northeast-1` | 예정 |
| `eks_cluster_name` | echo-was `AwsEnvironmentConfig.cluster_name`, Argo CD | `echo-dev-eks` | 예정 |
| `eks_cluster_endpoint` | Argo CD, AI 에이전트(읽기) | `https://…eks.amazonaws.com` | 예정 |
| `vpc_id` | 앱·이전 엔진 | `vpc-…` | 예정 |
| `vpc_cidr` | GCP·온프레(VPN), 복제 | `10.50.0.0/16` | 예정 |
| `private_subnet_ids` | 앱(DB 위치 결정 시) | `["subnet-…"]` | 예정 |
| `ecr_repository_urls` | 빌드·배포, 앱 | `{ app = "…/echo/app" }` | 예정 |

## 환경별 주소 대역 (2026-11-02 확정)

사설망(VPN)으로 복제·연결할 때 겹치면 안 된다. AWS 는 아래 대역을 쓰고, GKE·K3s 는 기본값을 쓴다. 바꾸려면 이 표를 먼저 고친다.

| 환경 | 노드·VPC | 파드 | 서비스 |
|---|---|---|---|
| AWS EKS (도쿄) | `10.50.0.0/16` | VPC 대역 안 (VPC CNI) | EKS 기본 (`10.100.0.0/16` 또는 `172.20.0.0/16`) |
| GCP GKE (서울) | GCP 기본 (`10.128.0.0/9` 안의 서울 대역) | GKE 기본 | GKE 기본 |
| 온프레 K3s | 현장 LAN | `10.42.0.0/16` (K3s 기본) | `10.43.0.0/16` (K3s 기본) |

bootstrap 출력값: `state_bucket`(다른 루트의 `backend.hcl`), `region`.
