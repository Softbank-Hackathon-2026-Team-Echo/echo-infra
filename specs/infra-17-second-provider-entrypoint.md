# 인프라 17: 진입점을 서울 안 두 클라우드로 — AWS VM c + Cloudflare Load Balancer

- 상태: **설계 + Terraform 코드(기본 꺼짐) + 적용 절차서까지.** `terraform apply`·새 자원·Cloudflare 변경 0
- 작성일: 2026-11-07 (지민 결정 R6a′, 03시)
- GitHub 이슈: echo-infra `[인프라 17] 진입점을 서울 안 두 클라우드로 — AWS VM c + Cloudflare LB`
- 브랜치: `feat/infra-17-second-provider-entrypoint`
- 작성: 김지민(Saccharine1211) · 리뷰: 서동옥(SeoDongOk, 인프라 담당)
- **적용 시점: 지민 아침 확인 뒤.** 밤에는 PR 까지만 한다(밤 규칙). 적용은 아래 7절 절차를 따른다.
- 결정(다시 묻지 않음): 입구를 **서울 안에서 두 회사**로(GCP a·b + AWS c). 도쿄는 재난 시나리오(대피 출발) 리전이라 입구를 두지 않는다. 요금 승인: t3.small급 ≈ $0.5/일 + Cloudflare Load Balancer $5/월(실제 계산은 9절 — 승인액보다 조금 크다).

## 1. 왜

| 관점 | 지금 | 이 작업 뒤 |
|---|---|---|
| 락인 | 손님 주소 `*.echoport.uk` 의 입구(진입점 VM a·b, NLB)가 **GCP 한 회사·서울 한 리전**. "Beyond Lock-In" 을 말하면서 입구가 한 회사에 묶여 있다 | 입구가 GCP(a·b)와 AWS(c) **두 회사**. 어느 한 회사 입구가 통째로 죽어도 대표 주소가 산다 |
| 단일 장애점 | a 하나 장애는 NLB 가 b 로 넘긴다(11/6 실측 3.8초). 그러나 **NLB·VPC·GCP 서울 리전·GCP 계정** 장애는 a·b 가 같이 죽는다 | Cloudflare LB 가 GCP 풀 헬스체크 실패를 보고 AWS c 로 넘긴다 |
| 역할 분리 | 환경 간 비율은 Envoy 가중치, 입구 생존은 GCP NLB | 그대로. Cloudflare LB 는 **입구 생존(어느 진입점이 받나)** 에만 쓰고, 환경 간 비율(aws/gcp)은 여전히 Envoy 가중치다 — `entrypoint/README.md` "DNS 는 프록시 자체의 생존에만" 원칙을 지킨다 |

## 2. 지금 구조 (2026-11-07 저장소 읽기)

