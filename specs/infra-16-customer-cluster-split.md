# 인프라 16: 고객 워크로드 전용 GKE 클러스터 분리 SPEC

- 상태: **설계 + Terraform 코드(기본 꺼짐)만. 적용하지 않았다**(`terraform apply`·클라우드·운영 kube 변경 0)
- 작성일: 2026-11-07
- GitHub 이슈: echo-infra `[인프라 16] 고객 워크로드 전용 GKE 클러스터 분리`
- 브랜치: `feat/infra-16-customer-cluster-split`
- 작성: 김지민(Saccharine1211) · 리뷰: 서동옥(SeoDongOk, Terraform) · 이도현(xtkww971, DB)
- 적용 시점: **중간 발표(11/7 17시) 이후 팀 합의 뒤.** 지금 운영(보안 매트릭스 BLOCKED 0, 이전·복귀·컷오버 리허설 통과 상태)은 건드리지 않는다.

## 1. 왜

| 관점 | 지금 | 나눈 뒤 |
|---|---|---|
| 장애 반경 | 관제탑(echo-was API·일꾼·관리 DB `echo-db`)과 고객 앱·Postgres B·ingress-nginx 가 **같은 노드 2대**를 나눠 쓴다. 고객 앱 폭주·노드 교체·클러스터 업그레이드가 관제탑을 같이 흔든다(11/5 노드 업그레이드 때 `echo-was-api` 이동으로 `/healthz` 33~68초 끊김 실측). | 고객 클러스터 노드가 죽거나 업그레이드돼도 관제탑은 그대로 → 이전·롤백을 지시할 주체가 살아 있다. |
| 보안 | 같은 클러스터라 `echo-was` 에 NetworkPolicy 울타리(default-deny + GCLB 대역)를 따로 둬야 했다. 노드 커널·kubelet·노드 SA 를 고객 코드와 공유한다. | 클러스터·노드 SA·서브넷이 따로. VPC 방화벽상 고객 대역 → 관제탑 노드·파드는 **기본 거부**(9090 지표 하나만 진입점으로 연다). |
| 메시지(Beyond Lock-In) | "관제탑이 대피 대상 클러스터 안에 있다"는 질문에 약하다. | 관제탑 = 데이터 평면 밖. AWS 도쿄·GCP 서울·온프레 세 고객 환경 모두 관제탑과 다른 클러스터. |

## 2. 지금 구조 (2026-11-07 읽기 전용 확인)

- 클러스터: `echo-dev-gke` 하나(asia-northeast3-a, 1.36.5-gke.1982000, RAPID, 정비 제외 `demo-freeze` ~2026-11-08T14:59Z), 풀 `default` e2-standard-2 ×2(CPU 17%/30%, 메모리 36%/45%).
- 네임스페이스: 관제탑 `echo-was`(api·worker·`echo-db` StatefulSet), `echo-ops`(컷오버 Job), `echo-loadgen`, `echo-otel` / 고객 쪽 `demo-y6cz3jrc`(app 1), `shap-api-5eyf1kkb`(워크로드 0), `ingress-nginx`, `cert-manager`, `echo-data`(Postgres B `echo-pg` StatefulSet + `echo-pgbouncer`, PVC 10Gi).
- 부하 분산기:
  - ingress-nginx **내부 L4 LB `10.60.0.8`**(80·443, `*.gcp-seoul.echoport.uk` 와일드카드 LE 인증서). 진입점 Envoy 업스트림이 `gcp=10.60.0.8:80`(진입점 VM 메타데이터, tfvars `entrypoint_upstreams`).
  - Postgres B **외부 L4 LB `<GCP_PG_LB_IP>:5432`**(`loadBalancerSourceRanges` AWS NAT <AWS_NAT_IP>/32, 역방향 구독·`cutover.sh` 의 `B_HOST`).
  - 관제탑 GCLB `<API_GCLB_IP>`(`api.echoport.uk`) — 이번 범위 밖, 그대로.
