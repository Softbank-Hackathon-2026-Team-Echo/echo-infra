# AWS 출력값 계약

`terraform/environments/aws/dev` 의 출력값 이름이다. 다른 파트는 이 이름으로 값을 받는다. 이름을 바꾸면 PR 체크리스트에 적고 받는 쪽에 알린다.

| 출력값 | 받는 쪽 | 예 | 상태 |
|---|---|---|---|
| `region` | echo-was `AwsEnvironmentConfig.region` | `ap-northeast-1` | 적용 (11/2) |
| `eks_cluster_name` | echo-was `AwsEnvironmentConfig.cluster_name`, Argo CD | `echo-dev-eks` | 적용 (11/2) |
| `eks_cluster_endpoint` | Argo CD, AI 에이전트(읽기) | `https://…eks.amazonaws.com` | 적용 (11/2) |
| `vpc_id` | 앱·이전 엔진 | `vpc-…` | 적용 (11/2) |
| `vpc_cidr` | GCP·온프레(VPN), 복제 | `10.50.0.0/16` | 적용 (11/2) |
| `private_subnet_ids` | 앱(DB 위치 결정 시) | `["subnet-…"]` | 적용 (11/2) |
| `ecr_repository_urls` | 빌드·배포, 앱 | `{ app = "…/echo/app" }` | 적용 (11/2) |
| `ci_build_role_arn` | **빌드 실행기**: echo-was 저장소 GitHub Actions(main)가 `aws-actions/configure-aws-credentials` `role-to-assume` 로 받아 ECR push | `arn:aws:iam::…:role/echo-dev-ci-build` | 코드 (11/3) |
| `executor_role_arn` | **배포 실행기**: GKE 위 echo-was 일꾼이 관제탑 GSA 의 Google ID 토큰으로 받아 EKS 접근 (`sts assume-role-with-web-identity`) | `arn:aws:iam::…:role/echo-dev-executor` | 코드 (11/3) |
| `cutover_role_arn` | **컷오버 Job**(인프라 12.2): 컷오버 이미지 빌드 인자 `AWS_ROLE_ARN`. 컷오버 GSA 의 Google ID 토큰으로만 받고, EKS 에는 그룹 `echo-cutover`(echo-data Role)로만 들어간다 | `arn:aws:iam::…:role/echo-dev-cutover` | 코드 (11/5) |

## 환경별 주소 대역 (2026-11-02 확정)

사설망(VPN)으로 복제·연결할 때 겹치면 안 된다. AWS·GCP 는 아래 대역을 쓰고, K3s 는 기본값을 쓴다. 바꾸려면 이 표를 먼저 고친다. (11/2 20시 회의: 온프레는 일단 범위 밖)

| 환경 | 노드·VPC | 파드 | 서비스 |
|---|---|---|---|
| AWS EKS (도쿄) | `10.50.0.0/16` | VPC 대역 안 (VPC CNI) | EKS 기본 (`10.100.0.0/16` 또는 `172.20.0.0/16`) |
| GCP GKE (서울) | `10.60.0.0/20` (노드) | `10.61.0.0/16` | `10.62.0.0/20` (컨트롤 플레인 `172.16.0.0/28`) |
| 온프레 K3s | 현장 LAN (시연 기기: AWS 서울 기본 VPC `172.31.0.0/16`, 다른 망과 연결 안 함) | `10.42.0.0/16` (K3s 기본) | `10.43.0.0/16` (K3s 기본) |
| AI 샌드박스 (GCP 서울, `gcp/ai-sandbox`) | `10.70.0.0/24` (VM 서브넷, **다른 망과 연결 안 함**) | — | — |
| AI 샌드박스 테스트 DB (Cloud SQL 사설 IP 예약) | `10.71.0.0/24` (샌드박스 VPC 와만 서비스 네트워킹 피어링) | — | — |

bootstrap 출력값: `state_bucket`(다른 루트의 `backend.hcl`), `region`.
