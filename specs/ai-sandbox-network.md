# AI 에이전트 샌드박스 망·VM SPEC

- 상태: 코드 작성, **plan·apply 전**(인프라 담당 리뷰 뒤 apply)
- 확인일: 2026-11-04
- GitHub 이슈: echo-ai-agent #1(SDK·모델·샌드박스 결정) · #2(샌드박스 생성·실행·로그)
- 저장소: `echo-infra` · 브랜치 `feat/ai-sandbox-network`
- 작성: 김형래(보안·AI)
- 설계 근거: echo-ai-agent `specs/ai-1-sdk-model-sandbox.md` D-4(사용자 결정 11/3)·AD-5·AD-6, 7절 보안 요건

## 1. 목표

AI 에이전트가 고객 앱 사본을 점검·수정할 **운영과 분리된 실행 환경**을 같은 GCP 프로젝트(`team-echo-final`) 안에 만든다. VM 안에서는 실행마다 새 Docker 컨테이너(작업 공간·검사)를 만들고 지운다(echo-ai-agent 러너).

## 2. 역할 경계

### 이 작업에 포함
- 새 루트 `terraform/environments/gcp/ai-sandbox/`(상태 `gcp/ai-sandbox`)
- 새 VPC·서브넷·Cloud Router·NAT, 방화벽(IAP SSH 들어옴, 443만 나감)
- VM 서비스 계정(프로젝트 역할 0개), 비밀 껍데기 3개 + 비밀 단위 읽기 권한
- VM 1대(공인 IP 없음, Shielded VM, OS Login, 시작 스크립트는 Docker 설치만)
- `iap.googleapis.com` 켜기

### 하지 않는다
- 기존 `gcp/dev` 루트·`echo-dev` VPC·방화벽·IAM은 바꾸지 않는다. compute·iam·secretmanager API는 `gcp/dev`가 켠 것을 쓰고 다시 관리하지 않는다
- 비밀 값 넣기(사람이 `gcloud secrets versions add`), 러너 코드 배포(echo-ai-agent 다음 단계)

## 3. 결정

| ID | 결정 | 이유 |
|---|---|---|
| D-1 | 같은 프로젝트의 **새 VPC**. 피어링·공유 VPC·VPN 없음 | 운영 대역(`10.60.0.0/20` 등)·WAS DB·진입점에 닿지 못하게. 프로젝트를 새로 만들지 않아 권한·결제 준비가 없다 |
| D-2 | 새 루트·새 상태 경로 | `gcp/dev` apply·destroy와 서로 영향이 없다 |
| D-3 | 들어오는 연결은 IAP 대역(`35.235.240.0/20`)의 22만. 공인 IP 없음 | 외부에서 직접 접속 불가 |
| D-4 | 나가는 연결은 NAT로 443만(`egress-https` 1000 허용, `egress-deny` 65000 전부 거부). apt도 https로 받는다 | Anthropic API·`api.echoport.uk`·GitHub·패키지만 필요. 도메인 목록은 제어 프로세스가 지킨다 |
| D-5 | VM SA는 **프로젝트 역할 0개**. 비밀 3개(`echo-sandbox-anthropic-api-key`·`-was-runner-token`·`-was-agent-token`)만 `secretAccessor`를 비밀 단위로 | VM이 털려도 GKE·DB·다른 비밀에 닿지 않는다 |
| D-6 | VM `e2-standard-2`, Debian 12, 30GB, Shielded VM, OS Login, 프로젝트 SSH 키 막음. `vm_running = false`면 멈춘다 | 비용 |
| D-7 | 대역 `10.70.0.0/24`. 연결하는 망은 없지만 대역 표(`contracts/aws-outputs.md`)에 올린다 | 나중에 연결할 때 겹치지 않게 |
| D-8 | 이름 `echo-sandbox-*`(`<project>-<env>-<역할>`, env = `sandbox`) | 이름 규칙, 운영 `echo-dev-*`와 구분 |

## 4. 적용 방법 (인프라 담당 리뷰 뒤)

```bash
cd terraform/environments/gcp/ai-sandbox
cp backend.hcl.example backend.hcl            # bucket = gcp/dev 와 같은 state 버킷, prefix = gcp/ai-sandbox
cp terraform.tfvars.example terraform.tfvars  # project_id
terraform init -backend-config=backend.hcl
terraform plan    # 새로 만드는 것만 나와야 한다(바뀜·지움 0)
terraform apply
# 비밀 값은 사람이 넣는다(값은 저장소·state 에 남지 않음)
gcloud secrets versions add echo-sandbox-anthropic-api-key --data-file=-
```