- echo-was 의 환경 접속 정보: **DB `environments.config`(JSON)** — gcp 는 `projectId`·`region`·`clusterName`·`clusterLocation`·`ingressDomain`·`ingressClass`, 비밀값 없음. 실행기(`app/executors/kubernetes/access.py`)가 GSA `echo-dev-echo-was` 메타데이터 토큰으로 GKE API `projects/{p}/locations/{위치}/clusters/{이름}` 에서 endpoint·CA 를 받는다. GSA 는 **프로젝트 단위 `roles/container.developer`**(Terraform 밖, 손으로 부여)라 같은 프로젝트 새 클러스터에도 바로 닿는다. 바꾸는 방법은 `PATCH /environments/{id}` 의 `config` 전체 교체(접속 상태가 UNCHECKED 로 돌아가 다시 확인).
- echo-was 데이터 확인(DATA_SYNC_CHECK): `deploy/base.yaml` ConfigMap `DATA_SYNC_DATABASES` 의 gcp 값이 **클러스터 안 DNS `echo-pg.echo-data.svc.cluster.local:5432/echo_sub`**. 클러스터를 나누면 닿지 않는다 → 바꿔야 한다(5절 3).
- 논리 복제: B 구독 `echo_sub` → A NLB(`echo-dev-pg-a-….elb…:5432`, GCP NAT <GCP_NAT_IP>/32 만, TLS require). 역방향 `echo_sub_rev` 는 A → B 외부 LB(컷오버 창 안에서 생성). 컷오버 Job 은 `echo-ops` KSA 가 **같은 클러스터의** `echo-data` Role 로 `kubectl exec` 한다(`replication/cutover-job/manifests/gke-binding.yaml`).
- state 버킷 `echo-tfstate-team-echo-final` 버전 관리 켜짐(롤백 근거).

## 3. 무엇을 옮기나

| 옮김 (새 `echo-dev-customer-gke`) | 남김 (`echo-dev-gke`) |
|---|---|
| 고객 앱 네임스페이스(`demo-y6cz3jrc` 등 `managed-by=echo-was` 라벨) — echo-was 재배포로 다시 생김 | `echo-was`(API·일꾼·관리 DB)·GCLB·SecretSync |
| `ingress-nginx`(내부 LB) + `cert-manager`(DNS-01, Cloudflare 토큰) + 와일드카드 인증서 | `echo-ops` 컷오버 Job(교차 클러스터 권한 추가 — 5절 4) |
| `echo-data`(Postgres B + PgBouncer B + 외부 LB) | `echo-loadgen`(진입점 공인 주소로 쏨, 위치 무관) |
| `echo-otel` 수집기(gcp overlay 그대로, 엔드포인트 10.60.0.6/0.9:9090) | — |

## 4. 설계 (Terraform `customer-gke.tf`)

- 스위치 `customer_gke_enabled`(기본 **false**) — 병합만으로는 아무것도 생기지 않는다(plan `No changes` 확인).
- 같은 프로젝트·같은 VPC `echo-dev` 에 **새 서브넷** `echo-dev-customer-asia-northeast3` `10.63.0.0/20`, 파드 `10.64.0.0/16`, 서비스 `10.65.0.0/20`, 컨트롤 플레인 `172.16.0.16/28`. 기존 서브넷·`network.tf` 는 바꾸지 않는다(대역 표 `contracts/aws-outputs.md` 에 한 줄 추가).
- Cloud NAT 는 `ALL_SUBNETWORKS_ALL_IP_RANGES` 라 새 서브넷도 **같은 NAT IP <GCP_NAT_IP>** 로 나간다 → AWS 쪽 A NLB·ALB 허용 목록 변경 없음.
- 방화벽: 기존 `echo-dev-internal`(출발지 = 관제탑 대역)로 진입점·관제탑 → 고객 클러스터(내부 LB·DB)는 열린다. 고객 대역 → 관제탑은 막힌 채로 두고, `echo-dev-customer-to-entry-metrics`(고객 노드·파드 → 태그 `entrypoint` tcp 9090)만 더한다.
- 클러스터 `echo-dev-customer-gke`: 존 클러스터, 비공개 노드, Workload Identity, Dataplane V2, 릴리스 채널 = 관제탑과 같은 변수(RAPID), `min_master_version 1.36.5-gke.1982000`, 정비 창 매일 03:00~07:00 KST, `demo-freeze`(NO_UPGRADES, ~2026-11-08T14:59Z — 지난 시각이면 `""`). Secret Manager CSI 는 켜지 않는다(고객 비밀은 echo-was 가 넣는 네임스페이스 Secret).
- 노드 풀 `customer`: e2-standard-2, 1~2대(자동 확장), 디스크 30GB pd-balanced, 전용 노드 SA `echo-dev-customer-gke-node`(관제탑 노드 SA 와 같은 최소 5역할), surge 1 / unavailable 0.
- 출력 `customer_gke_cluster_name`·`customer_gke_cluster_endpoint`·`customer_subnet_cidr`(`contracts/gcp-outputs.md`).