| 무엇 | 값 | 출처 |
|---|---|---|
| 진입점 a | `echo-dev-entry`, GCP asia-northeast3-a, e2-small, Debian 12, 공인 34.158.202.103 | `gcp/dev/entrypoint.tf` |
| 진입점 b | `echo-dev-entry-b`, 존 b (`entrypoint_secondary_zones = ["b"]`), 8.230.16.205 | 같음 |
| 앞단 | 리전 외부 패스스루 NLB `entry_lb`(34.158.197.107, 80), 헬스체크 `/__entry/healthz` 2초·2회, 평소 a · a 장애 시 b(장애 조치 백엔드) | 같음, 인프라 5.3 |
| VM 안 | startup 스크립트(`entrypoint-startup.sh.tftpl`)가 `entrypoint/` 파일을 메타데이터에서 `/opt/entrypoint` 에 쓰고 `docker compose up -d --build`. 컨테이너: Envoy :80 · weights-api :8080 · journal :8082(관리) · Prometheus :9090 · Grafana :3000 | `entrypoint/docker-compose.yml` |
| 가중치 | weights-api 가 Envoy 파일 xDS(`routes.yaml`)를 쓴다. **echo-was 는 a 만 PUT**(내부 주소 `http://<a 내부 IP>:8080`). **b 는 a 에서 당긴다**: `SYNC_FROM=http://<a 내부 IP>:8080` → 2초마다 `GET /weights`(Bearer, a·b 같은 토큰). a 가 죽으면 b 는 마지막 값 유지 | `weights-api/app.py` `sync_loop` |
| 토큰 | 가중치 토큰·Grafana·remote write·journal 토큰은 a 가 첫 부팅 때 만들어 GCP Secret Manager `echo-dev-entry-*` 에 넣고, b 는 같은 값을 읽는다 | startup 스크립트 3절 |
| 요청 기록(journal) | 주 진입점 a 에만(`entrypoint_journal_enabled`), b 는 늘 꺼짐. 저장소는 **VM 안 도커 볼륨 `journal-data` 의 SQLite**(최근 15분) | SPEC infra-12.4 D-11 |
| 업스트림 | `aws` = 도쿄 닻 ALB `echo-dev-apps-…ap-northeast-1.elb.amazonaws.com:80`(**공인**, `inbound-cidrs` 로 a·b·GKE NAT 만 허용) · `gcp` = ingress-nginx **내부** LB `10.60.0.8:80`(VPC 안에서만) | `cluster-addons/README.md`, `eks/anchor-ingress.yaml` |
| Cloudflare | 저장소 밖 수동. `*.echoport.uk` 프록시 A 레코드 → 진입점(5.3 이후 NLB IP 로 바꾸는 중). SSL 모드 Flexible(→ 원본 80) | `docs/manual-resources.md` |
| AWS Terraform | `aws/dev` 루트는 **도쿄**(VPC 10.50.0.0/16, EKS). 서울에는 `aws/onprem-demo`(서울 기본 VPC 172.31.0.0/16, t3.small, SSM 접속, 인바운드 0, EIP)만 | `aws/dev/*.tf`, `aws/onprem-demo/main.tf` |

## 3. 구성

```text
손님 ─▶ Cloudflare (프록시, *.echoport.uk)
          └─ Load Balancer *.echoport.uk  (steering: Off - Failover)
               ├─ 풀 1 gcp-entry (우선) : 34.158.197.107:80  GCP NLB ─▶ a (장애 시 b)
               └─ 풀 2 aws-entry-c      : <c EIP>:80        AWS 서울 EC2 c
                                            │ 같은 Envoy·weights-api·Prometheus·Grafana (journal 꺼짐)
                                            ├─ aws ─▶ 도쿄 닻 ALB :80  (inbound-cidrs 에 c EIP 추가)
                                            └─ gcp ─▶ ingress-nginx **외부** L4 LB :80 (c EIP/32 만)
            c 의 weights-api ── 2초마다 GET /weights ──▶ a 공인 IP :8080 (GCP 방화벽: c EIP/32 → 8080 만)
```

### 3.1 VM c (AWS `aws/dev/entrypoint-c.tf`, 스위치 `entrypoint_c_enabled` 기본 false)