Makefile은 `gcp/dev` 고정이라 위처럼 `-chdir`·직접 실행으로 쓴다(`make plan ROOT=terraform/environments/gcp/ai-sandbox`도 된다).

## 5. 완료 기준

- [ ] `scripts/check.sh` 통과(fmt·validate. tflint는 로컬에 없어 리뷰 환경에서)
- [ ] plan이 새로 만드는 리소스만 보여 준다(기존 리소스 바뀜·지움 0)
- [ ] apply 뒤 VM에 공인 IP가 없고, IAP SSH로만 들어간다
- [ ] VM에서 `echo-dev` 대역(예: `10.60.0.6:8080`)·외부 80 접속이 실패하고, 443(`api.anthropic.com`)은 된다
- [ ] VM SA로 다른 비밀 읽기가 거부된다
- [ ] VM에 Docker가 설치되어 있다(시작 스크립트)

## 6. 적용 후 인수인계

- 김형래: 비밀 3개 값 넣기, 러너 배포, echo-ai-agent `specs/ai-1-sdk-model-sandbox.md` 9절 PoC 1~2단계 기록
- 쓰지 않을 때 `vm_running = false`로 apply해 멈춘다

## 7. 롤백

- `terraform destroy`(이 루트만). API는 끄지 않는다(`disable_on_destroy = false`). 비밀 값도 함께 지워진다

## 8. 추가 — 코드 수정·시험 공간: 서울 리전 모델 + 테스트 DB (11/6, 이도현)

근거: 11/6 AI 에이전트 변경안("샌드박스에서 점검·코드 변경 → 안전 확인 뒤 프로덕션 반영", echo-ai-agent #22)의 echo-infra 몫 "운영과 분리된 테스트 DB". echo-demo-app·echo-demo-db 시험은 표를 비우므로 운영 DB 에 붙으면 안 된다.

| ID | 결정 | 이유 |
|---|---|---|
| D-9 | Cloud SQL PostgreSQL 17 `echo-sandbox-testdb`(Enterprise `db-g1-small`, 존 하나, 백업 없음, 지우기 보호 없음) | 운영 A·B 와 같은 PG 17. 시험 데이터만 둔다 |
| D-10 | 공인 IP 없음, 사설 IP 만(서비스 네트워킹 예약 `10.71.0.0/24`), TLS 만(`ENCRYPTED_ONLY`) | 샌드박스 VPC 에서만 닿는다. 운영 VPC 와는 여전히 연결 없음 |
| D-11 | 방화벽 `echo-sandbox-egress-testdb`(900): VM → `10.71.0.0/24` 5432 만 더 허용 | D-4(443 만)에 DB 하나만 더함 |
| D-12 | 비밀번호는 apply 때 ephemeral 로 만들어 `password_wo`·`secret_data_wo` 로만 넣는다. 접속 문자열은 비밀 `echo-sandbox-test-database-url`(VM SA 만 읽기) | state·저장소·사람 손에 값 0건 |
| D-13 | `vm_running = false` 면 DB 도 멈춘다(`activation_policy = NEVER`) | 비용 |
| D-14 | 모델은 **서울 리전 Vertex AI 의 Claude**(11/6 회의). `aiplatform` API 를 켜고, VM SA 에 `aiplatform.endpoints.predict` 하나만 담은 커스텀 역할 `echoSandboxModelInvoker` | 고객 코드·로그가 서울 밖으로 나가지 않는다. 사전 정의 역할(`aiplatform.user`)은 엔드포인트 만들기까지 들어 있어 쓰지 않는다 |

- 러너: `gcloud secrets versions access latest --secret=echo-sandbox-test-database-url` → 검증 컨테이너에 `TEST_DATABASE_URL` 로 준다. 작업 공간 컨테이너는 네트워크가 없으므로 **DB 시험을 돌리는 검사 컨테이너만** 이 DB 로 나가게 한다(러너 몫, 김형래)
- 비밀번호 바꾸기: `testdb_password_version` 을 올려 apply
- 모델: Model Garden 에서 Claude 사용 동의(콘솔, 사람 1회) 뒤 러너가 `AnthropicVertex(region="asia-northeast3", project_id="team-echo-final")` 로 부른다(키 없이 VM SA). 서울에 없는 모델이면 오류가 나므로 apply 뒤 VM 에서 한 번 호출해 확인한다
- 완료 기준: VM 에서 `psql "$URL" -c 'select 1'` 성공 · VM 밖(로컬)에서 접속 불가 · 다른 비밀 읽기 거부(기존)
