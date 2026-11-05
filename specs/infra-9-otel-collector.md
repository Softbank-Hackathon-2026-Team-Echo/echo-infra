# 인프라·이전 엔진 9: 세 환경 OTel 수집기 + 진입점 remote write 수신

- 상태: 구현 (로컬 시험 통과, **운영 적용 전 — 서동옥 님 리뷰 뒤 적용**)
- 확인일: 2026-11-05
- GitHub 이슈: echo-infra #9 (담당 서동옥, 구현 인수 댓글 11/5 "적용 전 리뷰")
- 짝 PR: echo-demo-app `feat/metrics-endpoint` (앱 `/metrics`, SPEC `echo-demo-app/specs/infra-9-metrics.md`)
- 저장소: `echo-infra` · 브랜치 `feat/otel-collector`
- 작성: 김지민 (지민 결정 11/5 17:00 "로컬에서 최대한 잘 테스트해보고 올려")

## 1. 목표

완료 기준 "모든 환경이 같은 OTel 수집기로 요청 수·오류율·지연을 보낸다"(킥오프 가이드 11절: 수집기를 각 클러스터에, 공통 속성으로 세 환경을 한 그래프에). 클러스터마다 OTel Collector 하나가 앱 `/metrics` 를 긁어 `cloud.provider`·`cloud.region`·`k8s.cluster.name` 을 붙이고 진입점 Prometheus 로 remote write 한다. Grafana 「Echo 고정 진입점」에 `cloud_provider` 별 행 하나를 더한다.

## 2. 확인된 사실 (11/5, 읽기 전용)

| 사실 | 근거 |
|---|---|
| 시연 앱(`demo-*/app`, echo/app digest 877f0b…)에 `/metrics` 없음(온프레 404) | SSM `curl` |
| 실행기가 만든 앱 파드 라벨 `app.kubernetes.io/managed-by=echo-was`, `app.kubernetes.io/name=app`, 포트 이름 `http`(8080) | GKE `kubectl get pods` |
| 진입점 VM a(`echo-dev-entry` 10.60.0.6 / 34.158.202.103)·b(`echo-dev-entry-b` 10.60.0.9 / 8.230.16.205) 모두 Prometheus v3.15.1, `web.enable-remote-write-receiver=false`, `web.config.file` 없음. **Prometheus·Grafana 가 VM마다 따로** | `/api/v1/status/flags`, `gcloud compute instances list` |
| 9090 방화벽: `echo-dev-entry-admin` = EKS NAT 18.180.171.76/32 · GKE NAT 34.64.211.218/32. `echo-dev-internal` 이 GKE 파드 대역 10.61.0.0/16 → VM 내부 IP 허용. 온프레 EC2 공인 IP 3.36.77.175 는 없음 | `gcloud compute firewall-rules list` |
| weights-api `/summary` 와 Grafana 데이터소스가 `http://prometheus:9090` 을 **인증 없이** 읽는다 | `entrypoint/weights-api/app.py`, `datasources/prometheus.yml` |
| Prometheus basic auth(`--web.config.file`)는 쿼리·UI 를 포함한 **모든 경로**에 걸린다(경로별로 나눌 수 없다) | Prometheus 문서, 로컬 확인 |
| Prometheus 불리언 플래그는 `--flag=false` 를 받지 않는다(`unexpected true` 로 기동 실패) → `--[no-]flag` 형태 | 로컬 확인 |
| 온프레 t3.small 가용 메모리 약 674MB, 들어오는 포트 0(SG 인바운드 0) | SSM |
| GKE 는 관리형 Prometheus(GMP)가 켜져 있다 — 이번 작업은 건드리지 않는다 | GKE describe |

## 3. 범위

### 포함
- `cluster-addons/otel-collector/base`: Namespace `echo-otel` · SA · ClusterRole(pods get/list/watch) · Deployment 1(`otel/opentelemetry-collector-contrib:0.164.0`, Recreate) · ConfigMap(설정·환경값, 내용 해시 이름)
- `overlays/{aws,gcp,onprem}`: 세 속성 + 진입점 a·b 주소. 온프레는 메모리 제한 128Mi
- `local-test/`: Docker 만으로 k3s + 진입점 흉내 Prometheus 두 대를 띄워 끝까지 확인하는 스크립트
- 진입점: Prometheus remote write 수신 + basic auth 를 **Terraform 스위치**(`entrypoint_prometheus_remote_write`, 기본 false)로. weights-api·Grafana 가 같은 계정으로 읽게(인증이 꺼진 Prometheus 는 헤더를 무시하므로 스위치와 무관하게 동작). 9090 만 여는 방화벽 변수(`entrypoint_remote_write_cidrs`). Secret Manager 껍데기 `echo-dev-entry-prometheus-remote-write`
- Grafana 「Echo 고정 진입점」에 행 1개(요청 수·오류율·p95, `cloud_provider` 별)

### 제외
- 운영 적용(GKE·EKS·온프레·진입점) — 절차서 `~/archive/softbank-hackathon-2026/otel/apply-runbook.md` 대로 리뷰 뒤
- 운영 앱 이미지 교체(`/metrics` 가 든 이미지로) — echo-demo-app PR 병합 뒤 echo-was 배포 흐름 또는 절차서
- 진입점 업스트림에 온프레 추가(인프라 13), 이전 판정 기준 변경(계속 Envoy `/counters`), GMP·트레이스·로그
- TLS(9090 은 평문 HTTP. basic auth 비밀번호가 NAT~진입점 구간에 평문으로 지난다 — 시연 기간 한정, 동옥 판단 항목)

## 4. 설계

