# otel-collector — 세 환경 OTel 수집기 (인프라 9)

클러스터마다 OTel Collector 하나가 Echo 가 배포한 앱의 `/metrics` 를 15초마다 긁어 `cloud.provider`·`cloud.region`·`k8s.cluster.name` 을 붙이고, 진입점 VM a·b 의 Prometheus 로 remote write 한다. Grafana 「Echo 고정 진입점」의 「세 환경 한 그래프」 행이 `cloud_provider` 별로 요청 수·오류율·p95 를 그린다. 범위·결정은 [SPEC](../../specs/infra-9-otel-collector.md).

```text
앱 파드 /metrics ─▶ echo-otel/otel-collector ─(basic auth)─▶ 진입점 a·b Prometheus :9090/api/v1/write ─▶ Grafana
```

| 파일 | 내용 |
|---|---|
| `base/collector.yaml` | 수집기 설정: prometheus receiver(k8s SD role=pod, 라벨 `app.kubernetes.io/managed-by=echo-was` 또는 annotation `echo.dev/scrape=true`, 포트 이름 `http`) → memory_limiter → resource → batch → remote write 두 곳 |
| `base/resources.yaml` | Namespace `echo-otel` · SA · ClusterRole(pods 읽기) · Deployment 1 |
| `base/kustomization.yaml` | ConfigMap 생성(내용 해시 이름 → 설정이 바뀌면 파드가 바뀐다), 환경값 기본은 쓸 수 없는 값 |
| `overlays/aws` · `gcp` · `onprem` | 세 속성 + 진입점 주소. 온프레는 메모리 제한 128Mi |
| `local-test/` | Docker 만으로 k3s + 진입점 흉내 Prometheus 두 대를 띄워 끝까지 확인 |

## 적용 (리뷰 뒤, 사람이)

진입점에서 remote write 수신을 먼저 켠다(`terraform/environments/gcp/dev` `entrypoint_prometheus_remote_write = true` → apply → VM 마다 `sudo google_metadata_script_runner startup`). 그다음 클러스터마다:

```bash
# Secret: 진입점 basic auth (값은 Secret Manager, 끝 줄바꿈을 지운다 — 줄바꿈이 비밀번호에 섞이면 401)
kubectl create namespace echo-otel --dry-run=client -o yaml | kubectl apply -f -
gcloud secrets versions access latest --secret=echo-dev-entry-prometheus-remote-write --project team-echo-final \
  | tr -d '\n' | kubectl -n echo-otel create secret generic otel-remote-write \
      --from-literal=username=echo-otel --from-file=password=/dev/stdin
kubectl apply -k cluster-addons/otel-collector/overlays/<aws|gcp|onprem>
kubectl -n echo-otel rollout status deploy/otel-collector
kubectl -n echo-otel logs deploy/otel-collector | grep -iE 'error|401' || echo "오류 없음"
```

온프레(k3s)는 EC2 안에서 `sudo k3s kubectl …`. 온프레 공인 IP 를 `entrypoint_remote_write_cidrs` 에 넣어야 9090 에 닿는다. 단계별 확인·되돌리기는 적용 절차서(`otel/apply-runbook.md`, 저장소 밖)를 따른다.

되돌리기: `kubectl delete -k cluster-addons/otel-collector/overlays/<환경>` (앱·진입점에 영향 없음. 이미 보낸 시계열은 진입점 7일 보존 뒤 사라진다).

## 로컬 시험

```bash
# echo-demo-app (feat/metrics-endpoint) 에서: docker build -t echo-demo-app:local .
bash cluster-addons/otel-collector/local-test/run.sh up echo-demo-app:local
sleep 90
bash cluster-addons/otel-collector/local-test/run.sh check   # http_requests_total{cloud_provider="local"} · 패널 식 · 수집기 메모리
bash cluster-addons/otel-collector/local-test/run.sh down
```

## 주의

- 앱 이미지에 `/metrics` 가 없으면(11/5 운영 이미지) 수집기는 `up=0` 만 보내고 앱 지표는 비어 있다. 앱을 새 이미지로 바꾼 뒤에 그래프가 찬다.
- 수집기 숫자는 진입점 Envoy 숫자와 다르다(헬스체크 제외, 진입점을 거치지 않은 클러스터 안 요청 포함). 이전 판정은 계속 Envoy(`/counters`).
- GKE 관리형 Prometheus(GMP)와 무관하다(PodMonitoring 을 만들지 않는다).
