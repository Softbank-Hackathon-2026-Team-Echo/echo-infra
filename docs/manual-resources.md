# 손으로 만든 자원 목록 (인프라 3.3)

echo-was 실제 실행기를 켜는 동안(11/3~11/4) 시간 때문에 Terraform 밖에서 만든 자원이다. 환경을 다시 세울 때([#11](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-infra/issues/11)) 아래 표를 위에서 아래로 따라가면 같은 상태가 된다. 값(비밀)은 이 저장소에 없고, 만드는 방법만 있다.

## Terraform 으로 옮긴 것 (GCP `terraform/environments/gcp/dev/control-plane.tf`)

| 자원 | Terraform 자원 | 값(version)은 | 다시 만들 때 |
|---|---|---|---|
| Secret Manager `echo-dev-echo-was-cloudflare-dns-token` | `google_secret_manager_secret.control_plane_executor["cloudflare_dns_token"]` | 사람이 넣는다 | `terraform apply` 로 껍데기 → 아래 Cloudflare 토큰 절의 명령으로 값 |
| Secret Manager `echo-dev-echo-was-onprem-executor-token` | `…control_plane_executor["onprem_executor_token"]` | 사람이 넣는다 | `terraform apply` 로 껍데기 → [onprem/README.md](../onprem/README.md) 의 "3) 토큰을 echo-was 비밀 저장소로" |
| GSA `echo-dev-echo-was` 의 위 두 비밀 읽기 권한(`secretAccessor`, 이 비밀만) | `google_secret_manager_secret_iam_member.control_plane_executor_accessor[*]` | - | `terraform apply` |

- 껍데기만 Terraform 이 갖는다. `google_secret_manager_secret_version` 은 만들지 않는다(값이 state 에 남지 않게).
- 11/3 에 CLI 로 먼저 만든 자원이라 `import` 블록으로 가져왔고, 11/4 apply 뒤 블록은 지웠다(state 에 4개 자원이 있다).
- 새 환경에서 apply 만 하면 껍데기와 권한이 생긴다. 값이 없으면 echo-was 일꾼의 해당 기능(대표 주소 레코드·온프레 배포)이 비밀을 못 읽어 실패한다.
- 진입점 9090 방화벽 `echo-dev-entry-remote-write` 의 허용 CIDR(`entrypoint_remote_write_cidrs`, 적용자 로컬 tfvars)의 원본은 온프레 EIP 다 — `terraform/environments/aws/onprem-demo` 의 `terraform output public_ip` 에 `/32` 를 붙여 넣는다(EIP 를 다시 만들면 이 값도 바꿔 apply).

## Terraform 으로 옮기지 않은 것: Cloudflare (손으로 관리)

Cloudflare 는 지민 개인 계정에 있고 영역 `echoport.uk` 를 갖는다. 토큰 권한과 계정 소유 문제로 Terraform 에 넣지 않았다. **바꿀 수 있는 사람은 계정 주인인 지민이다**(다른 팀원의 접근은 확인되지 않았다). 팀원이 바꿔야 하면 지민에게 이슈로 요청한다.

### DNS 레코드

| 이름 | 종류 → 값 | 프록시 | 용도 | 다시 만들 때 |
|---|---|---|---|---|
| `*.echoport.uk` | A → 고정 진입점 IP (`terraform output entrypoint_ip`, GCP dev 루트) | 켬(주황 구름) | 대표 주소 `{서비스}-{8자}.echoport.uk` | 대시보드 DNS → 레코드 추가, 또는 아래 API 예시 |
| `*.aws-tokyo.echoport.uk` | CNAME → 닻 ALB DNS (`kubectl -n echo-apps-anchor get ingress anchor`) | 끔(DNS only) | EKS 앱 주소 | 같음 |
| `*.gcp-seoul.echoport.uk` | A → GKE ingress-nginx 내부 IP (`kubectl -n ingress-nginx get svc ingress-nginx-controller`, 지금 `10.60.0.8`) | 끔 | GKE 앱 주소(VPC 안에서만 의미 있음) | 같음 |
| ACM 검증 CNAME | `terraform output acm_validation_records` (AWS dev 루트) | 끔 | `*.aws-tokyo.echoport.uk` 인증서 검증 | 같음 |
| 온프레 터널 CNAME (`demo-onprem-…`, `k3s-…`) | `cloudflared tunnel route dns` 가 만든다 | 켬 | 온프레 데모·k3s 창구 | [onprem/README.md](../onprem/README.md) |

API 예시(토큰은 Secret Manager 에서 바로 넘기고 화면에 찍지 않는다. 영역 id 는 대시보드 영역 개요에 있다):

```bash
CF_TOKEN=$(gcloud secrets versions access latest --secret=echo-dev-echo-was-cloudflare-dns-token)
curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/<영역 id>/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  --data '{"type":"A","name":"*.echoport.uk","content":"<entrypoint_ip>","proxied":true}'
```

### 설정 규칙

| 이름 | 내용 | 왜 | 다시 만들 때 |
|---|---|---|---|
| 구성 규칙 "진입점 대표 주소: 원본 HTTP 80 (Flexible)" | 조건 `http.host ne "app.echoport.uk"` → SSL 을 Flexible 로. 영역 전체 SSL 모드는 "전체(Full)" 그대로 | 진입점 Envoy 가 80 만 받는다 | 대시보드 규칙 → 구성 규칙 → 규칙 만들기 (위 조건·SSL=Flexible). echo-was 용 토큰 권한은 DNS 편집·영역 읽기뿐이라 이 규칙은 대시보드에서 바꾼다 |

**보류 기록(11/4)**: 이 규칙 때문에 Cloudflare → 진입점 구간은 암호화 없는 HTTP 80 이다. 손님 → Cloudflare 구간은 HTTPS 다. 시연에는 영향이 없어 Full (strict) 전환(Envoy 443 + Origin 인증서)은 보류했다. 하게 되면 할 일과 선택지는 [이슈 46](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-infra/issues/46).

### Cloudflare API 토큰 (echo-was 용)

| 항목 | 내용 |
|---|---|
| 권한 | 영역 `echoport.uk` 의 DNS 편집 + 영역 읽기만. 다른 영역·계정 권한 없음 |
| 만드는 곳 | 대시보드 내 프로필 → API 토큰 → "영역 DNS 편집" 템플릿, 영역 범위를 `echoport.uk` 하나로 |
| 쓰는 곳 | echo-was 일꾼(대표 주소 레코드 생성), GKE cert-manager(DNS-01), 위 API 예시 |
| 값을 넣는 명령 | `printf %s "$TOKEN" \| gcloud secrets versions add echo-dev-echo-was-cloudflare-dns-token --data-file=-` (껍데기는 Terraform) |
| GKE 로 넘기기 | `cluster-addons/README.md` 의 cert-manager 절 (`cert-manager/cloudflare-dns-token` Secret) |
| 확인 | `curl -sS -H "Authorization: Bearer $CF_TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify` → `"status":"active"` |

## Kubernetes 에 손으로 적용한 것

| 자원 | 어디 | 파일 | 다시 만들 때 |
|---|---|---|---|
| AWS Load Balancer Controller 3.6.2 (Helm release `aws-load-balancer-controller`) | EKS `echo-dev-eks` ns `kube-system` | 권한(역할 `echo-was-lbc`·정책·Pod Identity)은 11/4 Terraform `lbc.tf` 로 import. 컨트롤러는 [cluster-addons/README.md](../cluster-addons/README.md) 의 helm 명령 | 같은 README |
| cert-manager v1.21.3 (Helm release `cert-manager`) | GKE `echo-dev-gke` ns `cert-manager` | `cluster-addons/gke/cert-manager/values.yaml` | [cluster-addons/README.md](../cluster-addons/README.md) 4) 절 |
| Secret `cert-manager/cloudflare-dns-token` | 같음 | 파일 없음(값은 Secret Manager 에서 넘김) | 같은 절의 `gcloud secrets versions access … \| kubectl create secret` |
| ClusterIssuer `letsencrypt-dns` · Certificate `ingress-nginx/wildcard-gcp-seoul` | 같음 | `cluster-addons/gke/cert-manager/wildcard-gcp-seoul.yaml` | 같은 절의 `kubectl apply -f` |
| ingress-nginx · EKS 닻 Ingress | GKE / EKS | `cluster-addons/gke/ingress-nginx-values.yaml`, `cluster-addons/eks/anchor-ingress.yaml` | [cluster-addons/README.md](../cluster-addons/README.md) "설치" 절 |
| 서울 B(Postgres·PgBouncer·외부 LB `34.158.218.66`·내부 LB `echo-pg-internal` `10.63.0.15`) — 인프라 16 2단계(11/7) | GKE **`echo-dev-customer-gke`** ns `echo-data` | `replication/k8s/gcp-seoul/{00,10,20,30,35}` (단 PVC 는 `storageClassName: standard`(pd-standard) 로 바꿔 적용 — SSD 할당량 220/250 유지. 파일은 `standard-rwo` 그대로) | `replication/k8s/README.md` 적용 순서 + 구독은 `subscribe.sh` |
| 컷오버 Job 의 고객 클러스터 권한 | GKE `echo-dev-customer-gke` ns `echo-data` | `replication/cutover-job/deploy/gcp-seoul-customer` | `kubectl apply -k` |
| 풀 계층(PgBouncer-DB 분리, #114) — 3단계까지(11/7) | EKS `echo-dev-eks` · GKE `echo-dev-customer-gke` ns `echo-pool` + `echo-data/db-writer` | `replication/k8s/pool/{aws-tokyo,gcp-seoul}` · `replication/cutover-job/deploy/{aws-tokyo,gcp-seoul-customer}{,-pool}` | `replication/k8s/pool/README.md` "옮기는 순서" 3단계 |
| Secret `echo-pool/echo-pgbouncer-secret`(app_rw SCRAM 검증자 + 관리 계정) | EKS · 고객 GKE | 파일 없음(값은 A 의 `pg_authid` 와 새로 만든 관리 비밀번호) | `replication/k8s/pool/base/secret.example.yaml` 의 명령 |
| 서울 표지판 뒤 EndpointSlice `echo-data/db-writer-manual`(도쿄 A NLB IP) | GKE `echo-dev-customer-gke` | 파일 없음(주소는 그때 NLB 이름을 IP 로 풀어 넣는다) | `replication/k8s/scripts/pool-point.sh B "$A_HOST"` (컷오버·롤백 때는 스크립트가 바꾼다) |
| Service `ingress-nginx/ingress-nginx-entry-c`(진입점 c 전용 외부 L4 LB **34.47.94.41**, 출처 `3.39.160.158/32` 만) — 11/7 23:12 관제탑 `echo-dev-gke` 에서 옮김 | GKE **`echo-dev-customer-gke`** ns `ingress-nginx` | `cluster-addons/gke/ingress-nginx-external-entry-c.yaml`(`loadBalancerIP` = 아래 정적 주소) | 파일 머리말의 apply 명령. GKE 가 LB·방화벽(`k8s-fw-<LB 이름>`·`-deny`·`-http-hc`)을 만든다 |

## GCP 에 손으로 만든 주소 (Terraform 밖)

| 자원 | 값 | 왜 손으로 | 다시 만들 때 |
|---|---|---|---|
| 정적 외부 주소 `echo-dev-entry-c-gke` (asia-northeast3, EXTERNAL, PREMIUM) — 11/7 23:11 | `34.47.94.41`. 관제탑 Service 가 쓰던 **임시** IP 를 승격했다. 진입점 c 의 `UPSTREAMS gcp=34.47.94.41:80`(aws/dev `entrypoint_c_upstreams`, S3 `settings.env`)가 이 IP 를 가리킨다 | 클러스터를 옮겨도 c 설정·Terraform(aws/dev)을 바꾸지 않으려고. Service 를 지워도 IP 가 남는다 | `gcloud compute addresses create echo-dev-entry-c-gke --addresses=<IP> --region=asia-northeast3`(사용 중 임시 IP 승격, 끊김 없음). 이 IP 를 잃으면 새 IP 로 c 의 UPSTREAMS 를 바꿔야 한다. **이름을 GKE LB 이름(a+31자 hex)으로 짓지 않는다** — GKE 정리 로직이 LB 이름과 같은 주소를 지운다. Service 를 영구히 없애면 이 주소도 `addresses delete` 해야 미사용 IP 과금이 멈춘다 |

## GCP IAM·VM 메타데이터를 손으로 바꾼 것 (인프라 16 2단계, 11/7 — Terraform 반영 필요)

| 무엇 | 값 | 왜 손으로 | Terraform 에 넣을 때 |
|---|---|---|---|
| 컷오버 GSA `echo-dev-cutover` 프로젝트 역할 | `roles/container.clusterViewer` | 컷오버 Job(관제탑 클러스터)이 고객 클러스터 주소·CA 를 GKE API 로 읽고 인증 | `cutover.tf` 에 `google_project_iam_member` 1개(“프로젝트 역할 없음” 원칙 예외 — 읽기 전용, 클러스터 내 권한은 RBAC 로만) |
| 진입점 VM a·b startup-script `UPSTREAMS` | `gcp=10.63.0.14:80`(고객 클러스터 ingress-nginx 내부 LB) | 동옥 `terraform.tfvars` 가 M1 에 없어 `-target` apply 시 다른 변수 기본값이 섞임 → `add-metadata` 로 한 줄만 | tfvars `entrypoint_upstreams.gcp = "10.63.0.14:80"` → plan 이 No changes 인지 확인 |

## 이미 코드에 반영된 것

executor 역할 신뢰 조건([#41](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-infra/pull/41)), 온프레 실행기 신원·라벨 정책([#36](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-infra/pull/36)).

## 지금 상태 확인 (2026-11-04)

| 확인 | 결과 |
|---|---|
| `gcloud secrets list` 의 두 비밀 | 존재, version 1 사용 가능, 라벨 `managed-by=terraform` |
| 두 비밀의 IAM | `echo-dev-echo-was` GSA 의 `secretAccessor` 하나씩 |
| GKE | cert-manager 3개 Deployment 1/1, ClusterIssuer `letsencrypt-dns` Ready, Certificate `wildcard-gcp-seoul` Ready |
| `dig x.echoport.uk` / `x.aws-tokyo.echoport.uk` / `x.gcp-seoul.echoport.uk` | Cloudflare 프록시 IP / ALB CNAME / `10.60.0.8` |