```text
앱 파드 /metrics ─(prometheus receiver, k8s SD role=pod, 15초)─▶ [echo-otel/otel-collector]
   keep: 라벨 managed-by=echo-was 또는 annotation echo.dev/scrape=true · 포트 이름 http · Running
   metric keep: http_requests_total, http_request_duration_seconds_{bucket,sum,count}
   memory_limiter → resource(cloud.provider/region, k8s.cluster.name upsert) → batch
   ─▶ prometheusremotewrite/entry-a ─▶ 진입점 a :9090/api/v1/write  (basic auth echo-otel)
   ─▶ prometheusremotewrite/entry-b ─▶ 진입점 b :9090/api/v1/write
      resource_to_telemetry_conversion=on → 시계열 라벨 cloud_provider·cloud_region·k8s_cluster_name
```

| 환경 | cloud.provider | cloud.region | k8s.cluster.name | 진입점 주소 | 경로 |
|---|---|---|---|---|---|
| EKS | aws | ap-northeast-1 | echo-dev-eks | 34.158.202.103 / 8.230.16.205 | NAT 18.180.171.76 → admin 방화벽(이미 열림) |
| GKE | gcp | asia-northeast3 | echo-dev-gke | 10.60.0.6 / 10.60.0.9 | VPC 내부(echo-dev-internal) |
| 온프레 | onprem | ap-northeast-2 | echo-onprem-demo | 34.158.202.103 / 8.230.16.205 | EC2 공인 IP → **새 방화벽 `echo-dev-entry-remote-write`(9090 만)** |

| 결정 | 내용 | 출처 |
|---|---|---|
| D-1 | A안: 앱 `/metrics` → 클러스터 수집기(prometheus receiver) → 진입점 Prometheus remote write | `otel/plan.md`, 지민 |
| AD-1 | 진입점 a·b **둘 다** 쓴다(VM마다 Prometheus·Grafana 가 따로라 a 만 쓰면 b 의 Grafana 가 빈다). a 만으로 정하면 overlay 에서 exporter 하나를 뺀다 | AI-default, 동옥 확인 항목 |
| AD-2 | 인증 = Prometheus basic auth 하나(사용자 `echo-otel`). 비밀번호 원문은 VM 이 처음 켤 때 만들어 Secret Manager 에 넣고(기존 토큰과 같은 방식, b 는 a 의 값을 읽음), 설정 파일에는 bcrypt(`htpasswd -B -C 10`) 해시만. 저장소에는 원문·해시 모두 없다 | AI-default |
| AD-3 | basic auth 가 모든 경로에 걸리므로 weights-api(`PROMETHEUS_BASIC_AUTH`)·Grafana(데이터소스 `basicAuth`)도 같은 계정으로 읽는다. 읽기 전용 계정 분리는 Prometheus 가 지원하지 않아 하지 않는다 | AI-default |
| AD-4 | 진입점 변경은 Terraform 스위치 기본 false. false 면 Prometheus 플래그만 `--no-web.enable-remote-write-receiver` + 빈 web 설정(인증 없음)으로 지금과 같다. 단 **파일이 바뀌므로 startup 재실행 때 weights-api·Prometheus·Grafana 컨테이너는 다시 만들어진다**(Envoy 는 그대로, 로컬 확인) | AI-default |
| AD-5 | 수집 대상은 실행기 라벨로 고른다(네임스페이스 이름 `demo-*` 에 기대지 않음). 손으로 둔 앱은 annotation `echo.dev/scrape: "true"` 로 넣을 수 있다 | AI-default |
| AD-6 | Deployment `Recreate`(두 파드가 겹쳐 같은 시계열을 두 번 보내지 않게). ConfigMap 은 내용 해시 이름 → 설정이 바뀌면 파드가 바뀐다 | AI-default |
| AD-7 | 온프레: 메모리 제한 128Mi, memory_limiter 100MiB(spike 25), GOMEMLIMIT 90MiB. 나머지 50m/64Mi 요청·256Mi 제한 | AI-default |
| AD-8 | `cloud.provider=onprem` 은 OTel 표준 값이 아니다(시연에서 온프레로 간주). 실체 위치는 `cloud.region=ap-northeast-2` 로 남긴다 | AI-default |
| AD-9 | 대시보드 행은 헬스체크·`/metrics` 경로를 뺀다(`path!~"/healthz|/readyz|/metrics"`). 출처가 진입점 Envoy 와 다르다는 설명을 패널 설명에 적는다. 이전 판정은 계속 Envoy `/counters` | AI-default |

## 5. 완료 기준 (이 PR)

1. `kubectl kustomize overlays/{aws,gcp,onprem}` 세 개 모두 성공, 수집기 설정 `otelcol validate` 성공.
2. 로컬 k3s(v1.36.5+k3s1)에서 앱 이미지(echo-demo-app `feat/metrics-endpoint`) + 수집기(온프레 overlay 기반, 128Mi) → 진입점 흉내 Prometheus 두 대(remote write 수신 + 같은 web.yml basic auth)에서 `http_requests_total{cloud_provider="local"}` 이 조회되고, 라벨 없는 파드는 수집되지 않는다. 대시보드 세 식이 값을 낸다.
3. 진입점 compose 로컬(옛 main → 새 파일 → 스위치 켬 → 끔): 플래그·인증(401/200)·remote write 수신·weights-api `/summary`·Grafana 데이터소스가 각 단계에서 맞고, Envoy 컨테이너는 다시 만들어지지 않는다.
4. `scripts/check.sh`(fmt·validate·tflint) 통과, startup 템플릿을 실제 `templatefile` 로 그린 스크립트가 `bash -n` 통과 + 새 구간(3-b·4) 실행 시험(VM a·재실행·VM b·끔).

운영 완료 기준(세 환경 실제 수집)은 절차서 적용 뒤 이슈에서 확인한다.
