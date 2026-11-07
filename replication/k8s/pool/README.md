# 풀 계층 — PgBouncer 를 DB 와 떼어 낸다

- 상태: 매니페스트 · 컷오버 스크립트(풀 방식) · Job 권한 · 시험(11/7). **운영 적용은 아래 "옮기는 순서"대로**
- 작성: 이도현 · 근거: 노션 "플랫폼 · PgBouncer · DB 결합 구조 — 현재 상태와 분리안 (11/7)", 목표 그림 `echoport-architecture-target.drawio`

## 왜

지금 PgBouncer 는 DB 와 같은 네임스페이스(`echo-data`)에 있고 다섯 군데에서 DB 와 묶여 있다.

| 결합 | 지금 | 이 폴더에서 |
|---|---|---|
| 배치 | DB 와 같은 kustomization, 도쿄는 같은 노드 | 네임스페이스 `echo-pool`, 따로 apply·롤백 |
| 비밀 | DB 관리자 비밀이 든 `echo-pg-secret` 공유 | `echo-pgbouncer-secret`(app_rw 검증자 + 관리 계정)만 |
| 인증 | `auth_query` → DB 안 함수 `pgbouncer_user_lookup`·역할 `pgbouncer_auth` | `auth_file` + SCRAM pass-through. DB 함수·역할 불필요 |
| 쓰기 담당 주소 | 파드 안 ini 에 직접. 컷오버가 `sed` + RELOAD + ConfigMap patch | ini 에는 표지판 `db-writer.echo-data` 만. 컷오버는 **표지판 뒤**만 바꾼다 |
| 관리 콘솔 | DB 파드 env 의 `PGB_AUTH_PASSWORD` 로 | PgBouncer 파드의 `admin` 사이드카 |
| 네트워크 | 누구나 `echo-pg:5432` 직접 접속(PAUSE 우회) | DB 쪽 NetworkPolicy 로 PgBouncer·복제·관제탑만 |

목표: **쓰기 경로가 PgBouncer 하나**이고, **쓰기 담당은 표지판 하나**로 정해진다. 관제탑(echo-was)은 표지판을 바꾸는 제어(컷오버 Job)만 하고 데이터 경로에 없다 → 관제탑이 죽어도 앱 → PgBouncer → DB 는 마지막 쓰기 담당으로 계속 돈다.

```text
 앱 ─▶ echo-pool/echo-pgbouncer ─▶ echo-data/db-writer (ClusterIP 고정) ─▶ 쓰기 담당 DB
        (클라우드마다 1개)            ├ 자기 쪽이 쓰기 담당: selector app=echo-pg
                                       └ 상대 쪽이 쓰기 담당: EndpointSlice db-writer-manual(상대 LB IP)
 관제탑 ┄┄ 컷오버 Job: PAUSE → 표지판 → 반영 대기 → RECONNECT → RESUME   (데이터는 안 지나감)
 DB 끼리: 도쿄 A ══ 논리 복제 ══▶ 서울 B   (그대로)
```

PgBouncer 는 **1개**다. 보여 줄 것은 PgBouncer 가용성이 아니라 DB 정합성이고, 2개면 PAUSE 를 파드마다 보내야 해서 하나라도 빠지면 정지 창에 쓰기가 샌다.

### 왜 ExternalName 이 아닌가 (운영 측정 11/7)

표지판을 DNS 별칭(ExternalName)으로 두면 바꾼 뒤 클러스터 DNS 캐시만큼 옛 DB 를 본다. 운영 시험 네임스페이스에서 잰 값:

| 방식 | 도쿄 EKS(CoreDNS) | 서울 고객 GKE(kube-dns) |
|---|---|---|
| ExternalName 바꾸기 | 3.2초 | **30.1초** |
| ClusterIP 뒤 바꾸기(selector ↔ EndpointSlice), 명령이 끝난 뒤부터 | **1초 안**(4회) | **1초 안**(4회) |

(뒤 줄: 파드 안에서 0.2초마다 요청, 옛 쪽 응답 섞임 0 · 실패 0.) GKE 30초는 쓰기 정지에 그대로 더해지므로 **ClusterIP 고정 + 뒤만 바꾸기**를 쓴다. DNS 를 거치지 않는다. 반영 대기는 `WRITER_SETTLE`(기본 2초).

