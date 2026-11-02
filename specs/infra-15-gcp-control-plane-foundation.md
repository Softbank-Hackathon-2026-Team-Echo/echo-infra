# 인프라·이전 엔진 15: GCP 관제탑 기반 SPEC

- 상태: 구현 완료, apply 전
- 확인일: 2026-11-02
- GitHub 이슈: echo-infra #15 `[결정] API 서버(echo-was) 운영 인프라 먼저 정의 가능 여부`
- 저장소: `echo-infra` · 브랜치 `feat/gcp-control-plane-foundation`
- 작성: 서동옥

## 1. 목표

AWS 도쿄 리전 장애 중에도 관리 화면과 이전 실행기가 살아 있도록 관제탑을 데이터 평면과 분리한다. 프론트는 Cloudflare Pages를 유지하고, echo-was API·Worker·관리용 PostgreSQL이 GCP 서울 GKE에 배포될 수 있는 클라우드 기반을 Terraform으로 제공한다.

## 2. 역할 경계

### 이 작업에 포함

- GKE Secret Manager CSI 및 Kubernetes Secret 동기화 기능
- echo-was 전용 GCP 서비스 계정과 Workload Identity 연결
- DB URL·GitHub App 개인키·client secret을 담을 Secret Manager 리소스(값 제외)
- `api.echoport.uk`용 전역 고정 IP와 Google 관리형 TLS 인증서
- 앱 담당이 사용할 Terraform 출력값 계약

### 다른 담당

- echo-was API·Worker·PostgreSQL Kubernetes 객체
- Alembic migration과 기존 AWS 관리 DB 데이터 이전
- Secret Manager secret version 입력
- GKE Ingress와 Cloudflare DNS 레코드 연결
- GitHub 로그인과 배포 실행기 동작 검증

## 3. 결정

| 결정 | 선택 | 이유 |
|---|---|---|
| 관제탑 위치 | GCP 서울 GKE | 출발 리전인 AWS 도쿄와 장애 영역 분리 |
| 프론트 위치 | Cloudflare Pages 유지 | 이미 AWS·GCP와 분리돼 있음 |
| 비밀 전달 | Secret Manager CSI + SecretSync | 저장소·Terraform state·이미지에 값 0건 |
| 파드 권한 | 전용 GSA + Workload Identity | 서비스 계정 키 파일을 만들지 않음 |
| 비밀 접근 범위 | echo-was 전용 3개 secret만 | 프로젝트 전체 secretAccessor 금지 |
| API 주소 | 전역 고정 IP + 관리형 인증서 | GKE Ingress 재생성에도 DNS 주소 유지 |

## 4. 인프라 계약

| 출력값 | 의미 |
|---|---|
| `control_plane_ip` | Cloudflare `api.echoport.uk` A 레코드 대상 |
| `control_plane_certificate_name` | GKE Ingress pre-shared certificate |
| `control_plane_service_account` | KSA annotation에 넣을 GSA 이메일 |
| `control_plane_kubernetes_identity` | namespace·KSA 고정 이름 |
| `control_plane_secret_ids` | API 담당이 version을 추가할 secret ID |

구체적인 연결 예시는 `contracts/gcp-outputs.md`가 단일 출처다.

## 5. 완료 기준

- [x] 비밀값 없이 Terraform 코드로 GSA·IAM·Secret Manager·고정 IP·인증서를 정의한다.
- [x] echo-was 파드가 사용할 Workload Identity 주체를 고정한다.
- [x] GKE Secret Manager CSI·SecretSync를 켠다.
- [x] 앱 담당에게 전달할 출력값과 annotation 계약을 문서화한다.
- [x] `terraform plan` 확인: 10개 생성, GKE addon 1개 변경, 삭제 0개.
- [ ] 사용자 승인 후 apply하고 실제 출력값을 지민에게 전달한다.

## 6. 적용 후 인수인계

1. `terraform output -json`에서 관제탑 출력값을 확인한다.
2. API 담당이 세 secret에 version을 추가한다. 값은 채팅·이슈·저장소에 남기지 않는다.
3. API 담당이 namespace와 KSA를 만들고 GSA annotation을 붙인다.
4. SecretSync로 Kubernetes Secret을 만들고 API·Worker·migration Job에 주입한다.
5. GKE Ingress에 고정 IP·인증서 annotation을 넣는다.
6. DNS 담당이 `api.echoport.uk`를 `control_plane_ip`로 변경한다. Google 관리형 인증서가 `ACTIVE`가 될 때까지 Cloudflare는 DNS only로 둔다.
7. `/healthz`, `/readyz`, GitHub 로그인, Worker 처리를 확인한 후 AWS echo-was를 내린다.

## 7. 롤백

- DNS를 기존 AWS ALB로 되돌리면 API 트래픽은 즉시 기존 관제탑으로 복귀한다.
- GCP 리소스 apply 전에는 코드 revert만으로 끝난다.
- apply 후에는 secret version과 앱 Kubernetes 객체를 먼저 제거하고 Terraform 리소스를 정리한다.
