# 진입점 c 의 GCP 입구를 고객 클러스터로 옮김 — 2026-11-07 23:11~23:14 KST (인프라 16 후속 · 인프라 17)

## 왜

인프라 16 으로 고객 앱이 `echo-dev-customer-gke` 로 옮겨 간 뒤에도 AWS 서울 진입점 c 의 gcp 업스트림 `34.47.94.41:80` 은
관제탑 `echo-dev-gke` 의 Service `ingress-nginx/ingress-nginx-entry-c` 를 거쳐 **옛 앱 `app-7cbfcc686f-cn2n6`** 에 닿고 있었다.
진입점 a·b 는 이미 고객 클러스터 내부 LB `10.63.0.14` 를 쓴다. c 는 AWS 에 있어 GCP 내부 IP 에 닿지 못한다(c 에서 `10.63.0.14` 시간 초과 실측).

## 한 일 (안 A: IP 를 남기고 Service 만 옮김)

c 설정(UPSTREAMS·S3 `settings.env`·aws/dev Terraform)은 **바꾸지 않았다**.

| 시각(KST) | 단계 | 결과 |
|---|---|---|
| 23:07~23:10 | 사전 확인 | echo-demo `demo` 서비스 진행 중 이전 계획 없음, 서비스 가중치 aws 100 / gcp 0, 진입점 a·c `/weights` = `{"aws":100,"gcp":0}`, c 손님 요청 0(접근 로그의 비 healthz 줄은 점검 요청뿐), NLB `echo-dev-entry-lb` a·b HEALTHY. 원래 Service yaml 백업 |
| 23:11:27 | 임시 IP `34.47.94.41` → 정적 주소 `echo-dev-entry-c-gke` 승격 | `IN_USE`, users = 옛 전달 규칙 `a4841dc3…`. 끊김 없음 |
| 23:11:52 | 관제탑 `echo-dev-gke` 의 Service 삭제 | 23:12:25 삭제 완료, 옛 전달 규칙 NotFound, 주소 `RESERVED` |
| 23:12:49 | 고객 클러스터에 `cluster-addons/gke/ingress-nginx-external-entry-c.yaml`(`loadBalancerIP: 34.47.94.41`) apply | 23:13:41 `EnsuredLoadBalancer`, EXTERNAL-IP `34.47.94.41`, 새 전달 규칙 `a1f0406a…`, 방화벽 `k8s-fw-a1f0406a…`(출처 `3.39.160.158/32`, tcp:80, 고객 노드 태그) |
| 23:14:12 | c 에서 확인 | 두 Host(`demo-y6cz3jrc.echoport.uk`, `…gcp-seoul…`) `/healthz` 200, `/api/info` = **`app-78494697d5-vxwjq`(고객 클러스터의 현재 파드)**. Envoy `gcp::34.47.94.41:80` healthy |

## 측정

- **c → 34.47.94.41 (c 안에서 2초 간격, 504회)**: 옛 앱 200 ×34 → `000` ×21 → 새 앱 200 ×449. 마지막 옛 앱 응답 뒤 23:11:56 에 끊김 시작, 23:13:37 에 새 앱 첫 응답 — **c 의 gcp 경로 끊김 약 101초**. Envoy 능동 헬스체크는 23:12:56 `failed_active_hc` → 23:13:46 다시 healthy.
- **대표 주소 `https://demo-y6cz3jrc.echoport.uk/api/info` (M1, 약 3초 간격, 23:10:47~23:29:46)**: 380회 전부 200 · `aws-tokyo`. 손님 경로(Cloudflare → NLB → a → aws)는 이 작업과 무관해 영향이 없었다.
- 끊김 동안 c 의 gcp 가중치는 0 이었고 c 로 온 손님 요청도 없었다. **단 c 의 라우트는 `aws_then_gcp`(aws 실패 시 gcp 로 넘김)라, 이 101초 동안 aws(도쿄 ALB)까지 죽었다면 c 는 갈 곳이 없었다.**

## 자원 수 변화

| 자원 | 전 | 후 |
|---|---|---|
| 전달 규칙(프로젝트 전체) | 9 | 9 (`a4841dc3…` → `a1f0406a…`) |
| target pool | `a4841dc3…`(관제탑 노드 2) | `a1f0406a…`(고객 노드 1) — 1:1 교체 |
| HTTP 헬스체크·방화벽(`k8s-fw-…`·`-deny`·`-http-hc`) | `a4841dc3…` 3개 | `a1f0406a…` 3개 — 1:1 교체 |
| 정적 주소(asia-northeast3) | 5 | **6** (`echo-dev-entry-c-gke` — 같은 IP 를 임시에서 정적으로 바꾼 것. 새 IP 는 없음) |

비용: 전달 규칙·LB 수는 그대로다. 사용 중인 정적 주소의 시간당 요금은 공개 단가 기준 임시 IP 와 같은 수준으로 보이나 **가격 카탈로그로 확인하지 못했다(미검증)**. Service 를 지우고 주소만 남기면 미사용 정적 IP 요금이 붙는다.

## 되돌리기 (이번에는 쓰지 않음)

1. `kubectl --context <고객> delete -f cluster-addons/gke/ingress-nginx-external-entry-c.yaml` → 주소가 `RESERVED` 로 돌아온다.
2. 같은 파일을 관제탑 `echo-dev-gke` 컨텍스트로 apply → 같은 IP 로 옛 앱 경로 복원.
3. 정적 주소는 지우지 않는다(지우면 IP 가 사라져 c 의 UPSTREAMS 를 바꿔야 한다).

## 검증 범위 (어디까지 확인했나)

- 확인함: c → 34.47.94.41 → 고객 클러스터 ingress-nginx → 새 앱의 **HTTP GET**(`/healthz`·`/api/info`) 실제 도착, 대표 주소 GET 무실패, 가중치·진행 계획 불변.
- 확인 안 함: c 를 통한 **쓰기(POST) 전환**, c 로의 **Cloudflare 장애 조치(풀 aws-c)** 실제 동작, 고객 앱 DB 쓰기 담당(쓰기는 지금도 A). 이번 일은 c 의 gcp 업스트림 대상 교정이지 c 경유 장애 대피 완료가 아니다.
- 관제탑의 옛 앱 `app-7cbfcc686f-cn2n6` 과 관제탑 ingress-nginx 는 그대로 있다(정리는 범위 밖).
