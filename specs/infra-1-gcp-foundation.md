# 인프라·이전 엔진 1 (GCP 절반): GKE 대피처 기반 SPEC

- 상태: Draft (팀 검토 전)
- 확인일: 2026-11-02
- GitHub 이슈: echo-infra #1 `[인프라·이전 엔진 1] 클라우드 계정 · 비용 알림 + Terraform (EKS·GKE)` 의 **GCP 절반**. AWS 절반은 [infra-1-aws-foundation.md](infra-1-aws-foundation.md).
- 저장소: `echo-infra` · 브랜치 `feat/aws-foundation` (AWS 와 같은 PR 로 간다)
- 작성: 서동옥

## 1. 목표

GCP 서울(asia-northeast3)에 대피처 1(GKE)을 Terraform 으로 세운다. 평소 Warm(노드 2대), 경계 시 Hot(3대). 도쿄가 죽어도 서울이 혼자 설 수 있게 **state·이미지·비밀값을 GCP 안에 따로 둔다**(docs/architecture.md §5). echo-was 가 `gcp-seoul` 환경으로 등록할 수 있게 출력값 이름을 고정한다.

## 2. 맥락 (11/2 20시 회의)

- 데이터 평면: AWS 일본 = 출발·재난 지역(EKS 고객 앱 + PostgreSQL 주 DB, 쓰기는 한 곳만), GCP 서울 = 대피처 1(GKE 고객 앱 + PostgreSQL 복제본), 온프레 k3s = 대피처 2(**일단 범위 밖**).
- 고정 진입점(Envoy, 주소 `{서비스}.echoport.uk`)과 측정·관측(요청 수·오류율·p95, 이전마다 RPO·전환 시간 기록)은 인프라 담당(서동옥)이 맡는다 → `entrypoint/`, `entrypoint.tf`.
- 복제 경로: AWS PostgreSQL → GKE 복제본(논리 복제, 데이터 담당). 구독자(GKE)가 발행자(AWS)에 붙어야 하므로 GKE 의 나가는 IP 를 고정(Cloud NAT 고정 IP)하고 AWS 보안 그룹 허용 목록에 적는다.

## 3. 범위

### 포함

- `terraform/bootstrap/gcp`: state 버킷(GCS, 버전 관리, 공개 차단, prevent_destroy)
- `terraform/environments/gcp/dev`: API 켜기, VPC·서브넷(보조 대역)·Cloud NAT 고정 IP, GKE 존 클러스터 + 노드 풀(2~3대), Artifact Registry(태그 불변), 팀원 IAM, Workload Identity 연합(CI plan), 비용 알림(선택)
- 출력값 계약 `contracts/gcp-outputs.md`, `make up CLOUD=gcp` / `make down CLOUD=gcp`

### 제외 (다른 이슈·담당)