selector 를 빼는 것만으로는 부족하다(k3s 시험에서 발견): 컨트롤러가 만든 EndpointSlice 와 옛 Endpoints 객체가 남고, Endpoints 가 남으면 **미러링 컨트롤러가 자기 쪽 슬라이스를 다시 만든다** → 전환 뒤에도 쓰기가 옛 DB 로 갔다. `repoint` 는 selector 를 뺀 뒤 Endpoints `db-writer` 와 우리 것이 아닌 표지판 슬라이스를 지운다.
selector Service 는 같은 네임스페이스의 파드만 고르므로 표지판은 `echo-data` 에 둔다. EndpointSlice 는 IP 만 받으므로 도쿄 A NLB(DNS 이름)는 전환할 때 IP 로 푼다(NLB 의 AZ 별 IP 는 NLB 를 지우기 전까지 그대로).

## 시험

| 시험 | 무엇을 | 11/7 결과 |
|---|---|---|
| `tests/pool-test.sh` (k3s 1대, 매니페스트 그대로) | 인증(`auth_file` + SCRAM pass-through) · `common.sh` 의 `repoint` 그대로 쓴 전환(0.1초마다 쓰기 중) · 재시작 · NetworkPolicy | (아래 표) |
| `../scripts/tests/run.sh` (Postgres 2대 + 가짜 kubectl) | 컷오버·롤백·승격·재동기화 전체 시나리오. `POOL_SIDES="A B"` 면 풀 방식, `"A"` 면 섞인 상태 | (아래 표) |
| `../../cutover-job/tests/policy-test.sh` (k3s) | Job 권한: 표지판·EndpointSlice·`echo-pool` 관리 콘솔 허용, secrets·다른 Service 거부 | 56/56 |

- B 의 `app_rw` 검증자가 A 와 다르면 전환 뒤 로그인이 실패한다(첫 실행에서 확인) → 전환 전 `sync-role-verifiers.sh --check` 필수(preflight 가 확인)

## 파일

| 파일 | 내용 |
|---|---|
| `base/namespace.yaml` | `echo-pool` |
| `base/pgbouncer.yaml` | ConfigMap(ini, `host=db-writer.echo-data`) · Service `echo-pgbouncer:6432` · Deployment(replica 1, `pgbouncer` + 관리 사이드카 `admin`) |
| `base/secret.example.yaml` | `echo-pgbouncer-secret` 만드는 법(손으로, 값은 저장소에 없음) |
| `aws-tokyo/db-writer.yaml` | 도쿄 표지판(`echo-data`). 평소 selector → A |
| `gcp-seoul/db-writer.yaml` | 서울(고객 GKE) 표지판(`echo-data`). 평소 selector 없음 → 적용 뒤 `pool-point.sh B "$A_HOST"` |
| `migrate/echo-data-pgbouncer-alias.yaml` | 앱 주소를 안 바꾸고 넘기는 별칭(`echo-data/echo-pgbouncer` → `echo-pool/echo-pgbouncer`) |
| `../scripts/common.sh` | 풀 방식: `pool_mode` · `pgb`(admin 사이드카) · `repoint`(표지판) · `pgb_backend` · `persist_backend`(할 일 없음) |
| `../scripts/pool-point.sh` | 표지판을 손으로 맞춤(설치·복구) |
| `../../cutover-job/deploy/{aws-tokyo,gcp-seoul-customer}-pool` | Job 의 `echo-pool` 권한(관리 콘솔). `echo-data` 권한에 표지판·EndpointSlice 추가 |
| `../aws-tokyo/40-networkpolicy.yaml` · `../gcp-seoul/40-networkpolicy.yaml` | DB 5432 허용 목록(마지막 단계) |

## 풀 방식은 언제 켜지나

스크립트(사람·Job 모두)는 클러스터마다 고른다: **`echo-data/db-writer` 가 있고 옛 `echo-data/echo-pgbouncer` Deployment 가 없을 때만** 풀 방식. 그래서