## 5. 전환 순서

전제: 시작 시점 진입점 가중치 **aws 100 / gcp 0**, PgBouncer 두 개 백엔드 = A(A 가 쓰기 담당), 진행 중 이전 계획 없음. gcp 쪽으로 사용자 트래픽이 없는 상태에서만 바꾼다.

| # | 단계 | 담당 | 예상 |
|---|---|---|---|
| 0 | 준비: `terraform state pull > backup-<시각>.tfstate`(로컬, 커밋 금지) · 지금 값 기록(진입점 `/status`·`/weights`, echo-was gcp-seoul 환경 config, `DATA_SYNC_DATABASES`, B `pg_subscription`) | 동옥 · 지민 | 10분 |
| 1 | 새 클러스터 생성: tfvars `customer_gke_enabled = true` → `make plan CLOUD=gcp` 가 **10 add / 0 change / 0 destroy**(이 PR 의 `-target` plan 과 같음)인지 확인 → apply | 동옥 | 15분 |
| 1b | 애드온: `cluster-addons/gke` ingress-nginx(내부 LB, 가능하면 고정 내부 IP 예약) · cert-manager + Cloudflare 토큰 Secret + 와일드카드 인증서 READY · `cluster-addons/otel-collector/overlays/gcp` | 동옥 | 15분 |
| 2 | echo-was gcp-seoul 환경 `PATCH config` → `clusterName: echo-dev-customer-gke`(나머지 칸 그대로) → 접속 확인 CONNECTED(노드 수 1) | 지민 | 5분 |
| 3 | Postgres B 새 클러스터에 재구성(아래 6절, **도현 영역**) + 외부 LB 새 IP · echo-was 가 닿을 내부 LB(`echo-pg-internal`, 출발지 관제탑 파드 10.61.0.0/16) | 도현 | 30~45분 |
| 3b | echo-was `deploy/base.yaml` PR: `DATA_SYNC_DATABASES` gcp 값을 새 내부 LB IP 로(`sslmode=require` 그대로) → 병합·배포·`rollout restart` → 파드 env 확인 | 지민 | 15분 |
| 4 | 고객 앱 재배포: 서비스마다 gcp-seoul 환경에 같은 `commitSha` 배포 요청 → 새 클러스터에 네임스페이스·Deployment·Ingress, `{ns}-env` Secret 은 Secret Manager 참조로 다시 생성 → 환경별 주소 `/readyz` 200(VPC 안) | 지민 | 10분 |
| 4b | 컷오버 Job 교차 클러스터 권한: 새 클러스터 `echo-data` 에 `echo-cutover` Role + **User `echo-dev-cutover@…` RoleBinding**, 컷오버 GSA 에 endpoint 조회 권한(`container.clusterViewer` 또는 동등), Job 의 B 컨텍스트를 새 클러스터로 | 도현(매니페스트) · 동옥(IAM) | 20분 |
| 5 | 진입점 업스트림 전환: tfvars `entrypoint_upstreams.gcp = "<새 ingress-nginx 내부 LB IP>:80"` → apply(메타데이터 제자리 갱신) → **b 먼저** `sudo google_metadata_script_runner startup`, `/status` gcp healthy 확인 → a(헬스체크 NLB 가 그동안 b 로 보냄) | 동옥 | 15분 |
| 6 | 검증(7절) | 지민 · 도현 | 20분 |
| 7 | 예전 네임스페이스 정리: 7절이 다 통과하고 **시연(11/8)이 끝날 때까지 유지**한 뒤 팀 합의로 `echo-dev-gke` 의 `demo-*`·`ingress-nginx`·`cert-manager`·`echo-data`(PVC 포함, 먼저 `pg_dump` 보관)·`echo-otel` 정리. 이후 관제탑 풀 `node_min_count` 2 → 1 검토 | 동옥 · 도현 | 15분 |