| 항목 | 값 | 이유 |
|---|---|---|
| 리전·자리 | `ap-northeast-2`(서울) 기본 VPC, AZ a 기본 서브넷 | a·b 와 같은 도시라 지연이 같다. 새 VPC·NAT 비용 0. onprem-demo 와 같은 VPC(서로 연결은 없음) |
| provider | `aws/dev` 루트에 `aws.seoul` 별칭을 더한다(나머지 루트는 도쿄 그대로) | 지시대로 dev 루트에 둔다. 리전 변수 검증으로 도쿄를 거부한다 |
| 기종 | t3.small(2 vCPU·2GB, a·b 의 e2-small 과 같은 급), 크레딧 standard, gp3 20GB 암호화, IMDSv2 필수 | 프리 플랜 계정 허용 기종. unlimited 크레딧 추가 요금 방지 |
| OS | Ubuntu 24.04(Canonical SSM 공개 파라미터) | SSM 에이전트 기본 포함 → 22 를 열지 않는다(onprem-demo 와 같음). a·b 의 Debian 12 와 OS 는 다르지만 컨테이너·설정은 같다 |
| 파일 전달 | `entrypoint/` 허용 목록(a·b 와 같은 목록)을 **S3 설정 버킷**에 올리고 VM 이 부팅마다 받는다 | EC2 user_data 한도 16KB < 파일 약 61KB. GCP 메타데이터(256KB)와 다르다 |
| 부팅 | user_data 는 systemd 유닛 `echo-entry-c-sync` 만 깐다. 유닛이 부팅마다 Docker·AWS CLI 설치(처음만) → S3 받기 → `.env` → `docker compose up -d --build` → envoy.yaml 이 바뀌었으면 Envoy 다시 만들기 | GCP startup 과 같은 순서·멱등. 설정 변경 = apply + `sudo systemctl start echo-entry-c-sync` |
| `.env` | `UPSTREAMS`·`DEFAULT_WEIGHTS`·`SYNC_FROM` 은 Terraform 이 `settings.env` 로, `JOURNAL_ENABLED=false`, remote write 수신 꺼짐 | journal·remote write 는 a 에만(인프라 12.4 D-11, 인프라 9) |
| 비밀값 | 가중치 토큰 = a·b 와 **같은 값**을 SSM SecureString `/echo/dev/entry-c/weights-token` 에서 읽는다. 값은 적용 절차가 GCP Secret Manager 에서 **파이프로** 넣는다(화면·state 에 안 남음). 없으면 유닛이 멈춘다(다른 토큰으로 뜨면 동기화가 401 로 실패해 기본 가중치로 흐르므로, 헬스체크 실패로 풀에서 빠지는 편이 안전). Grafana 관리자 비밀번호는 c 가 혼자 만들어 VM 안(0600)에만 | 저장소·state 비밀값 0 (NFR-17) |
| 보안 그룹 | 들어오는 규칙 **80·443 을 Cloudflare IPv4 15대역(관리형 접두사 목록)에서만**. 22·8080·8082·9090·3000 은 열지 않는다. 나가는 길 전체 | 손님·Cloudflare LB 헬스체크 모두 Cloudflare 대역에서 온다. Cloudflare 를 거치지 않는 직접 접근 차단. 관리 포트는 SSM 포트 포워딩으로 |
| IAM | 역할 `echo-dev-entry-c`: `AmazonSSMManagedInstanceCore` + 설정 버킷 GetObject·ListBucket + 토큰 파라미터 GetParameter 하나 | 최소 권한 |
| 공인 IP | EIP(`entrypoint_c_ip` 출력) | Cloudflare 풀 엔드포인트·ALB·GKE LB·GCP 방화벽이 모두 이 /32 를 쓴다. 기기를 멈췄다 켜도 그대로 |

### 3.2 가중치 동기화 경로 (결정: **c 가 a 에서 당긴다** — b 와 같은 방식)

| 안 | 어떻게 | 판단 |
|---|---|---|
| **A. c 가 a 에서 당김 (채택)** | `SYNC_FROM=http://34.158.202.103:8080`(a 공인 IP). GCP 방화벽 `entry_weights_sync`(새 변수 `entrypoint_weights_sync_cidrs`, 기본 빈 값)로 c EIP/32 → 8080 하나만 연다 | 코드 변경 0(weights-api 그대로), echo-was 변경 0. b 와 똑같이 a 가 죽으면 마지막 값 유지 |
| B. echo-was 가 a·c 둘 다 PUT | 실행기가 진입점 목록을 돌며 PUT | echo-was 저장소 변경 + 부분 실패(한쪽만 바뀜) 처리 필요. 밤 범위·시간 초과 |
| C. 가중치 저장소 분리(공용 KV) | 진입점 셋이 한 저장소를 봄 | 규모가 커질 때의 답(README 5.1 한계). 지금은 과함 |

