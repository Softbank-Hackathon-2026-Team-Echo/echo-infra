# Echo 이전 엔진·인프라 (echo-infra)

Team Echo 멀티 클라우드 관리 플랫폼의 **실행 평면**이다. echo-was(관리 평면 API)가 "무엇을 어디에 몇 %로" 기록하면, echo-infra가 실제 클러스터를 만들고 배포하고 트래픽을 옮기고 되돌린다. 클라우드와 온프레를 **실제로 만지는** 조각이다.

> **상태: 초안.** 아직 코드가 없다. README 한 줄과 이 문서뿐이다.
> 아래 구조·원칙·규칙 문서는 모두 **제안**이고, 팀과 교정하며 확정한다. 확정 안 된 것은 맨 아래 [§ 교정할 것](#교정할-것-팀과-정한다)에 모았다.

- **범위**: 클러스터 프로비저닝(Terraform), GitOps 배포(Argo CD), 이전 엔진(트래픽 전환·데이터 동기화·롤백)
- **대상 환경**: AWS EKS · GCP GKE · 온프레 k3s
- **짝 저장소**: [echo-was](../echo-was) 관리 평면 API, [echo-ai-agent](../echo-ai-agent) 검증 게이트, [echo-secure](../echo-secure) 보안·거버넌스, [echo-frontend](../echo-frontend) 대시보드

---

## 시스템 내 위치

```text
[echo-frontend] ──HTTP──▶ [echo-was: 관리 평면 API] ──▶ PostgreSQL (환경·서비스·배포 기록)
                                  │
                                  │ 어댑터 계약 (지금 echo-was 쪽은 가짜/simulated)
                                  ▼
                        ┌───────────────────────────────────────────────┐
                        │  echo-infra: 실행 평면                          │
                        │                                                │
                        │  프로비저닝(Terraform) ─▶ EKS · GKE · 온프레 k3s │
                        │  GitOps(Argo CD)       ─▶ 매니페스트 배포         │
                        │  이전 엔진             ─▶ Envoy 트래픽 전환        │
                        │                           데이터 동기화 · 롤백     │
                        └───────────────────────────────────────────────┘
```

echo-was는 기록의 주인이고, echo-infra는 그 기록을 **집행**한다.
echo-was가 "shop-api를 aws-seoul에 10%, gcp-tokyo에 90%로" 라고 적으면, 실제로 그 비율을 프록시에 먹이는 것은 echo-infra다.

---

## 범위 (맡는 것 / 안 맡는 것)

**맡는 것**

- **프로비저닝.** Terraform으로 EKS·GKE·온프레 k3s 클러스터와 네트워크를 만든다.
- **배포.** Argo CD로 서비스 매니페스트를 각 환경에 올린다.
- **이전 엔진.** L7 프록시(Envoy) 가중치로 트래픽을 옮기고, 데이터를 동기화하고, 실패하면 되돌린다.
- **집행.** echo-was가 선언한 상태(배포·트래픽 비율)를 실제 클러스터에 반영하고 결과를 돌려준다.

**안 맡는 것 (= echo-was)**

- 환경·서비스·배포 **기록의 주인**. echo-infra는 기록을 만들지 않고 받아서 집행한다.
- API·인증·권한. 사람은 echo-was/프론트로만 조작한다.

**경계 (echo-was와 함께 정한다)**

- echo-was의 `app/adapters/<kind>.py` 동작 클래스는 지금 **가짜(simulated)**다(네트워크 호출 없이 고정 값 반환).
- echo-infra는 이 가짜를 실제 클러스터 조작으로 바꾸는 쪽이다.
- 그래서 **어댑터 계약**(현재 `check_connection`·`read_cluster_info`, 앞으로 배포·트래픽·롤백 메서드)은 echo-was와 **공동으로** 정한다. 한쪽이 임의로 바꾸지 않는다.

---

## 공유 규칙 (반드시 따른다)

echo-infra는 echo-was와 같은 도메인을 다룬다. 용어와 계약은 echo-was를 단일 출처로 따른다.

| 무엇 | 어디 | 쓸 때 |
|---|---|---|
| 도메인 용어·식별자 | [echo-was `.claude/rules/term-dictionary.md`](../echo-was/.claude/rules/term-dictionary.md) | Environment·Service·Deployment·traffic_weight·rollback·image_ref·secret_ref 의 뜻과 표기를 정할 때. **표준 용어의 단일 출처** |
| 본선 원장 | `final_features_v6.md`(F1~F17, NFR) | 인프라 작업도 이 기능 번호에 묶는다. (원장 원본은 echo-was 파트가 관리) |
| 공통 모델 | [echo-was `docs/schema.md`](../echo-was/docs/schema.md) | 환경·서비스·배포·연결의 관계를 참조할 때 |

### 어기면 교차 저장소가 깨지는 계약

* **트래픽 합계 100%는 이전 엔진이 맞춘다.** DB의 `traffic_weight`는 "마지막으로 프록시에 적용한 값"일 뿐이다. 합을 100으로 유지하는 책임은 **여기(echo-infra)**에 있다.
* **되돌리기는 새 배포다.** 기존 배포 행을 고치거나 지우지 않는다. 예전 이미지·설정을 복사해 **새 배포 행**으로 올린다(원본은 `rollback_of_id`로 가리킨다).
* **이미지는 digest로 배포한다.** `image_ref = image_repository@image_digest`. `latest` 같은 바뀌는 tag로 배포하지 않는다.
* **비밀값은 state·manifest·로그에 넣지 않는다.** Terraform state, Argo CD manifest, 로그 어디에도 비밀값을 평문으로 두지 않는다. 보관 위치(`secret_ref`)만 다룬다.
* **환경 이름은 RFC 1123 label**(소문자·숫자·하이픈 1~63자)이다. 클러스터 리소스 이름으로 그대로 쓰기 때문이다.

---

## 제안 구조 (초안)

아직 파일이 없다. 아래는 **제안**이다. 실제 배치는 첫 작업에서 확정한다.

```text
terraform/
├─ modules/
│   ├─ eks/            # AWS EKS 클러스터 + 노드
│   ├─ gke/            # GCP GKE 클러스터 + 노드
│   ├─ k3s/            # 온프레 k3s
│   ├─ network/        # VPC·서브넷·방화벽 (환경별 차이를 여기 가둔다)
│   └─ proxy/          # L7 프록시(Envoy) 및 고정 도메인 입구
├─ envs/
│   ├─ aws/            # 환경별 변수·backend 설정
│   ├─ gcp/
│   └─ onprem/
gitops/
├─ argocd/            # Argo CD Application 정의
└─ apps/              # 서비스별 매니페스트(또는 Helm/Kustomize)
engine/              # 이전 엔진 (트래픽 전환·데이터 동기화·롤백 집행)
scripts/             # 반복 작업 스크립트
docs/                # 설계 문서·런북
```

* **환경별 차이는 module 안에 가둔다.** 바깥에서 보면 aws·gcp·onprem이 같은 인터페이스로 보이게 한다. echo-was의 "새 환경 종류 = 파일 하나" 원칙과 짝이다.
* `engine/`의 언어·형태(echo-was 안의 Worker로 둘지, 독립 서비스로 둘지)는 아직 안 정했다([§ 교정할 것](#교정할-것-팀과-정한다)).

---

## 핵심 원칙 (초안)

코드와 인프라를 쓰기 전 지킨다. 자주 어기는 것만 추린다.

### IaC
* **모든 인프라는 코드다.** 콘솔에서 손으로 바꾸지 않는다. `terraform plan`에 안 잡히는 변경은 없어야 한다.
* **멱등성.** 같은 입력이면 같은 결과다. `apply`를 두 번 돌려도 안전해야 한다.
* **원격 state + 잠금.** state는 로컬에 두지 않는다. 동시 apply를 막는 잠금을 건다. state에 비밀값이 들어가면 암호화한다.

### 이전·무중단
* **전환 전에 건강을 먼저 확인한다.** 대상이 헬스체크를 통과하기 전에는 트래픽을 한 방울도 보내지 않는다.
* **전략은 둘.** 점진 전환(canary)은 Envoy 가중치를 조금씩 올린다. 통째 전환(blue-green)은 새 환경을 띄워 두고 한 번에 넘긴다. 어느 쪽을 쓸지는 서비스 구조(상태를 쪼갤 수 있는지)로 고른다.
* **집행이지 선언이 아니다.** "옮겨라"를 받는 것만으로 끝이 아니다. 각 단계가 실제로 통과됐는지 확인하고 넘어간다. 실패하면 원 환경으로 되돌린다.
* **되돌릴 수 있는 지점을 남기고 간다.** 원 환경은 전환이 끝날 때까지 살려 둔다.

### 보안
* 비밀값은 외부 저장소(AWS Secrets Manager·GCP Secret Manager 등)에 두고 런타임에만 주입한다. state·manifest·로그·env 파일에 평문으로 두지 않는다.
* 클러스터 접근 자격은 최소 권한으로 발급한다.

---

## 도구 (초안)

* **IaC**: Terraform(또는 OpenTofu — [§ 교정할 것](#교정할-것-팀과-정한다)). 버전·provider를 고정한다.
* **GitOps**: Argo CD. 매니페스트는 Helm 또는 Kustomize.
* **클러스터**: `kubectl`, `helm`, 온프레는 `k3s`.
* **클라우드 CLI**: `aws`, `gcloud`.
* **프록시**: Envoy(트래픽 가중치 적용 지점).

버전은 모두 고정한다. 데모 환경에서 재현이 안 되면 심사에서 치명적이다.

---

## 교정할 것 (팀과 정한다)

이 문서는 초안이다. 아래는 아직 안 정했고, 정하는 대로 위 본문에 반영한다.

* **Terraform vs OpenTofu.** 라이선스·팀 경험으로 하나 고른다.
* **state backend 위치.** S3+DynamoDB? GCS? 온프레? 데모에서 어디에 둘지.
* **이전 엔진의 위치.** echo-was 안의 Worker로 둘지(echo-was CLAUDE.md "Worker 진입점은 API 서버 3에서 정한다"와 맞물림), echo-infra의 독립 서비스로 둘지.
* **어댑터 계약.** 배포·트래픽·롤백 메서드 시그니처를 echo-was와 공동 정의한다. 지금은 `check_connection`·`read_cluster_info`만 있다.
* **데이터 동기화 범위.** DB 복제 전략(warm standby / hot ready). 정합성을 어디까지 보장할지. (1101 회의 서동옥 제안)
* **재난복구(DR) 시나리오.** 지진·랜섬웨어 감지 시 자동 이전. 데모는 크롤러 대신 버튼으로 재난을 시뮬레이션하고 대시보드에 알림. (1101 회의)
* **데모 대상 환경 2개.** 첫 구현은 AWS·GCP만으로 충분하다는 의견. 온프레(k3s)를 어디까지 넣을지.
* **규칙 문서.** echo-was처럼 `.claude/rules/`에 IaC 규칙·GitOps 규칙·git 규칙을 둘지. 두면 이 표에 링크를 채운다.