- 3단계(새 풀을 옆에 띄움)까지는 앱이 옛 PgBouncer 를 쓰므로 스크립트도 옛 방식 그대로다
- 4단계에서 옛 Deployment 를 지우고 별칭으로 넘기는 순간 그 클러스터가 풀 방식이 된다
- 한 클러스터만 옮긴 상태(섞임)에서도 컷오버가 돈다(`run.sh` `POOL_SIDES="A"`)

Job 은 VAP 때문에 환경 변수를 더 받을 수 없어 이렇게 클러스터 상태로 고른다.

## 옮기는 순서 (끊김 없이 — 옛 것을 옆에 둔 채)

전제: 쓰기 담당 A, 이전·컷오버 계획 없음, 시연 시간 밖. 컷오버 이미지가 이 브랜치의 스크립트로 다시 빌드돼 있어야 한다(5단계 전).

```bash
EKS=aws-tokyo; GKE=gke_team-echo-final_asia-northeast3-a_echo-dev-customer-gke   # 서울 B 는 고객 클러스터(인프라 16)
cd replication/k8s
A_HOST=$(kubectl --context $EKS -n echo-data get svc echo-pg-external -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

1. **확인**: `scripts/sync-role-verifiers.sh --check`(A·B `app_rw` 검증자 같음), 복제 streaming
2. **Secret**: 클러스터마다 `pool/base/secret.example.yaml` 의 명령(app_rw 검증자는 A 에서 읽는다)
3. **풀 계층 띄우기**(옛 PgBouncer·앱은 그대로):
   ```bash
   kubectl --context $EKS apply -k pool/aws-tokyo
   kubectl --context $GKE apply -k pool/gcp-seoul
   POOL_FORCE=1 B_CTX=$GKE scripts/pool-point.sh B "$A_HOST"      # 서울 표지판 → A NLB IP
   kubectl --context $EKS apply -k ../cutover-job/deploy/aws-tokyo-pool
   kubectl --context $GKE apply -k ../cutover-job/deploy/gcp-seoul-customer-pool
   kubectl --context $EKS apply -k ../cutover-job/deploy/aws-tokyo           # echo-data Role 에 표지판·EndpointSlice 권한
   kubectl --context $GKE apply -k ../cutover-job/deploy/gcp-seoul-customer
   ```
   확인: 두 새 PgBouncer 로 `select inet_server_addr()` 가 A, 쓰기 1건이 A 에 기록
4. **앱을 새 풀로**(클러스터마다, `pool/migrate/echo-data-pgbouncer-alias.yaml` 머리말): 옛 Deployment·Service 삭제 → 별칭 apply. 이 순간부터 그 클러스터는 풀 방식. 확인: `scripts/preflight.sh`, 앱 쓰기
5. **리허설**: 컷오버 Job 으로 cutover → rollback(누락 0·중복 0, 쓰기 정지 기록)
6. **NetworkPolicy**: `../gcp-seoul/40-networkpolicy.yaml`(GKE 는 바로 집행). 도쿄는 EKS 집행을 켠 뒤. 적용 뒤 복제 streaming·관제탑 데이터 확인·앱 쓰기 확인 → 각 kustomization 에 넣는다
7. **정리**: NetworkPolicy 의 옛 PgBouncer 허용 줄, DB 의 `pgbouncer_auth`·`pgbouncer_user_lookup`, `echo-pg-secret` 의 `PGB_AUTH_PASSWORD`·`userlist.txt`, Job Role 의 ConfigMap 권한, `../{aws-tokyo,gcp-seoul}/20-pgbouncer.yaml`

되돌리기: 4단계 전에는 `echo-pool` 네임스페이스와 `echo-data/db-writer` 를 지우면 원상(앱 영향 없음). 4단계 뒤에는 별칭 Service 를 지우고 `../<클라우드>/20-pgbouncer.yaml` 을 다시 apply(옛 Deployment 가 생기면 스크립트도 옛 방식으로 돌아간다).

## 관제탑 구독 (echo-was, 다음 작업)

두 클러스터의 표지판(`pgb_backend` 와 같은 값: selector 면 자기 쪽, 아니면 `echo/writer-host`)과 PgBouncer `SHOW POOLS` 를 주기적으로 읽어 화면에 표시하고, **두 표지판이 서로 다른 DB 를 가리키면 경보**(split brain 감지). 필드 계약은 김지민과 맞춘다.
