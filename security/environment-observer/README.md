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

WAS 어댑터는 현재 ClusterAccessProvider 및 worker의 workload 자격을 재사용한다.
호출은 읽기 전용이지만 이것이 기존 실행기의 넓은 권한이나 신원 분리를 해결하지는 않는다.
권한 템플릿은 아직 바인딩하지 않았다. 독립 읽기 신원 적용/실효권한 확인은 #24 인수에 남는다.
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