- 한계 1: 토큰이 **평문 HTTP 로 공인 구간**(서울 AWS→서울 GCP)을 2초마다 지난다. 8080 은 c EIP 와 admin CIDR 에서만 열려 있어 토큰이 새도 그 출처에서만 쓸 수 있다. remote write(9090) 평문과 같은 시연 기간 한계로 `docs/design-infra.md` 10절에 같이 적는다. 대안: a 의 8080 앞에 TLS(자체 서명) — 후속.
- 한계 2: GCP 입구 장애 동안(c 가 받는 동안) echo-was 는 a 에 PUT 을 못 해 **비율 변경 불가**, c 는 마지막 값으로 흐른다(b 와 같은 한계). `/counters` 는 a 만 읽으므로 c 가 받은 요청은 echo-was 판정 숫자에 들어가지 않는다.

### 3.3 gcp-seoul 업스트림 경로 (AWS 에서 10.60.0.8 에 못 닿는다)

| 안 | 비용 | 시간 | 판단 |
|---|---|---|---|
| **A. ingress-nginx 앞에 외부 L4 LB 를 하나 더 + 소스 IP 제한 (채택)** | GCP 전달 규칙 1개 ≈ $0.24~0.6/일 | 10분(kubectl apply 1회) | 기존 내부 LB(10.60.0.8, a·b 용)는 그대로. 같은 nginx 파드 앞에 `type: LoadBalancer` Service `ingress-nginx-entry-c`(`loadBalancerSourceRanges: [c EIP/32]`, 80 만, `externalTrafficPolicy: Local`). GKE 가 그 출처만 여는 방화벽을 만든다. 파일 `cluster-addons/gke/ingress-nginx-external-entry-c.yaml` |
| B. HA VPN / 인터커넥트 (AWS 서울 VPC ↔ GCP VPC) | HA VPN 터널 2개 + AWS VGW ≈ $3~4/일 이상 | BGP·라우팅·방화벽 2~3시간 | 비용·시간 초과 |
| C. c 의 gcp 업스트림을 GCP NLB(진입점) 로 | 0 | 0 | a 의 Envoy 가 **가중치로 한 번 더 나눠** 비율이 이중으로 걸린다 — 안 됨 |
| D. GKE 에 cloudflared 터널 | 0 | 1시간+ | 대표 주소 `*.echoport.uk` 가 같은 Cloudflare 영역이라 Host 라우팅이 꼬일 위험. 시간 초과 |

- 받는 쪽 Host: c 의 Envoy 는 a·b 처럼 Host(`{서비스}-{suffix}.echoport.uk`)를 그대로 넘긴다. 외부 LB 도 같은 nginx 라 앱 Ingress 규칙이 그대로 맞는다.
- aws 업스트림(도쿄 닻 ALB)은 이미 공인이다 — `anchor-ingress.yaml` 의 `inbound-cidrs` 에 c EIP/32 를 더한다(11/4 b 를 더할 때와 같은 일. 빠뜨리면 c 에서 aws 헬스체크가 타임아웃돼 gcp 로만 흐른다).
- 인프라 16(고객 전용 GKE)으로 ingress-nginx 를 옮기면 외부 LB Service 도 그 클러스터에 같이 적용한다.

### 3.4 Cloudflare Load Balancer (저장소 밖, 화면 절차 7절 6단계)

