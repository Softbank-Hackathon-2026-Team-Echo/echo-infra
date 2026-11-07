# 보안 매트릭스 점검 — C-TLS-2 내부 구간 암호화 · C-IAM-1 실행 신원 범위 (2026-11-08)

> 관련: 이슈 #134, PR #135. 시연 보안 화면의 IAM·암호화 칸 근거입니다.

## 점검 (11/8 01:20~01:45 KST, 읽기 전용)

실제 환경에서 읽기 전용 명령으로 확인했습니다. 설정 변경은 없습니다(아래 「오늘 조치」 제외). 공인 IP·호스트 이름은 가렸습니다.

### ① C-TLS-2 내부 구간 암호화

판정 기준: 네트워크를 건너는 구간은 TLS 여야 PASS. TLS 이지만 서버 인증서를 검증하지 않거나, 같은 클러스터 안에서 평문이면 WARN. 공용 인터넷을 평문으로 건너면 FAIL.

| 환경 | 구간 | 상태 | 판정 | 근거 |
|---|---|---|---|---|
| aws-tokyo | 진입점(Envoy, GCP 서울) → 앱(도쿄 ALB) | HTTP 80 평문, 공용 인터넷 | **FAIL** | 진입점 업스트림 `aws = <ALB>:80` (gcp/dev tfvars). weights-api 가 만드는 Envoy 클러스터에 `transport_socket`(TLS) 없음 (`entrypoint/weights-api/app.py` render_clusters) |
| aws-tokyo | 앱 → PgBouncer | 평문(클러스터 안) | WARN | 앱 `DATABASE_URL` 에 `sslmode` 없음, PgBouncer `client_tls_*` 설정 없음 (live ConfigMap `echo-pool/echo-pgbouncer-ini`) |
| aws-tokyo | PgBouncer → PostgreSQL A | TLS | PASS | live ConfigMap `server_tls_sslmode = require` |
| aws-tokyo | 복제 A → 서울 B (`echo_sub`) | TLSv1.3, 서버 인증서 검증 없음 | WARN | A `pg_stat_ssl`: `walsender echo_sub repl_user ssl=true TLSv1.3`. 구독 `sslmode=require`(verify 아님). A `pg_hba` 마지막 줄 `host all all all scram-sha-256` 이라 비TLS 로그인도 허용 |
| gcp-seoul | 진입점 → 앱(고객 GKE ingress 내부 LB) | HTTP 80, 같은 VPC 안 | WARN | 업스트림 `gcp = <내부 LB>:80`. 앱 계층 평문, VPC 내부 구간 |
| gcp-seoul | 앱 → PgBouncer / PgBouncer → B | 평문(클러스터 안) / TLS | WARN / PASS | aws-tokyo 와 같은 구성 (live ConfigMap 동일, 앱 `DATABASE_URL` sslmode 없음) |
| gcp-seoul | 복제 서울 B → 온프레 `gcpcopy` | TLSv1.3, 서버 인증서 검증 없음 | WARN | B `pg_stat_ssl`: `walsender echo_gcp_onprem_sub ssl=true TLSv1.3`. 온프레 구독 `sslmode=require`. B `pg_hba` 도 비TLS 허용 |
| onprem | 손님 → 온프레 앱 | Cloudflare 터널(암호화) → 노드 안 HTTP | PASS | cloudflared 터널, 인바운드 포트 없음. 진입점 → 온프레 갈래는 아직 없음(#103) |
| onprem | 앱 → PgBouncer → demo-db | 평문(한 노드 안) | WARN | 앱 `DATABASE_URL` sslmode 없음, demo-pgbouncer TLS 설정 없음 |
| onprem | 복제 온프레 → GCP B2·AWS B2 | TLSv1.3, 비TLS 거부 | PASS | demo-db `pg_stat_ssl`: `echo_onprem_sub`·`echo_onprem_sub_aws` 둘 다 `ssl=true TLSv1.3`. `pg_hba`: `hostnossl all repl_onprem all reject`, `hostssl demo repl_onprem all scram-sha-256` |

환경별 요약: **aws-tokyo FAIL**(진입점 → ALB 평문), **gcp-seoul WARN**, **onprem WARN**.

참고: 손님 → 진입점 앞단은 Cloudflare Flexible 모드라 Cloudflare → 진입점도 HTTP 80 입니다(`docs/manual-resources.md`). 이 칸(C-TLS-2)의 범위 밖이라 판정에 넣지 않았습니다.

### ② C-IAM-1 실행 신원 범위

| 환경 | 실행 신원 | 권한 | 판정 | 근거 |
|---|---|---|---|---|
| aws-tokyo | 앱 파드 | 클라우드 권한 없음 | PASS | `demo-y6cz3jrc/app` 은 default SA, IRSA 주석 없음, Pod Identity 연결은 kube-system 의 EBS CSI·LBC 뿐 (`aws eks list-pod-identity-associations`), RoleBinding 없음 |
| aws-tokyo | 컷오버 Job (`echo-dev-cutover`) | `eks:DescribeCluster` + 쿠버네티스 그룹 `echo-cutover`(echo-data Role) | PASS | 역할 인라인 `eks-describe` 만, 신뢰 주체 `accounts.google.com`(컷오버 GSA 고정). EKS access entry 에 정책 없음, 그룹만 |
| aws-tokyo | 관제(echo-was) 실행기 (`echo-dev-executor`) | EKS 클러스터 관리자 | **WARN** | access entry 정책 `AmazonEKSClusterAdminPolicy`(cluster 범위). 기능상 필요하지만 최소는 아님 |
| aws-tokyo | EKS 노드 역할 | `AmazonSSMManagedInstanceCore` 포함 | WARN | 이 정책의 `ssm:GetParameter` 가 계정 전체. 노드 IMDS hop limit 1 이라 일반 파드는 못 빌림, hostNetwork 파드는 가능 |
| gcp-seoul | 앱 파드 | 클라우드 권한 없음 | PASS | 고객 GKE `demo-y6cz3jrc/app` default KSA, `iam.gke.io/gcp-service-account` 주석 없음, RoleBinding 없음 |
| gcp-seoul | 컷오버 GSA (`echo-dev-cutover`) | `container.clusterViewer` + echo-data Role | PASS | project IAM `container.clusterViewer` 하나, WI 바인딩 `[echo-ops/echo-cutover]` 하나 |
| gcp-seoul | echo-was GSA (`echo-dev-echo-was`) | 프로젝트 전체 `container.developer`, 조건부 `secretmanager.admin` | **WARN** | project IAM. 컷오버 Role 보다 넓어 Job 경계를 우회할 수 있음(`replication/cutover-job/README.md` 에도 기록) |
| gcp-seoul | GKE 노드 SA | 로그·지표·AR 읽기 | PASS | `artifactregistry.reader`, `logging.logWriter`, `monitoring.*`, `stackdriver.resourceMetadata.writer` |
| gcp-seoul | AI 샌드박스 (`echo-sandbox-runner`) | 모델 호출 사용자 정의 역할 + 자기 비밀값 접근 | PASS | project IAM 은 `echoSandboxModelInvoker` 하나, 별도 VPC(IAP 22 만 인바운드) |
| onprem | 앱 파드 | 쿠버네티스·클라우드 권한 없음 | PASS | `demo-y6cz3jrc/app` default SA, 네임스페이스 RoleBinding 은 `echo-app-deployer → echo-executor` 하나 |
| onprem | echo-was 실행기 SA (`echo-system/echo-executor`) | 앱 네임스페이스 생성·배포 | PASS(오늘 조치 후) | VAP 2개: 네임스페이스·RoleBinding 제한, 앱 파드 privileged·host 네임스페이스·hostPath 금지(서버 dry-run 으로 거부 확인) |
| onprem | 기기 EC2 역할 (`echo-onprem-demo-host`) | SSM 에이전트 + 자기 접두사 파라미터 | PASS(오늘 조치 후) | `simulate-principal-policy`: 진입점 가중치 토큰 `explicitDeny`, 자기 터널 자격 `allowed`. IMDS hop limit 1 |

조직 밖 접근: GCP 프로젝트 IAM 에 `allUsers`·`allAuthenticatedUsers` 없음. 사람 계정은 팀원 5명뿐. AWS 역할 신뢰 주체는 AWS 서비스, GitHub OIDC(저장소 고정), `accounts.google.com`(우리 GSA 고정)뿐이고 다른 AWS 계정 주체는 없습니다.

환경별 요약: **aws-tokyo WARN**(echo-was 실행기 클러스터 관리자, 노드 역할 SSM 범위), **gcp-seoul WARN**(echo-was GSA 프로젝트 전체 `container.developer`), **onprem PASS**.

### 오늘 조치 (PR #135, 머지·적용 완료)

보안 감사에서 실제 환경으로 확인된 온프레 문제 두 가지를 막았습니다.
- 앱 네임스페이스 파드의 노드 권한(privileged·hostNetwork·hostPath 등)을 VAP 로 금지
- 기기 IMDS hop limit 2 → 1, 기기 역할의 다른 SSM 파라미터 읽기 명시 거부

### 남은 일 (시연 뒤)

- 진입점 → ALB 를 HTTPS 로 (ALB 443·ACM 은 이미 있음, Envoy 클러스터에 TLS 추가)
- 복제·PgBouncer 를 `verify-full` 로, A/B 에 `hostnossl ... reject`
- echo-was 실행 신원을 네임스페이스 범위로 좁히기 (#24 후속)
