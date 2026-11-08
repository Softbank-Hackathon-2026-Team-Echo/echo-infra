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

| 세 환경 한 그래프 (인프라 9) | 클러스터 OTel 수집기가 remote write 로 보낸 앱 지표 `http_requests_total`·`http_request_duration_seconds` 를 `cloud_provider` 별로(요청 수·5xx 비율·p95). 헬스체크 경로는 뺀다. Envoy 숫자와 출처가 다르다 — [cluster-addons/otel-collector](../cluster-addons/otel-collector/README.md) |

Prometheus 는 5초마다 긁고 7일 보관. 접근 로그는 JSON 으로 stdout (`docker compose logs envoy`): 요청마다 `upstream_cluster`·`upstream_host`·`duration_ms`·`flags`.

## 요청 기록 (인프라 12.4, 기본 꺼짐)

도쿄 원본이 응답 없이 죽으면 서울로 아직 복제되지 않은 쓰기를 잃는다. 진입점이 쓰기 요청을 최근 15분만 기록해 두었다가, 서울 승격 직후 다시 보낸다(`replication/k8s/scripts/promote-with-replay.sh`, [SPEC](../specs/infra-12.4-request-journal.md)).

```text
클라이언트 ─▶ Envoy ─ ext_authz ─▶ journal(:8081, 도커 네트워크 안) — 쓰기만 SQLite 에 기록 → 허용 / hold 면 429
                    └ router ───▶ 업스트림(지금과 같음)
운영자·스크립트 ─▶ journal 관리(:8082, 토큰) — /status · /hold · /release · /entries
```

- 켜기(둘 다 필요): `.env` 에 `JOURNAL_ENABLED=true`·`JOURNAL_TOKEN` → `docker compose up -d journal`, Envoy 런타임 `curl -X POST '127.0.0.1:9901/runtime_modify?journal.enabled=100'`(Envoy 재시작하면 다시 0)
- 끄기: `runtime_modify?journal.enabled=0` — 기록·hold 모두 멈추고 지금과 같아진다
- VM: `entrypoint_journal_enabled = true`(주 진입점만, 보조는 늘 꺼짐) → apply → `sudo google_metadata_script_runner startup`. 관리 토큰은 시작 스크립트가 만들어 Secret Manager `echo-dev-entry-journal-token` 에 둔다
- 관리 API(:8082)는 방화벽으로 열지 않는다. IAP SSH 터널로 쓴다:
  `gcloud compute ssh echo-dev-entry --zone <zone> --tunnel-through-iap -- -N -L 8082:127.0.0.1:8082 -L 9901:127.0.0.1:9901` → `JOURNAL_URL=http://127.0.0.1:8082`
- journal 이 죽거나 느리면(0.5초) 쓰기는 통과한다(`failure_mode_allow`). 그동안의 쓰기는 기록되지 않는다
- 확인 포트 8081 은 밖에 열지 않는다: 열면 누구나 가짜 쓰기를 기록에 넣고 재생 때 서울 DB 에 들어간다
- 시험: `python -m unittest entrypoint/journal/test_app.py` · `entrypoint/journal/tests/envoy-test.sh`

## GCP VM (Terraform)

`terraform/environments/gcp/dev/entrypoint.tf` 가 고정 IP + e2-small(Debian 12) + 방화벽 + 서비스 계정 + Secret Manager 껍데기를 만든다. startup 스크립트가 이 디렉터리의 파일을 `/opt/entrypoint` 에 쓰고 `docker compose up -d --build` 한다.

- 업스트림 주소: 변수 `entrypoint_upstreams = { aws = "<ALB DNS>:80", gcp = "<GKE 인그레스>:80" }`. 바꾸면 `terraform apply` 뒤 VM 에서 `sudo google_metadata_script_runner startup`.
- 토큰·Grafana 비밀번호: VM 이 첫 부팅 때 만들어 `echo-dev-entry-weights-token`·`echo-dev-entry-grafana-admin` 에 넣는다. state·레포에 없다.
- SSH: `gcloud compute ssh echo-dev-entry --tunnel-through-iap` (공개 22 없음).
- Grafana 는 익명 Viewer 허용(3000 은 허용 CIDR 에서만), 편집은 admin.

## remote write 수신 (인프라 9 OTel 수집기)