| 항목 | 값 | 이유 |
|---|---|---|
| 호스트 | `*.echoport.uk` (프록시, 주황 구름) | 기존 `*` A 레코드와 **같은 구체성이면 LB 가 우선**한다(Cloudflare 문서 "DNS records for load balancing" Scenario 3). 더 구체적인 레코드(`api`·`app`·`*.gcp-seoul`·`*.aws-tokyo`·온프레 터널 CNAME)는 그대로 그 레코드가 이긴다. **A 레코드는 지우지 않는다** — LB 를 끄면 그 레코드가 다시 응답(되돌리기 1단계) |
| 풀 1 `echo-entry-gcp` | 엔드포인트 `34.158.197.107`(GCP 출력 `entrypoint_lb_ip`), 가중치 1 | 평소 전부 여기 — echo-was 의 가중치·판정·지표가 a 를 보므로 숫자가 맞는다(5.3 과 같은 이유) |
| 풀 2 `echo-entry-aws-c` | 엔드포인트 `<c EIP>`(AWS 출력 `entrypoint_c_ip`), 가중치 1 | 풀 1 이 Critical 일 때만 |
| 스티어링 | **Off - Failover**, 순서 풀 1 → 풀 2, 폴백 풀 = 풀 2 | 비엔터프라이즈 기본 정책. 풀 1 이 돌아오면 다시 풀 1(페일백) |
| 모니터 | HTTP, 포트 80, `GET /__entry/healthz`, 기대 `200`, 본문 `ok`, 간격 **60초**(Free·Pro 최솟값), 타임아웃 2초, 재시도 1, 헬스 지역 **동북아 1곳** | `/__entry/healthz` 는 Envoy 가 Host 와 무관하게 바로 200 을 준다(진입점 자체 생존). 지역·간격을 늘리면 유료 옵션이 붙는다 — 화면에 추가 요금이 보이면 멈추고 묻는다 |
| 세션 고정 | 끔 | 풀마다 엔드포인트 1개라 의미 없음 |

**예상 전환 시간**: 풀 1 이 죽은 직후부터 다음 모니터 시각까지 0~60초 + 실패 판정(타임아웃 2초 × (1+재시도 1)) ≈ 4초 + 엣지 반영 수 초 → **약 5~70초(평균 30~40초)**. 그동안 손님 요청은 Cloudflare 521/522 로 실패한다. 비교: a 하나만 죽으면 GCP NLB 가 3.8초에 b 로 넘기는 것은 그대로다(Cloudflare 는 풀 1 이 살아 있다고 본다). 즉 **진입점 한 대 장애 = 3.8초(GCP NLB), GCP 입구 전체 장애 = 5~70초(Cloudflare LB)** 의 2단 구조다.
- 더 줄이려면(후속, 미검증): Business 요금제 15초 간격, 또는 한 풀에 두 엔드포인트 + 세션 고정 + Zero-Downtime Failover(풀 안에서만 재시도하는 기능).

## 4. 하지 않는 것

- echo-was 변경(PUT 대상 늘리기), weights-api·Envoy 설정 변경 — 0줄.
- c 의 요청 기록(journal) 켜기. c 는 GCP 입구가 죽었을 때만 받으므로 그 사이 쓰기는 기록되지 않는다(b 와 같은 한계, 12.4 재생은 a 기록만).
- 도쿄 진입점, VPN·인터커넥트, Cloudflare 를 Terraform 으로 관리(지금처럼 수동 + `docs/manual-resources.md` 기록).

## 5. Terraform 변경 (이 PR)

| 파일 | 내용 | 기본값에서 plan |
|---|---|---|
| `aws/dev/versions.tf` | provider `aws.seoul` 별칭 | 0 |
| `aws/dev/variables.tf` | `entrypoint_c_*` 9개(enabled·region·az·instance_type·upstreams·default_weights·sync_from·token_parameter·ingress_cidrs) | 0 |
| `aws/dev/entrypoint-c.tf` | 설정 버킷 + 객체, 접두사 목록·보안 그룹·규칙, IAM, EC2, EIP | 0 (켜면 27 add) |
| `aws/dev/entrypoint-c-bootstrap.sh.tftpl` | user_data(맞추기 스크립트 + systemd 유닛) | — |
| `aws/dev/outputs.tf` | `entrypoint_c_ip`·`entrypoint_c_instance_id`·`entrypoint_c_config_bucket` (꺼지면 null) | 0 |
| `gcp/dev/entrypoint.tf`·`variables.tf` | 방화벽 `entry_weights_sync`(8080, `entrypoint_weights_sync_cidrs`, 기본 빈 값 = 안 만듦) | 0 |
| `cluster-addons/gke/ingress-nginx-external-entry-c.yaml` | gcp 업스트림용 외부 LB Service(예시 주소 203.0.113.10 자리) | 클러스터 변경 0(적용 전) |