합계 ≈ **2.5~3시간**(1·1b 는 병렬 준비 가능). 사용자 트래픽 영향: 5단계 VM 재기동 때 진입점 하나씩(NLB 페일오버 3.8초 실측) 외에는 없음.

## 6. Postgres B 재구성 (도현 담당 — 필요한 단계만)

1. 새 클러스터에 `replication/k8s/gcp-seoul/{00,10,20,30}` 적용(`__A_HOST__` = A NLB), `echo-pg-secret` 은 지금 B 와 같은 계정(`app_rw`·`repl_user`·`pgbouncer_auth`·`echo_monitor`)·TLS 자체 서명.
2. **복제 슬롯 이름 충돌**: A 에는 지금 B 의 슬롯 `echo_sub` 가 있다. 새 B 가 같은 이름으로 `subscribe.sh` 하면 실패한다. 선택지 — (a) 지금 B 에서 `DROP SUBSCRIPTION echo_sub`(A 슬롯 삭제) 뒤 새 B 에 `echo_sub` 생성(copy_data, 스크립트·echo-was 설정 이름 유지 — **권장**), (b) 새 이름(`echo_sub_b2`) — 스크립트·`DATA_SYNC_DATABASES` 이름도 바꿔야 함. (a) 를 하면 지금 B 는 멈춘 사본이 되므로 롤백은 재구독(초기 복사 몇 분)이다. 어느 쪽인지 도현 결정.
3. `ops-table.sh`(echo_ops.cutover_runs)·`monitor-user.sh`(echo_monitor) 를 새 B 에도. 비밀번호는 Secret Manager 값 그대로.
4. 외부 LB 새 IP → `cutover.sh`·`rollback.sh` 의 `B_HOST`, 리허설 기록·`design-infra.md` 5절 주소 갱신. 내부 LB(`echo-pg-internal`) → 5절 3b.
5. 확인: A `pg_stat_replication` 에 `echo_sub` streaming, 새 B `pg_subscription` enabled, `verify.sh` 누락 0·중복 0, 두 PgBouncer 백엔드 = A.

## 7. 검증 (완료 기준)

- [ ] `terraform plan` 10 add / 0 change / 0 destroy, apply 뒤 `make plan` No changes
- [ ] echo-was gcp-seoul 환경 CONNECTED, 보안 매트릭스 **BLOCKED 0 유지**(전환 전후 비교)
- [ ] 서비스 상세: aws SERVING 100 / gcp STANDBY 0, 같은 `imageDigest`
- [ ] 진입점 `/status` `upstreams.gcp.address` = 새 IP, `healthy ≥ 1`, `/counters` gcp `hosts ≥ 1`
- [ ] 복제: A→새 B streaming, `DATA_SYNC_CHECK` 가 새 내부 LB 로 lag 읽음
- [ ] 운영 이전 1회 aws→gcp→aws(부하 켜고) 실패 요청 0, 데이터 확인 통과
- [ ] 컷오버 Job 리허설 1회(새 B) 누락 0·중복 0
- [ ] 관제탑 `echo-was` 파드 재시작 0(이 작업으로 관제탑이 흔들리지 않았음)

## 8. 롤백