- 고정 진입점 VM·Envoy·관측 스택 → `entrypoint.tf`(같은 루트, 별도 커밋)
- Argo CD 설치·클러스터 등록, ECR → Artifact Registry 이미지 복사 workflow (#3)
- PostgreSQL 복제본 배치·논리 복제 (#7, 데이터 담당)
- 온프레 k3s (#2, 일단 범위 밖)

## 4. 구성 요소

| 구성 요소 | 위치 | 설명 |
|---|---|---|
| state 버킷 | `bootstrap/gcp` | `echo-tfstate-<project_id>`, 서울 |
| API | `apis.tf` | compute·container·artifactregistry·iam·sts·secretmanager·billingbudgets 등. `make down` 때 끄지 않는다 |
| 네트워크 | `network.tf` | VPC `echo-dev`, 서브넷 `10.60.0.0/20`, 파드 `10.61.0.0/16`, 서비스 `10.62.0.0/20`, Cloud NAT 고정 IP(`nat_ip`) |
| GKE | `gke.tf` | 존 클러스터 `echo-dev-gke`(asia-northeast3-a), REGULAR 채널, 사설 노드 + 공개 API(허용 CIDR), Dataplane V2, Workload Identity, 노드 풀 e2-standard-2 ×2~3, 전용 노드 SA |
| 이미지 | `registry.tf` | Artifact Registry `echo`(DOCKER, 태그 불변). 경로 `asia-northeast3-docker.pkg.dev/<project>/echo/app` |
| CI | `ci.tf` | GitHub Workload Identity 연합(main·PR 만) + `echo-dev-ci-plan` SA(viewer) |
| 비용 | `budget.tf` | 결제 계정 ID 가 있을 때만 월 예산(80% 실제·100% 예측) |

## 5. 결정

| 결정 | 선택 | 대안과 버린 이유 |
|---|---|---|
| 클러스터 종류 | Standard 존 클러스터 | Autopilot: 파드 단위 과금이라 Warm 대기 비용은 싸지만 특권 파드·호스트 네트워크 제약으로 Envoy·OTel·DB 복제본이 걸릴 수 있다. 리전 클러스터: 관리비 3배, 데모에 불필요 |
| 노드 | e2-standard-2 ×2 (최대 3) | e2-medium: 공유 코어라 PostgreSQL 복제본 + 앱 + OTel 에 빠듯 |
| 노드 네트워크 | 사설 노드 + Cloud NAT 고정 IP | 공개 노드: 복제 허용 목록에 노드 IP 를 일일이 못 적는다 |
| 이미지 | AR 에 ECR 사본 (같은 digest) | GKE 가 ECR 에서 받기: 도쿄가 죽으면 서울 배포도 막힌다(예선 iris-infra 가 그랬다) |
| 자격 증명 | ADC(사용자) + WIF(CI) | 서비스 계정 키 파일: NFR-17 위반 |
| 기본 노드 풀 | `remove_default_node_pool=true` + `initial_node_count=1` | provider 8.9 가 deprecation 경고를 낸다(1.36.4-gke.1469000+ 에서는 `initial_node_count=0`). 채널 버전이 확인되면 바꾼다 |

## 6. 비용 (대략, 서울)

| 항목 | 하루 |
|---|---|
| GKE 존 클러스터 관리비 | 결제 계정당 존 클러스터 1개는 무료, 아니면 $2.4 |
| e2-standard-2 ×2 | $3.2 (3대면 $4.8) |
| Cloud NAT + 고정 IP | $1.1 + 전송량 |
| 디스크·AR·로그 | $0.5 안팎 |
| **합** | **$5~7 (₩7,000~10,000)**, 6일 ₩5~6만 |

## 7. 검증

- `bash scripts/check.sh`: fmt·validate(루트 4개)·tflint(google 룰셋 0.41.0) 통과 (11/2 21:30).
- `terraform plan` 은 GCP 프로젝트와 ADC 가 생기면 돌린다. apply 는 plan 확인 뒤.

## 8. 적용 순서 (사람)

1. 구글 계정에 본선 프로젝트 만들고 결제 계정 연결(크레딧 확인).
2. `gcloud auth login` → `gcloud auth application-default login` → `gcloud config set project <id>`.
3. `terraform -chdir=terraform/bootstrap/gcp apply`(로컬 state 1회) → `state_bucket` 출력값.
4. `environments/gcp/dev/backend.hcl`·`terraform.tfvars` 채우고 `make plan CLOUD=gcp` → 확인 → `make up CLOUD=gcp` (GKE 생성 약 10분).
5. `gcloud container clusters get-credentials echo-dev-gke --zone asia-northeast3-a` 로 kubeconfig. 팀원은 `gke_admin_members` 에 넣는다.
6. `nat_ip` 를 AWS 쪽 PostgreSQL 보안 그룹에 적는다(데이터 담당에게 전달).

## 9. 리스크

| 리스크 | 대응 |
|---|---|
| GCP 프로젝트 소유 계정·크레딧이 정해지지 않음 | 회의 결정 필요. 개인 계정 무료 크레딧($300)이면 결제 계정 업그레이드 뒤 GKE 가능 |
| 쿼터(서울 e2 vCPU 기본 24 안팎) | 3대 ×2 vCPU = 6, 문제 없음 |
| AWS PostgreSQL 을 공개 엔드포인트로 노출 | NLB + 보안 그룹 `nat_ip`/32 만 허용 + TLS 강제. 데모 후 폐기 |
| `make down` 때 AR 에 이미지가 남아 삭제 실패 | AR 저장소는 force 삭제 옵션이 없어 이미지를 먼저 지운다(runbook) |

## 10. 남은 것

- 적용(위 8).
- `entrypoint.tf`(Envoy VM·관측) 출력값을 계약에 추가.
- ECR → AR 복사 workflow, Argo CD 클러스터 등록(#3).
- 도쿄 state 사본을 GCS 에 두는 방법(§5-1).