### 5.1 plan (읽기 전용, `-lock=false`, 2026-11-07 03시대, 해커톤 계정 706878591119)

| 경우 | 결과 |
|---|---|
| 스위치 끔(기본), **전체** plan | **No changes** |
| 스위치 끔, c 자원 target | No changes |
| 스위치 켬(`entrypoint_c_enabled=true`, `sync_from` 예시), c 자원 target | **Plan: 27 to add, 0 to change, 0 to destroy** — S3 버킷 1 + 공개 차단 1 + 객체 13(파일 12 + settings.env) + 접두사 목록 1 + 보안 그룹 1 + 규칙 3(80·443·나감) + IAM 역할·정책·연결·프로필 4 + EC2 1 + EIP 1 + 연결 1. AMI `ami-05b2d28c4a1614552`(Ubuntu 24.04), t3.small |

GCP 쪽은 plan 을 돌리지 않았다(tfvars·자격은 동옥 로컬). 새 방화벽은 `count = length(var.entrypoint_weights_sync_cidrs) > 0 ? 1 : 0` 이라 기본값에서 자원 0, 켜면 1 add 다(`validate` 통과).

## 6. 시험 계획

11/6 3.8초 측정과 같은 도구 `entrypoint/scripts/failover-probe.sh`(대표 주소 `/healthz` 를 Cloudflare 경유 https 로 초당 RATE 번, 클라이언트 타임아웃 5초, 첫 실패 → 마지막 실패 = 실패 구간)를 그대로 쓴다.

| # | 시험 | 방법 | 통과 기준 |
|---|---|---|---|
| T1 | c 단독 동작 | SSM 세션에서 `curl -s localhost/__entry/healthz` · `curl -s -o /dev/null -w '%{http_code}' -H 'Host: <대표 주소>' localhost/healthz` · weights-api `/status`(토큰은 `.env` 에서 셸 변수로, 출력하지 않음) | `ok` · 200 · aws·gcp 모두 healthy ≥1 |
| T2 | 가중치 동기화 | a 가중치와 c `GET /weights` 비교, `docker compose logs weights-api` 에 `sync source reachable` | 같은 값 |
| T3 | Cloudflare 풀 상태 | Load Balancing 화면 | 풀 1·2 모두 Healthy, 트래픽 풀 1 |
| T4 | **GCP 입구 전체 장애 → c 전환 시간** | 창 1: `HOST=<대표 주소> DURATION=300 RATE=2 entrypoint/scripts/failover-probe.sh` / 창 2(30초 뒤): `gcloud compute instances stop echo-dev-entry --zone asia-northeast3-a` 와 `echo-dev-entry-b --zone asia-northeast3-b` 를 **같이** 멈춘다 | 실패 구간 기록(예상 5~70초), 그 뒤 200 이 c 에서(c Envoy 접근 로그 증가) |
| T5 | 페일백 | 두 VM `start` → NLB HEALTHY → 다음 모니터 뒤 트래픽 풀 1 | 실패 0, 가중치 그대로 |
| T6 | 직접 접근 차단 | M1 에서 `curl -m 5 http://<c EIP>/__entry/healthz` | 타임아웃(Cloudflare 대역만 허용) |

- T4 는 실제로 대표 주소 입구를 몇 분 끊는 시험이다. 부하(loadgen)·이전·컷오버가 돌지 않는 시각에, 지민 확인 뒤 한다. 결과는 `docs/rehearsals/2026-11-07-entry-second-provider.md` 와 `docs/design-infra.md` 7절에 "실측만" 적는다.

## 7. 적용 절차 (지민 아침 확인 뒤 · 8단계 · 약 75분)

자격: AWS 는 `env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN AWS_PROFILE=hackathon`(먼저 `aws sts get-caller-identity` 가 `706878591119` 인지), GCP 는 `--configuration=echo`(프로젝트 `team-echo-final`). Cloudflare 는 계정 헤더가 해커톤(개인) 계정인지 먼저 읽는다 — 회사(MORI) 세션과 섞지 않는다.

