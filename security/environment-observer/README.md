# 환경 보안 관측기 — WAS #131 / infra #23·#24

운영 배포 전 검토용입니다. 기존 kustomization·Terraform·클러스터에는 반영하지 않았습니다.

WAS `feat/sec-environment-evidence`가 C-IAM-1/C-TLS-2 자동 결과를 findings에 등록합니다.
이 폴더의 DB 관측기는 애플리케이션→PgBouncer, PgBouncer→DB, 복제 연결을 읽습니다.
진입점 `GET /security/transport?route=...`는 Envoy active cluster 설정과 실제 TLS 접속을 검사합니다.
공개 TLS(C-TLS-1) 검사기의 내부 IP 차단은 그대로입니다.

| 관측 | 자동 판정 | 확인되지 않는 범위 |
|---|---|---|
| Kubernetes Role/Binding·workload KSA | 범위 밖/wildcard/공용 신원 WARN, 명시 허용표와 일치 PASS | RBAC 외 authorizer·클라우드 권한은 별도 관측 필요 |
| AWS/GCP 정책·관리 역할 | 확인한 권한 항목 저장, 미조회/조건/전체 실효 권한 미입증 UNKNOWN | SCP·리소스별 정책·GCP deny/PAB 등; 전체 IAM 칸 PASS를 보장하지 않음 |
| Envoy→origin | 공용 평문 FAIL·사설 평문 WARN, CA/SAN/SNI+TLS≥1.2 접속 검증 PASS | SDS/조건부 socket/private CA 미지원 UNKNOWN |
| DB/PgBouncer 연결 | 실제 평문/구버전 TLS WARN | TLS 세션만으로 client verify-full을 증명할 수 없어 UNKNOWN; 접속 0건도 UNKNOWN |

관측 시각·고정 경로 ID·이유 코드만 ConfigMap에 보냅니다. 비밀번호·SQL·DB 주소·conninfo는 저장/로그하지 않습니다.
DB의 `monitor.sql`은 보안 정의자 함수로 필요한 집계만 노출합니다. 관측 로그인은 함수 실행만 받으며
pg_monitor/테이블 SELECT/쓰기/복제 권한을 받지 않습니다. PgBouncer 로그인은 `stats_users`이며
`admin_users`가 아닙니다. SHOW CLIENTS/SERVERS만 실행합니다.

## 적용 전 필요한 값과 순서

1. 데이터 담당: `transport_targets`에 실제 DB/user/application_name의 정확한 매핑을 넣고
   monitor LOGIN에 schema USAGE/function EXECUTE만 부여합니다. 계정 비밀은 별도 Secret으로 만듭니다.
   PgBouncer에도 통계 전용 사용자와 각 DB의 정확한 사용자/DB 명을 지정합니다.
2. 인프라 담당: 현재 AWS/GCP/onprem 각각의 DB·풀 경로를 확정합니다. 없는/휴지 상태 경로를
   정상으로 기록하지 않습니다. `targets.example.json`을 실제 경로 ID로 작성하고 revision을 올립니다.
   libpq 서비스 파일은 Secret `transport-observer-services`의 `pg_service.conf`에만 넣습니다.
   관측 연결도 sslmode=verify-full 및 신뢰 CA를 사용합니다. 실패 시 자격/SSL을 낮추지 않습니다.
3. 이미지 빌드 후 digest를 manifests.yaml에 넣고 ConfigMap targets를 준비합니다.
   observer SA는 지정 ConfigMap PATCH만 가능합니다. 신규 namespace의 DB/DNS/API egress,
   DB/풀 ingress는 정확한 포트·namespace에 한정합니다. CNI 미집행은 별도 블로커입니다.
4. API/worker에는 같은 WAS 프로필 JSON을 배포합니다. collector의 실제 신원에 reader-rbac 및
   cloud read 정책의 필요한 리소스만 바인딩합니다. 템플릿의 대체 문자열을 그대로 적용하지 않습니다.
   기존 executor broad role을 최소 권한 달성의 근거로 삼지 않습니다.
