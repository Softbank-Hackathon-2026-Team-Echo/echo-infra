# 고정 진입점 (Envoy) + 측정·관측

고객 앱 주소 `{서비스}.echoport.uk` 는 항상 여기로 온다. 이전 중에도 주소창은 그대로다. Envoy 가 헬스체크와 가중치로 AWS·GCP 두 환경에 트래픽을 나누고, Prometheus·Grafana 가 환경별 요청 수·오류율·지연을 기록한다. 온프레(k3s)는 지금 범위 밖이다(환경을 더하려면 `UPSTREAMS` 에 한 줄).

## 두 메커니즘

| 상황 | 무엇이 움직이나 | 어떻게 |
|---|---|---|
| 계획 이전 (10 → 50 → 100%) | **가중치** | `PUT /weights {"aws": 50, "gcp": 50}` → weights-api 가 `routes.yaml` 을 다시 써서 같은 디렉터리에 rename → Envoy 가 재시작 없이 읽는다 |
| 갑작스런 장애 | **헬스체크 + aggregate 클러스터** | Envoy 가 `/healthz` 를 2초마다 본다. 두 번 실패하면 그 환경을 뺀다. 라우트의 가중치는 `aws_then_gcp`·`gcp_then_aws` 라는 aggregate 클러스터 사이의 비율이라, `aws` 가 전부 죽으면 가중치가 90/10 이어도 전부 `gcp` 로 간다 (로컬 측정: 1초 안) |

```text
클라이언트 ─▶ Envoy :80 ─ weighted_clusters ─┬─ aws_then_gcp (aws 건강하면 aws, 아니면 gcp)
                                             └─ gcp_then_aws (gcp 건강하면 gcp, 아니면 aws)
                                                  aws / gcp: STRICT_DNS + 능동 헬스체크 + outlier detection
```

파일: `config/envoy/envoy.yaml`(리스너·admin, 고정) / `/etc/envoy/dynamic/clusters.yaml`·`routes.yaml`(weights-api 가 생성, 파일 기반 xDS).

## 가중치 바꾸기

```bash
TOKEN=$(gcloud secrets versions access latest --secret=echo-dev-entry-weights-token)   # VM 이 첫 부팅 때 만든 값
URL=http://<entrypoint_ip>:8080                                                       # terraform output entrypoint_weights_url

curl -H "Authorization: Bearer $TOKEN" $URL/weights                     # 현재 {"aws": 100, "gcp": 0}
curl -H "Authorization: Bearer $TOKEN" $URL/status                      # + Envoy 가 본 환경별 healthy 호스트 수
curl -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"aws": 50, "gcp": 50}' $URL/weights                           # 모든 환경 키, 0~100 정수, 합 100
```

echo-was 실행기는 이전 단계마다 이 PUT 을 부른다. 이 API 는 `entrypoint_admin_cidrs` 에서만 열린다.

## 로컬 실행

```bash
cd entrypoint
cp .env.example .env            # 토큰·비밀번호·UPSTREAMS 채우기 (.env 는 커밋하지 않는다)
docker compose up -d --build    # envoy :80 · weights-api :8080 · prometheus :9090 · grafana :3000
curl localhost/__entry/healthz  # 진입점 자체 상태
docker compose down             # -v 를 붙이면 가중치·측정 데이터도 지운다
```

설정만 검사: `docker run --rm -v "$PWD/config/envoy:/cfg:ro" -v <dynamic 디렉터리>:/etc/envoy/dynamic:ro envoyproxy/envoy:v1.39.6 --mode validate -c /cfg/envoy.yaml` (dynamic 파일이 있어야 통과한다. weights-api 가 먼저 뜨는 이유).

## 관측 (Grafana 대시보드 「Echo 고정 진입점」)