| 단계 | 할 일 | 명령·화면 | 확인 | 시간 |
|---|---|---|---|---|
| 0 | 승인·시각 확인 | 지민 "적용해" + 요금(9절) 확인. loadgen·이전 안 도는지 | — | 5분 |
| 1 | 토큰 파라미터 | `gcloud secrets versions access latest --secret=echo-dev-entry-weights-token --project team-echo-final \| aws ssm put-parameter --region ap-northeast-2 --name /echo/dev/entry-c/weights-token --type SecureString --value file:///dev/stdin` (값을 화면에 찍지 않는다) | `aws ssm describe-parameters --region ap-northeast-2 --parameter-filters Key=Name,Values=/echo/dev/entry-c/weights-token` 1건 | 2분 |
| 2 | EIP 먼저 | `aws/dev/terraform.tfvars` 에 `entrypoint_c_enabled = true` → `terraform plan -target=aws_eip.entry_c`(1 add) → apply → `terraform output entrypoint_c_ip` | IP 1개 | 3분 |
| 3 | 받는 쪽 열기 | (a) GCP `terraform.tfvars` 에 `entrypoint_weights_sync_cidrs = ["<c IP>/32"]` → `-target=google_compute_firewall.entry_weights_sync` plan(1 add) → apply (b) `cluster-addons/eks/anchor-ingress.yaml` `inbound-cidrs` 끝에 `,<c IP>/32` → `kubectl --context echo-dev-eks apply -f …` (c) `cluster-addons/gke/ingress-nginx-external-entry-c.yaml` 의 203.0.113.10 을 c IP 로 → `kubectl --context gke_… apply -f …` → `get svc ingress-nginx-entry-c` EXTERNAL-IP 대기 | 방화벽 1개, ALB SG 에 c IP, 외부 LB IP 1개 | 15분 |
| 4 | c 만들기 | `aws/dev/terraform.tfvars`: `entrypoint_c_upstreams = { aws = "<닻 ALB DNS>:80", gcp = "<3c EXTERNAL-IP>:80" }`, `entrypoint_c_sync_from = "http://34.158.202.103:8080"` → plan(**26 add, 0 change, 0 destroy** — 2단계 EIP 뒤) → apply | 출력 `entrypoint_c_instance_id` | 10분 |
| 5 | c 확인 (T1·T2) | 부팅·이미지 빌드 5~8분 대기 → `aws ssm start-session --region ap-northeast-2 --target <id>` → `journalctl -u echo-entry-c-sync` 에 `완료`, 6절 T1·T2 | healthz ok, aws·gcp healthy, 가중치 = a | 10분 |
| 6 | Cloudflare LB (화면) | ① 대시보드 → 계정 → **Load Balancing** → Enable(결제 화면 금액 $5/월 확인, 추가 옵션 선택 안 함) ② **Monitors** → Create: HTTP · 포트 80 · 경로 `/__entry/healthz` · 고급: 간격 60 · 타임아웃 2 · 재시도 1 · 기대 코드 200 · 본문 `ok` ③ **Pools** → Create `echo-entry-gcp`: 엔드포인트 `34.158.197.107`, 모니터 ②, 헬스 지역 동북아 → Create `echo-entry-aws-c`: 엔드포인트 `<c IP>`, 같은 모니터·지역 ④ 영역 `echoport.uk` → **Traffic → Load Balancing → Create load balancer**: 호스트 `*`(=`*.echoport.uk`), 프록시 켬, 풀 순서 gcp → aws-c, 폴백 aws-c, 스티어링 Off(Failover), 세션 고정 끔 → Save ⑤ 기존 `*` A 레코드는 **그대로 둔다** | 풀 2개 Healthy, LB Healthy, 대표 주소 200(트래픽 a) | 15분 |
| 7 | 시험 T3~T6 | 6절 | 실패 구간 기록 | 15분 |
| 8 | 기록 | `docs/rehearsals/2026-11-07-entry-second-provider.md`, `docs/design-infra.md` 3·7·10절, `docs/manual-resources.md`(Cloudflare LB·모니터·풀, GKE Service, SSM 파라미터), 3(b)(c) 의 실제 IP 를 후속 PR 로 커밋, 이슈 댓글 | — | 10분 |