클러스터 OTel 수집기가 `:9090/api/v1/write` 로 보낸다. Terraform 스위치 `entrypoint_prometheus_remote_write`(기본 `false` = 지금과 같음)로 켠다.

| 스위치 | Prometheus | 읽는 쪽 |
|---|---|---|
| `false` | `--no-web.enable-remote-write-receiver`, web 설정 `config/prometheus-web-off.yml`(인증 없음) | weights-api·Grafana 가 인증 없이 읽는다 |
| `true` | `--web.enable-remote-write-receiver` + `--web.config.file`(basic auth 사용자 `echo-otel`). **쿼리·UI 도 인증이 필요하다** | weights-api(`PROMETHEUS_BASIC_AUTH`)·Grafana(데이터소스 `basicAuth`)가 같은 계정으로 읽는다 |

- 비밀번호: VM 이 처음 켤 때 만들어 Secret Manager `echo-dev-entry-prometheus-remote-write` 에 넣는다(보조 b 는 그 값을 읽는다 → a 를 먼저 돌린다). `/opt/entrypoint/prometheus-web.yml` 에는 bcrypt 해시만(`scripts/render-prometheus-web.sh`). 저장소에는 원문·해시 모두 없다.
- 방화벽: EKS·GKE NAT 는 `entrypoint_admin_cidrs` 로 이미 9090 이 열려 있다. 그 밖(온프레 EC2 공인 IP)은 `entrypoint_remote_write_cidrs` 에 넣으면 9090 만 연다.
- 바꾼 뒤 `sudo google_metadata_script_runner startup` 을 돌리면 **weights-api·Prometheus·Grafana 컨테이너가 다시 만들어진다**(로컬 측정: Prometheus 약 9초 수집·조회 공백, `/summary` 는 그동안 `prometheus: unreachable`). Envoy 는 다시 만들어지지 않는다(트래픽 끊김 0, 로컬 측정). 9090 은 평문 HTTP 라 비밀번호가 NAT~진입점 구간에 평문으로 지난다(시연 기간 한정).
- 로컬: `.env.example` 의 인프라 9 주석대로 `printf '%s' "$PW" | bash scripts/render-prometheus-web.sh ./prometheus-web.yml` 뒤 `.env` 에 네 줄.

## Cloudflare 에 붙일 때

- `*.echoport.uk` A 레코드 → `entrypoint_ip`. 프록시(주황 구름)를 켜면 Cloudflare 가 TLS 를 끝내고 **HTTP 80** 으로 온다. Envoy 는 그대로 80 만 받는다. 이때 `envoy.yaml` 의 `xff_num_trusted_hops` 를 1 로 올린다(진짜 클라이언트 IP).
- **환경 간(aws/gcp)** 헬스체크·전환은 Envoy 가 한다. Cloudflare 로 환경 비율을 나누지 않는다(두 군데서 전환하면 꼬인다). 인프라 17 의 Cloudflare Load Balancer 는 **어느 진입점이 받나**(GCP NLB ↔ AWS c)에만 쓴다 — 아래 「진입점 c」 절.
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

## 앞단 헬스체크 NLB (인프라 5.3, 11/6)

진입점 두 곳을 Cloudflare A 레코드 두 개로만 묶으면 헬스체크가 없어, 한 대가 죽어도 요청 일부가 계속 그쪽으로 간다(11/6 측정: b 정지 75초 동안 126건 중 15건 실패, `docs/rehearsals/2026-11-06-entry-failover.md`).
그래서 진입점 앞에 **리전 외부 패스스루 NLB** 를 둔다(`entrypoint_lb_enabled = true`).

| 무엇 | 값 |
|---|---|
| 헬스체크 | `GET /__entry/healthz` :80, 2초 간격, 2회 실패면 제외 |
| 평소 | 주(a)로만 보낸다 — echo-was 의 가중치·`/counters`·Prometheus 가 a 를 보기 때문에 숫자가 맞는다 |
| a 장애 | 장애 조치 백엔드 b 로 넘긴다(가중치는 b 가 2초마다 맞춰 둔 마지막 값). a 가 돌아오면 다시 a |
| Cloudflare | `*.echoport.uk` A 레코드를 출력 `entrypoint_lb_ip` 하나로(프록시 켬). 기존 a·b 레코드는 지운다 |
| 방화벽 | NLB 헬스체크 대역 35.191.0.0/16 · 209.85.152.0/22 · 209.85.204.0/22 → 80 |