| 패널 | 출처 |
|---|---|
| 현재 가중치 | weights-api `/metrics` `entrypoint_weight{env}` |
| 참고용 요약(JSON) | weights-api `GET /summary?window=30s` (Bearer): 환경별 rps·5xx 비율·p95·healthy + 전체 + 가중치. Prometheus 를 읽어 수집 간격(5초)보다 짧은 구간은 비어 있다(`null`) |
| healthy 호스트 수 | Envoy `envoy_cluster_membership_healthy{aws,gcp}` |
| 요청 수 (환경별) | Envoy `envoy_cluster_upstream_rq_total` — aggregate 아래 **실제 환경 클러스터**에도 기록된다 |
| 5xx 비율 (경로별) | Envoy `envoy_cluster_upstream_rq_xx`·`upstream_rq_completed` — 응답 코드는 **경로 클러스터**(`aws_then_gcp`)에만 기록된다(로컬 확인 11/3). 첫 환경이 건강하면 그 환경의 비율이다 |
| 건수 기반 판정(JSON) | weights-api `GET /counters` (Bearer): Envoy 시작 이후 환경별 누적 `requests`·`errors_5xx`·`hosts`. Envoy admin `/clusters` 의 호스트 통계(`rq_total`·`rq_error`) 합이라 Prometheus 수집 간격과 무관하게 즉시 반영된다. 값이 줄면(호스트 교체·재시작) 기준값을 다시 잡는다 |
| p95 지연 | Envoy `envoy_cluster_upstream_rq_time` 히스토그램 — 라우트의 **경로 클러스터**(`aws_then_gcp`)에 기록된다. 첫 환경이 건강하면 그 환경의 지연이다 |
| 진입점 전체 요청·5xx | `envoy_http_downstream_rq_*` |

Prometheus 는 5초마다 긁고 7일 보관. 접근 로그는 JSON 으로 stdout (`docker compose logs envoy`): 요청마다 `upstream_cluster`·`upstream_host`·`duration_ms`·`flags`.

## GCP VM (Terraform)

`terraform/environments/gcp/dev/entrypoint.tf` 가 고정 IP + e2-small(Debian 12) + 방화벽 + 서비스 계정 + Secret Manager 껍데기를 만든다. startup 스크립트가 이 디렉터리의 파일을 `/opt/entrypoint` 에 쓰고 `docker compose up -d --build` 한다.

- 업스트림 주소: 변수 `entrypoint_upstreams = { aws = "<ALB DNS>:80", gcp = "<GKE 인그레스>:80" }`. 바꾸면 `terraform apply` 뒤 VM 에서 `sudo google_metadata_script_runner startup`.
- 토큰·Grafana 비밀번호: VM 이 첫 부팅 때 만들어 `echo-dev-entry-weights-token`·`echo-dev-entry-grafana-admin` 에 넣는다. state·레포에 없다.
- SSH: `gcloud compute ssh echo-dev-entry --tunnel-through-iap` (공개 22 없음).
- Grafana 는 익명 Viewer 허용(3000 은 허용 CIDR 에서만), 편집은 admin.

## Cloudflare 에 붙일 때

- `*.echoport.uk` A 레코드 → `entrypoint_ip`. 프록시(주황 구름)를 켜면 Cloudflare 가 TLS 를 끝내고 **HTTP 80** 으로 온다. Envoy 는 그대로 80 만 받는다. 이때 `envoy.yaml` 의 `xff_num_trusted_hops` 를 1 로 올린다(진짜 클라이언트 IP).
- 헬스체크는 Envoy 가 한다. Cloudflare 쪽 헬스체크·로드밸런싱은 켜지 않는다(두 군데서 전환하면 꼬인다).
- Host 헤더는 그대로 업스트림에 넘어간다(`{서비스}.echoport.uk`). **각 환경의 인그레스가 이 고정 호스트도 받아야 한다**(환경별 주소 `{서비스}-{환경}-{8자}.echoport.uk` 에 더해). 서비스마다 호스트를 바꿔 주는 방식(`host_rewrite_literal`)은 필요해지면 weights-api 에 서비스 표를 더한다.