## 8. 되돌리기

| 순서 | 할 일 | 효과 | 시간 |
|---|---|---|---|
| 1 | Cloudflare Load Balancing → LB `*.echoport.uk` **Disable**(또는 삭제) | 기존 `*` A 레코드(GCP NLB)가 다시 응답 — A 레코드를 건드리지 않았으므로 원복 작업 없음. 프록시 레코드라 즉시 | 1분 |
| 2 | 풀·모니터 삭제 → Billing 에서 Load Balancing 구독 해지 | $5/월 정지 | 3분 |
| 3 | AWS `entrypoint_c_enabled = false` → plan(**27 destroy**) → apply | EC2·EIP·버킷(force_destroy)·IAM·보안 그룹 삭제 | 5분 |
| 4 | `aws ssm delete-parameter --region ap-northeast-2 --name /echo/dev/entry-c/weights-token` | 토큰 사본 제거 | 1분 |
| 5 | `kubectl … delete -f cluster-addons/gke/ingress-nginx-external-entry-c.yaml`, 닻 `inbound-cidrs` 에서 c IP 빼고 apply, GCP `entrypoint_weights_sync_cidrs = []` apply(1 destroy) | 열어 둔 길 닫기 | 5분 |

1 만으로 손님 경로는 지금과 같아진다. 2~5 는 비용·노출 정리.

## 9. 요금

| 항목 | 단가 (출처) | 하루 |
|---|---|---|
| EC2 t3.small 서울 | $0.026/시간 (AWS Pricing API, 11/7 조회) | $0.62 |
| 공인 IPv4(EIP) | $0.005/시간 | $0.12 |
| EBS gp3 20GB | $0.0912/GB-월 | $0.06 |
| S3·SSM 파라미터(Standard)·평소 전송 | 객체 13개·요청 부팅 때만 | ≈ $0 |
| GKE 외부 L4 LB 전달 규칙 | $0.025/시간(프로젝트 첫 5개) 또는 추가분 $0.01/시간 | $0.24~0.60 |
| Cloudflare Load Balancing | $5/월(엔드포인트 2개 포함, 지민 승인) | 월정액 |
| **합계** | | **≈ $1.0~1.4/일 + $5/월** |

- 승인(≈ $0.5/일 + $5/월)보다 **하루 약 $0.5~0.9 크다**: t3.small 실제 값이 $0.62/일이고, EIP·디스크와 GCP 외부 LB 가 더해진다. 11/7~11/8 이틀이면 ≈ $2~3 + $5 ≈ ₩1.1만(한도 ₩500,000 대비 2%). AWS 쪽은 프리 플랜 크레딧에서 나간다. 줄이는 안: t3.micro(1GB, $0.31/일)는 컨테이너 5개에 메모리가 빠듯해 추천하지 않는다.
- 시연 뒤 8절 2~5 로 정리한다(유휴 EIP·구독이 계속 과금되지 않게).

## 10. 미검증 (적용 전이라 아직 모르는 것)

- Ubuntu 24.04 에서 맞추기 스크립트 실제 실행(문법 `bash -n`·shellcheck 만 통과), 첫 부팅 소요 시간.
- Cloudflare Free 영역에서 모니터 최소 간격(문서: Pro 60초) · 헬스 지역 1곳이 $5 에 포함되는지 — 결제 화면에서 확인.
- 실제 전환 시간(예상 5~70초)은 T4 로만 확정한다.
- GCP 프로젝트의 현재 전달 규칙 수(외부 LB 단가 $0.025 vs $0.01 갈림).
- GKE 외부 LB 에서 `/healthz`(Host `gcp`) 응답이 내부 LB 와 같은지(같은 nginx 라 같을 것으로 본다).