5. 진입점에는 WEIGHTS_TOKEN과 다른 SECURITY_READ_TOKEN을 넣습니다. 동일하면 관측 API는 503입니다.
   WAS는 고정 IP HTTPS 관리 origin + read-token 참조만 사용합니다. 기존 내부 HTTP 8080에 토큰을 보내지 않습니다.
   HTTPS 종단·신뢰 CA 제공 전에는 관측을 활성화하지 않습니다.
6. 최초 수집 후 3환경 findings·matrix/compare·이관 비저장 판정, 권한 거부·30분 만료·프로필 변경을 검증합니다.
   두 통제는 선택 통제이며 WARN/UNKNOWN만으로 이관을 차단하지 않습니다. 전체 보안 인수와 구분합니다.

## 시험

`python3 -B -m unittest discover -s security/environment-observer -v`
`python3 -B -m unittest discover -s entrypoint/weights-api -v`

[PgBouncer SHOW 명령](https://www.pgbouncer.org/usage.html),
[PostgreSQL pg_stat_ssl](https://www.postgresql.org/docs/17/monitoring-stats.html#MONITORING-PG-STAT-SSL-VIEW),
[Envoy config dump](https://www.envoyproxy.io/docs/envoy/latest/api-v3/admin/v3/config_dump.proto)를 기준으로 읽습니다.


## 최신 수동 점검·서비스 라우팅과의 관계

11/8 infra #134에서 수동6건 등록 완료(UNKNOWN0)·AWS TLS FAIL+예외가 보고됐다.
이 자동 수집기는 후속이다. 수동 FAIL을 삭제/덮어쓰지 않는다.
WAS 정책 버전 상승 시 수동6건·빌드·TLS·플랫폼·PRECHECK 증거 재생성 인수가 필요하다.
수집 OFF여도 정책 상승은 기존 증거에 영향을 주므로 시연 중 단독 배포하지 않는다.

서비스 라우팅 ON에서는 필수 route가 svc_<service UUID hex>_<environment UUID hex>다.
현재 등록표에 있는 cluster 한 개만 읽으며 legacy aws/gcp로 fallback하지 않는다.
기존 가중치·서비스 CAS revision·트래픽을 수정하지 않는다.
legacy 모드에는 기존 경로 이름과 query 없는 전체 관측을 허용한다.

feat/sec-observer-runtime은 전용 수집 workload와 자격 선택을 제공합니다.
실제 최소 권한 생성·바인딩/실효권한 인수는 아직 운영에 적용하지 않았습니다.
GCP 상위조직 읽기가 금지되면 그 누락을 UNKNOWN으로 유지한다.

## 재현 가능한 격리 시험

운영 자원은 사용하지 않는다. 테스트 이미지 두 개를 먼저 빌드한다.
실제 Envoy 시험은 임시 CA를 두 컨테이너의 시스템 신뢰 저장소에만 마운트하고
정상 인증서와 잘못된 hostname을 검사한다. 운영 신뢰를 낮추지 않는다.

```sh
docker build -t echo-secu131-weights:test entrypoint/weights-api
docker build -t echo-secu131-observer:test security/environment-observer
python3 entrypoint/weights-api/verify_envoy.py
# echo-secu131- 접두사의 전용 PG17 컨테이너(테스트 echo DB 사용자)가 있어야 한다.
python3 security/environment-observer/verify_postgres.py echo-secu131-final-pg
python3 security/environment-observer/verify_pool.py echo-secu131-final-pg
```

Envoy 시험은 실제 HTTP/TLS origin 트래픽, CA/SAN 검증, 잘못된 인증서 거절,
관측 전후 weights 불변·이후 서비스별 PUT 전환을 확인한다.
PG 시험은 집계 함수 실행·대상표 읽기/쓰기/권한 상승 거부,
PgBouncer 시험은 observer 이미지의 psql·SHOW CLIENTS/SERVERS와 stats 계정 PAUSE 거부다.
fixture 비밀번호는 폐기용 로컬 값이며 운영 Secret은 읽지 않는다.

## 전용 수집 runtime (feat/sec-observer-runtime)

WAS의 `python -m app.worker.environment_security`를 일반 배포 worker와 다른
GSA/KSA·AWS role·onprem token·WAS DB 로그인으로 실행합니다. 프로필의 `reader`가 없거나
실행기와 동일한 역할/토큰 참조면 수집에 실패하고 UNKNOWN을 기록합니다.
AWS/GCP에서는 metadata가 반환하는 실제 GSA 이메일도 프로필과 대조합니다.
WAS/API/worker/collector는 동일한 프로필 JSON을 받아야 판정 시 설정 지문이 맞습니다.

### 준비 순서와 필요한 출력

1. GCP dev의 `security_reader_enabled=true`가 별도 GSA, 제한 custom role,
   `echo-security/security-reader` KSA의 Workload Identity 바인딩을 준비합니다.
   기본 false이므로 기존 실행 신원은 그대로입니다. 출력은 이메일/고유 숫자 ID입니다.
   프로젝트 밖 folder/org 정책을 읽을 권한은 별도 정확한 상위 범위에 승인해야 합니다.
   미승인 상위 범위를 PASS로 간주하지 않습니다.
2. AWS dev의 `security_reader_google_service_account_id`에 그 숫자 ID를 지정합니다.
   실행기/컷오버 ID와 같으면 거부합니다. `security_reader_targets`에는 감사할 역할·
   부착 정책·EKS access-entry의 **정확한 ARN**을 넣습니다(와일드카드 금지).
   별도 역할은 DescribeCluster/지정 IAM·EKS 메타데이터 읽기와 `echo-security-reader`
   그룹 연결만 갖습니다. 기존 executor 정책은 변경하지 않습니다.
3. 각 감사 클러스터에 reader-rbac와 해당 환경의 reader-binding을 적용할 준비를 합니다.
   `reader-bindings.example.yaml`의 GKE GSA User/EKS Group/onprem KSA 중 해당 subject만
   남깁니다. onprem은 새로운 토큰을 발급·회전하고 배포용 토큰을 재사용하지 않습니다.
   읽기 역할에는 Secret 조회·exec·Job 생성·ConfigMap 쓰기·impersonation 권한이 없습니다.
   DB 관측기만 보호 ConfigMap 하나를 PATCH합니다.
4. WAS migration 이후 DB 소유자가 `collector-db.sql`을 적용하고 별도 LOGIN에 그 역할을 줍니다.
   로그인/비밀번호는 이 파일에 없습니다. 앱/배포 데이터 쓰기나 schema 소유권을 주지 않습니다.
   **환경 행 잠금 때문에 updated_at 한 열 UPDATE를 허용**합니다. findings INSERT와
   superseded_at/updated_at 변경은 증거 작성에 필요한 권한입니다.
   기존 공용 DB 권한이나 추가 role 상속이 있으면 먼저 제거·점검해야 합니다.
5. `collector.example.yaml`은 기본 suspend=true인 별도 CronJob입니다. 실제 WAS image digest,
   profiles ConfigMap, 전용 자격 Secret, CA ConfigMap을 채웁니다. UID1001/비루트,
   읽기 전용 rootfs, capabilities 없음, 최대600초, 중복 실행 방지를 적용했습니다.
   DB 관측기 manifests/monitor.sql/통계 로그인 구성도 함께 준비합니다.
6. `--preflight`와 기존 정책 증거 재확인, 권한/네트워크 점검을 마친 후 별도 운영 승인으로
   단발 수집→3환경 matrix/compare/배포·이관 회귀→스케줄 활성화 순서로 인수합니다.
   현재 브랜치 작업에서는 apply·운영 수집·main PR/병합을 하지 않았습니다.

### HTTPS 관측 관리 경로

`entrypoint/docker-compose.security.yml`은 **선택형 overlay**입니다.
기존 compose에 추가하면 read-only HTTPS proxy(8443)를 실행합니다.
`SECURITY_READ_TOKEN_FILE`, `SECURITY_TLS_CERT_FILE`, `SECURITY_TLS_KEY_FILE`에
운영자가 준비한 파일 경로를 지정하고 UID1001이 읽을 최소 파일 권한을 설정합니다.
토큰은 weights-api와 proxy에 같은 파일로 마운트되며 proxy에는 WEIGHTS_TOKEN이 없습니다.
기존 토큰과 같으면 weights-api가 관측을 거부합니다.
`SECURITY_BIND_IP` 기본값은 127.0.0.1이며 인수 때 접근을 허용한 사설 인터페이스로만 바꿉니다.
인증서 SAN은 WAS 프로필의 고정 IP와 일치해야 하고, CA를 collector에 마운트합니다.

proxy는 TLS1.2 이상, 인증된 GET /security/transport?route=... 한 경로만 전달합니다.
weights/서비스 변경 경로와 POST/PUT/PATCH/DELETE는 전달하지 않습니다.
redirect를 따르지 않고 응답 크기/연결 시간을 제한합니다.
같은 호스트의 compose 내부 네트워크에서 weights-api로 전달하는 마지막 hop은 HTTP입니다.
그 네트워크를 외부에 노출하지 않으며 기존 weights 관리포트의 운영 방화벽 정책은 유지합니다.
이 HTTPS 경로는 **관측 API 보호**이며 기존 공용 HTTP origin·DB peer 검증 누락을 고치는 설정은 아닙니다.

### 네트워크 인수

동옥/지민이 정확한 클러스터 API·AWS STS/IAM/EKS·Google IAM/Resource Manager/Container API·
WAS DB·사설 HTTPS 관측 IP/포트를, 도현이 DB/PgBouncer 관측 IP/포트를 제공해야 합니다.
그 출력으로 namespace CNI egress와 클라우드 방화벽을 좁혀야 하며 임의의 0.0.0.0/0
allow 정책은 이 브랜치에 넣지 않습니다. DNS와 workload metadata 경로도 별도로 필요합니다.
[GKE 공식 지침](https://docs.cloud.google.com/kubernetes-engine/docs/troubleshooting/authentication)에 따라
CNI 종류별 metadata 허용 대상을 선택합니다. 실제 CNI 통신 검증은 운영 인수에 남습니다.
AWS 읽기 권한의 리소스 범위는 [EKS 권한 표](https://docs.aws.amazon.com/service-authorization/latest/reference/list_eks.html)를 따릅니다.

### 추가 시험

- `python3 security/environment-observer/verify_rbac.py`: 전용 로컬 k3s 생성/정리.
  GKE User/EKS Group/KSA subject의 실제 GET/거부, observer PATCH-only 경계를 확인합니다.
  실제 클라우드 연합 인증을 대신하지 않습니다.
- `python3 -B -m unittest discover -s entrypoint/weights-api -v`: HTTPS 실제 소켓,
  CA/hostname/auth/쓰기·경로 거부 및 기존 서비스별 weights 회귀.
- AWS/GCP `tests/security-reader.tftest.hcl`: **mock provider + command=plan**으로 기본 OFF,
  신원 분리, 명시적 읽기 권한을 검사합니다. 클라우드 자원 생성이나 실제 IAM 인수는 아닙니다.
- WAS 전체 테스트는 `ECHO_INFRA_OBSERVER_DIR`로 collector-db.sql을 실제 PostgreSQL에 적용해
  2회 수집/이력 교체와 환경 config·기존 finding 판정·jobs·DELETE·schema 생성 거부를 확인합니다.
  `ECHO_INFRA_WEIGHTS_APP`로 HTTPS→수집→저장→matrix 및 기존 트래픽 HTTP 계약을 확인합니다.