되돌리기: Cloudflare 레코드를 a IP 로 되돌리면 끝(LB 는 남아 있어도 무해). LB 를 지우려면 `entrypoint_lb_enabled = false` → apply.

### 11/8 — 보조 b 뺌, VM 하나만 (운영 선반영)

이중화는 시연에 필요 없고 b 는 서비스별 분리(서비스 모드) 전 legacy 코드라 a 가 죽어 b 가 받으면 분리가 풀렸다 → **a 하나만** 남긴다. LB IP(Cloudflare 가 가리킴)는 그대로, 백엔드만 a.

- 05:14 `gcloud compute backend-services remove-backend echo-dev-entry-lb --region asia-northeast3 --instance-group echo-dev-entry-b --instance-group-zone asia-northeast3-b` (35초)
- 05:15~05:16 `gcloud compute instances stop echo-dev-entry-b --zone asia-northeast3-b` (59초). **지우지 않았다** — VM·디스크·고정 IP·인스턴스 그룹은 Terraform state 에 남아 있다(정지 중 디스크·IP 요금은 계속).
- 그동안 손님 3주소 2초 프로브 실패 0, b 유입 0건(헬스체크도 끊김).
- Terraform 반영: `entrypoint_secondary_zones = []` 로 바꾸고 apply 하면 b VM·IP·그룹이 지워지고 LB 백엔드는 a 하나로 맞는다(이 PR 에서 LB 를 보조 존 없이도 만들게 바꿈 — 안 바꾸면 LB 째 지워져 대표 주소가 멈춘다). apply 전 plan 에서 지워지는 것이 b 관련 4개(instance·address·instance_group·backend 블록 변경)뿐인지 확인한다.
- 되돌리기: `gcloud compute instances start echo-dev-entry-b --zone asia-northeast3-b` → `gcloud compute backend-services add-backend echo-dev-entry-lb --region asia-northeast3 --instance-group echo-dev-entry-b --instance-group-zone asia-northeast3-b --failover`.

## 진입점 c — AWS 서울 (인프라 17, 코드만 · 기본 꺼짐 · 미적용)

입구가 GCP 한 회사·한 리전이면 GCP NLB·VPC·리전 장애 때 a·b 가 같이 죽는다. 같은 한 벌을 **AWS 서울** EC2 c 에 하나 더 두고, Cloudflare Load Balancer 가 GCP NLB(풀 1) → c(풀 2) 순서로 페일오버한다. 설계·적용 절차·되돌리기·요금은 [SPEC](../specs/infra-17-second-provider-entrypoint.md).

| 무엇 | a·b (GCP) | c (AWS 서울) |
|---|---|---|
| 코드 | `gcp/dev/entrypoint.tf` | `aws/dev/entrypoint-c.tf` (`entrypoint_c_enabled`) |
| 파일 전달 | 메타데이터 startup-script | S3 설정 버킷 → systemd `echo-entry-c-sync`(부팅마다). user_data 16KB 한도 때문 |
| 가중치 | a = echo-was PUT, b = a 내부 IP 에서 당김 | a **공인** IP:8080 에서 당김(GCP 방화벽 `entrypoint_weights_sync_cidrs` = c EIP/32) |
| 토큰 | Secret Manager | SSM SecureString `/echo/dev/entry-c/weights-token`(a 와 같은 값, 적용 절차가 파이프로 넣음) |
| 업스트림 gcp | 내부 LB 10.60.0.8 | ingress-nginx **외부** LB(`cluster-addons/gke/ingress-nginx-external-entry-c.yaml`, c EIP 만 허용) |
| 업스트림 aws | 닻 ALB | 같은 ALB(`inbound-cidrs` 에 c EIP 추가) |
| journal · remote write | a 만 | 꺼짐 |
| 들어오는 길 | 80 전체 + NLB | 80·443 Cloudflare 대역만, 22 없음(SSM) |

다시 맞추기: `aws ssm start-session --region ap-northeast-2 --target <entrypoint_c_instance_id>` → `sudo systemctl start echo-entry-c-sync` · 로그 `journalctl -u echo-entry-c-sync`.
