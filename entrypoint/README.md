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

## 왜 DNS 가중치가 아니라 프록시인가 (인프라 5 기록)

DNS 가중치(Route 53 weighted, Cloudflare Load Balancing)로도 두 환경에 트래픽을 나눌 수는 있다. 쓰지 않는 이유:

| 요구 | DNS 가중치 | 고정 진입점(Envoy) |
|---|---|---|
| 10 → 50 → 100% 가 **언제** 반영되나 | TTL 뒤에야, 그것도 리졸버·브라우저·OS 캐시가 TTL 을 지킬 때만. 실제 비율을 알 수 없다 | `PUT /weights` 즉시(파일 xDS, 재시작 없음). 로컬 측정 1초 안 |
| 단계 승격 판정 "도착 환경이 N건 처리"(API 서버 8-1) | DNS 는 요청을 세지 못한다 | `/counters` 가 환경별 요청 수·5xx 를 즉시 센다 |
| 장애 때 우회 | 헬스체크 페일오버도 TTL 에 묶인다(수십 초 + 캐시) | 능동 헬스체크 2초×2회 + aggregate 클러스터, 1초 안 |
| 롤백 60초 안(NFR-05) | 보장 못 한다 | 가중치 되돌리기 한 번 |
| 클라이언트 종류 | 모바일·기업 프록시·CDN 의 DNS 캐시를 통제할 수 없다 | 클라이언트는 한 주소만 본다 |
| 벤더 중립(Beyond Lock-in) | Route 53 은 AWS, Cloudflare LB 는 유료·Cloudflare 종속 | Envoy 설정 하나가 어느 클라우드에서도 같다. 온프레도 `UPSTREAMS` 한 줄 |

대가와 대응:

- **프록시가 단일 장애점**이다 → 인프라 5.1(진입점 두 곳 + DNS 페일오버 PoC)에서 다룬다. DNS 는 **프록시 자체의 생존**에만 쓰고 환경 간 비율에는 쓰지 않는다(역할 분리).
- 한 홉이 는다(서울 VM 경유, 도쿄 앱까지 왕복 +수십 ms) → 측정값을 그대로 공개한다(`/summary` p95).
- 트래픽이 VM 한 대를 지난다 → e2-small 로 시연 50 rps 는 충분. 규모가 커지면 관리형 LB(Cloud Load Balancing + NEG) 뒤에 Envoy 를 여러 대 둔다.

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

## 진입점 두 곳 (인프라 5.1 단일 장애점 PoC)

진입점 VM 이 한 대면 그 VM 이 죽을 때 대표 주소 전체가 멈춘다. 대응은 **같은 VM 을 다른 존에 하나 더** 두고, Cloudflare 의 `*.echoport.uk` 에 **프록시된 A 레코드를 두 IP 로** 두는 것이다. Cloudflare 는 한 IP 로 보낸 요청이 실패하면 같은 호스트의 다른 IP 로 다시 시도한다([round-robin DNS](https://developers.cloudflare.com/dns/manage-dns-records/how-to/round-robin-dns/), LB 애드온 없이). DNS 는 프록시 자체의 생존에만 쓰고, 환경 간 비율은 여전히 Envoy 가중치다.

| 무엇 | 주 (`echo-dev-entry`, 존 a) | 보조 (`echo-dev-entry-b`, 존 b) |
|---|---|---|
| Envoy·Prometheus·Grafana | 같음 | 같음 (같은 startup 스크립트) |
| 가중치 | echo-was 가 `PUT /weights` | `SYNC_FROM=http://<주 내부 IP>:8080` 으로 2초마다 `GET /weights` 해 맞춤. 주가 죽으면 마지막 값 유지 |
| 토큰·Grafana 비밀번호 | 첫 부팅 때 만들어 Secret Manager 에 넣음 | Secret Manager 의 기존 값을 읽어 **같은 값** 사용 |
| 판정(`/counters`) | echo-was 가 읽음 | VM 별 통계라 주와 합산되지 않음 (PoC 한계) |

- 만들기: `terraform.tfvars` 에 `entrypoint_secondary_zones = ["b"]` → `make plan CLOUD=gcp` → apply. 출력 `entrypoint_secondary_ips["b"]` 를 Cloudflare 에 두 번째 A 레코드(프록시 켬)로 올린다.
- **보조 IP 를 받는 쪽에도 열어야 한다**: AWS 닻 ALB 의 `inbound-cidrs`(`cluster-addons/eks/anchor-ingress.yaml`)에 보조 IP 를 더하고 `kubectl apply`. 빠뜨리면 보조 VM 에서 aws 헬스체크가 타임아웃돼 gcp 로만 흐른다(11/4 적용 때 확인). GKE 쪽 nginx 는 VPC 안이라 바꿀 것 없다.
- 한계: 주가 죽어 있는 동안 echo-was 는 가중치를 바꾸지 못한다(보조는 마지막 값으로 흐른다). 주 복구 뒤 보조가 자동으로 다시 맞춘다. 규모가 커지면 관리형 LB 뒤 Envoy 여러 대 + 가중치 저장소 분리가 답이다.
- 측정: `HOST=<대표 주소> DURATION=120 entrypoint/scripts/failover-probe.sh` 를 돌리면서 다른 창에서 주 VM 을 멈춘다(`gcloud compute instances stop echo-dev-entry --zone asia-northeast3-a`). 실패 구간(초)·실패 건수가 나온다. 값은 `docs/design-infra.md` 7절에 적는다.
