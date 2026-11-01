# AWS 출력값 계약

`terraform/environments/aws/dev` 의 출력값 이름이다. 다른 파트는 이 이름으로 값을 받는다. 이름을 바꾸면 PR 체크리스트에 적고 받는 쪽에 알린다.

| 출력값 | 받는 쪽 | 예 | 상태 |
|---|---|---|---|
| `region` | echo-was `AwsEnvironmentConfig.region` | `ap-northeast-2` | 예정 |
| `eks_cluster_name` | echo-was `AwsEnvironmentConfig.cluster_name`, Argo CD | `echo-dev-eks` | 예정 |
| `eks_cluster_endpoint` | Argo CD, AI 에이전트(읽기) | `https://…eks.amazonaws.com` | 예정 |
| `vpc_id` | 앱·이전 엔진 | `vpc-…` | 예정 |
| `vpc_cidr` | GCP·온프레(VPN), 복제 | `10.50.0.0/16` | 예정 |
| `private_subnet_ids` | 앱(DB 위치 결정 시) | `["subnet-…"]` | 예정 |
| `ecr_repository_urls` | 빌드·배포, 앱 | `{ app = "…/echo/app" }` | 예정 |

bootstrap 출력값: `state_bucket`(다른 루트의 `backend.hcl`), `region`.
