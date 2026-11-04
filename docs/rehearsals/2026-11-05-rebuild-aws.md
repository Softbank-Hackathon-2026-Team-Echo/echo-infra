# 환경 재구축 리허설 2026-11-05 01:00 KST — AWS 도쿄 (인프라 11, NFR-16)

같은 Terraform 코드로 **이름만 다른 AWS 환경(`echorh-dev`)을 옆에 세우고** "명령 2개로 세워지는가 + 걸리는 시간"을 쟀다.
운영 dev(`echo-dev-eks`·A DB·공유 문)는 다른 workspace·다른 VPC 라 한 건도 바뀌지 않았다(plan: 0 to change, 0 to destroy).

## 방법

| 항목 | 값 |
|---|---|
| 루트 | `terraform/environments/aws/dev` (같은 코드) |
| 상태 | workspace `rehearsal` (같은 버킷, `env:/rehearsal/aws/dev/terraform.tfstate`) |
| 이름 | `-var project=echorh` → `echorh-dev-*`, ECR `echorh/app`, 역할 `echorh-dev-eks-lbc` (`-var lbc_role_name= lbc_policy_name=`) |
| 제외 | `-target` 으로 ci.tf 의 11개(GitHub·Google OIDC 공급자, CI 역할 2개, 실행기 역할·접근 항목) — OIDC 공급자는 계정당 하나라 두 번째 환경을 같은 계정에 못 만든다 |
| 공유 문 | `aws eks update-kubeconfig` → helm `aws-load-balancer-controller` 3.6.2 (`cluster-addons/README.md` 와 같은 값) → 닻 Ingress(`load-balancer-name` 만 `echorh-dev-apps` 로) |
| 확인 | 진입점 VM 에서 닻 ALB `/healthz` → 200 (ALB 는 진입점·GKE NAT 만 받는다) |

## 시간 (실측)

| 단계 | 시간 | 메모 |
|---|---|---|
| `terraform apply` (46개) | **10분 56초** | NAT 1분 45초, **EKS 컨트롤 플레인 8분 16초**, 노드 그룹 1분 19초 |
| 공유 문 (helm + 닻 Ingress → ALB active → /healthz 200) | **2분 7초** | ALB 컨트롤러 권한은 Terraform(lbc.tf) 이 함께 만듦 |
| **합계** | **13분 3초** | 01:00:36 → 01:13:39 |
| 정리 (닻 Ingress 삭제 → `terraform destroy` 46개) | **7분 22초** | EKS 삭제 2분 23초. 뒤에 남은 자원 0(EKS 목록 dev 만, VPC·역할·ECR·인증서 없음, EIP 3개 그대로) |

## 결과

- 46개 자원 생성, 실패 0. 명령은 둘: `terraform apply`, 그리고 공유 문(helm 1 + kubectl 1). "환경 하나 = apply + cluster-addons" 가 성립한다.
- **ACM 인증서가 자동 발급됐다**: 같은 계정·같은 도메인(`*.aws-tokyo.echoport.uk`)이면 검증 CNAME 이 같아서, 11/3 에 Cloudflare 에 넣어 둔 레코드로 새 인증서(01:00:41 생성)가 바로 ISSUED. 재구축 때 DNS 담당 손이 안 간다.
- 닻 ALB(`echorh-dev-apps`)가 기존 dev 인증서 ARN 으로 443 까지 올라왔다.

## 발견 (코드·절차에 반영할 것)

| 발견 | 처리 |
|---|---|
| ALB 컨트롤러의 IAM 역할·정책·Pod Identity 가 코드 밖(11/2 CLI) | **반영됨**: `lbc.tf` 로 import(#60). 컨트롤러 helm 명령은 `cluster-addons/README.md` |
| OIDC 공급자(GitHub·Google)는 계정당 하나 → 같은 계정에 두 번째 환경 불가 | 후속: `create_oidc_providers=false` 면 data 로 참조하는 변수. 지금은 `-target` 으로 제외 |
| ECR 이름 `echo/app` 이 환경 무관 → 두 번째 환경이 같은 이름을 만들려 함 | 후속: `${local.name}/app` 또는 공유 저장소로 명시. 지금은 `project` 변수로 우회 |
| 닻 Ingress 의 `load-balancer-name` 이 `echo-dev-apps` 고정 | 후속: 클러스터 이름에서 파생(kustomize 변수) |
| **실제 dev 를 부수고 다시 세울 때 추가로 필요한 재연결** | ALB 주소가 바뀜 → Cloudflare `*.aws-tokyo` CNAME + 진입점 `entrypoint_upstreams` tfvars 재apply(GCP) → A DB 재생성(`replication/k8s/aws-tokyo` apply -k + Secret) → `subscribe.sh` → echo-was 환경 재확인. 명령 2개 밖의 일이 5단계. 설계 문서 9절에 적는다 |

## 되돌리기

`11-teardown`: 닻 Ingress 삭제(ALB 가 VPC 삭제를 막지 않게) → `terraform destroy`(같은 target, workspace `rehearsal`). dev 는 건드리지 않는다.