| 단계에서 실패 | 되돌리기 | 시간 |
|---|---|---|
| 1·1b | tfvars `customer_gke_enabled = false` → plan 이 **고객 자원 10 destroy 만** 보이는지 확인 → apply. state 는 0단계 백업 + GCS 버전 관리 | 10분 |
| 2·4 | 환경 `PATCH config` `clusterName: echo-dev-gke` 로 되돌림 → 예전 네임스페이스가 그대로 있어 재배포 불필요(필요하면 같은 commitSha 재배포) | 5분 |
| 3·3b | `DATA_SYNC_DATABASES` 원래 값 PR · B 는 6절 (a) 였으면 예전 B 에 `subscribe.sh` 재구독, (b) 였으면 새 구독만 DROP | 15~30분 |
| 5 | tfvars `entrypoint_upstreams.gcp = "10.60.0.8:80"` → apply → b·a 순 startup 재실행 | 10분 |
| 전체 | 예전 네임스페이스·LB(10.60.0.8, <GCP_PG_LB_IP>)를 **7단계 전까지 지우지 않는다** — 위 네 줄만으로 원상 | 30~45분 |

## 9. 비용 (목표 ≈ $4/일 이하) — 공개 가격 근사, 청구서로 미검증

| 항목 | 일 비용(USD) |
|---|---|
| 클러스터 관리 수수료(존 클러스터 $0.10/h, 무료 크레딧은 `echo-dev-gke` 가 이미 씀) | ≈ 2.40 |
| e2-standard-2 ×1(서울) | ≈ 2.0~2.1 |
| 부팅 디스크 30GB pd-balanced | ≈ 0.1 |
| 새 내부 LB(`echo-pg-internal`) 1개 추가(ingress-nginx·pg 외부 LB 는 옮김이라 예전 것 지우면 상쇄) | ≈ 0.6 |
| **새로 드는 합** | **≈ 5.1** (목표 초과) |
| 7단계 뒤 관제탑 풀 2 → 1대 | −2.0 |
| **순증** | **≈ 3.1** |

옮기는 동안(4~7단계 사이) 두 클러스터 비용이 겹친다. 순증을 목표 안에 넣으려면 7단계(관제탑 1대로 줄이기)까지 가야 한다 — 관제탑 1대면 노드 교체 때 관제탑이 잠깐 멈추므로 동옥·지민이 같이 정한다. 대안: 고객 풀 Spot(≈ −1.4/일, 대신 선점 시 Postgres B 이동).

## 10. 위험

1. **Postgres B 재구성 중 복제 단절**(슬롯 이름 충돌·초기 복사) — A 쓰기 담당 상태에서만, 이전·컷오버 계획 없을 때. 6절 (a)/(b) 를 먼저 정한다.
2. **echo-was 데이터 확인 주소**가 클러스터 안 DNS라 3b 를 빼먹으면 다음 이전이 `METRICS_UNAVAILABLE` 로 롤백된다. 3b 를 4·5 보다 먼저 끝낸다.
3. **컷오버 Job 권한**: 지금은 같은 클러스터 RBAC 만이라 교차 클러스터 접근(4b)이 없으면 컷오버가 실패한다. 프로젝트 역할 추가가 `cutover.tf` 의 "프로젝트 역할 없음" 원칙과 부딪힌다 → 동옥·도현 합의.
4. 진입점 VM 재기동 순간 모든 고객 요청 영향 — b → a 순서와 NLB 로 3.8초 수준(실측 근거 `docs/rehearsals/2026-11-06-entry-failover.md`).
5. 비용 순증은 7단계까지 가야 목표 안(9절).
6. GKE 1.36.4+ 에서 `remove_default_node_pool` 이 deprecated 경고(기존 `gke.tf` 와 같은 모양으로 맞춤, 동작은 같음).

## 11. 하지 않는 것

- 관제탑 클러스터·`network.tf`·기존 방화벽 변경, 관제탑 GCLB·`api.echoport.uk`
- echo-was 실행기 권한 축소(`container.developer` 프로젝트 전체 → 클러스터별) — #24 후속
- AWS·온프레 환경
