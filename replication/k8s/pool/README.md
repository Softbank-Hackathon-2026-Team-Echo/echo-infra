# 풀 계층 — PgBouncer 를 DB 와 떼어 낸다

- 상태: **매니페스트만. 운영에 적용하지 않았다**(11/7). 적용은 시연 뒤, 리허설과 함께(아래 "옮기는 순서")
- 작성: 이도현 · 근거: 노션 "플랫폼 · PgBouncer · DB 결합 구조 — 현재 상태와 분리안 (11/7)", 목표 그림 `echoport-architecture-target.drawio`

## 왜

지금 PgBouncer 는 DB 와 같은 네임스페이스(`echo-data`)에 있고 다섯 군데에서 DB 와 묶여 있다.

| 결합 | 지금 | 이 폴더에서 |
|---|---|---|
| 배치 | DB 와 같은 kustomization, 도쿄는 같은 노드 | 네임스페이스 `echo-pool`, 따로 apply·롤백 |
| 비밀 | DB 관리자 비밀이 든 `echo-pg-secret` 공유 | `echo-pgbouncer-secret`(app_rw 검증자 + 관리 계정)만 |
| 인증 | `auth_query` → DB 안 함수 `pgbouncer_user_lookup`·역할 `pgbouncer_auth` | `auth_file` + SCRAM pass-through. DB 함수·역할 불필요 |
| 쓰기 담당 주소 | 파드 안 ini 에 직접. 컷오버가 `sed` + RELOAD + ConfigMap patch | ini 에는 `db-writer` 이름만. 컷오버는 **Service `db-writer` 하나만** 바꾼다 |
| 네트워크 | 누구나 `echo-pg:5432` 직접 접속(PAUSE 우회) | DB 쪽 NetworkPolicy 로 PgBouncer·복제·관제탑만 |

목표: **쓰기 경로가 PgBouncer 하나**이고, **쓰기 담당은 표지판 하나**로 정해진다. 관제탑(echo-was)은 표지판을 바꾸는 제어만 하고 데이터 경로에 없다 → 관제탑이 죽어도 앱 → PgBouncer → DB 는 마지막 쓰기 담당으로 계속 돈다.

```text
 앱 ─▶ echo-pool/echo-pgbouncer ─▶ echo-pool/db-writer ─▶ 쓰기 담당 DB (도쿄 A 또는 서울 B)
        (클라우드마다 1개)          (ExternalName 표지판)
 관제탑 ┄┄ 컷오버 Job: PAUSE → db-writer 변경 → RECONNECT → RESUME   (데이터는 안 지나감)
 DB 끼리: 도쿄 A ══ 논리 복제 ══▶ 서울 B   (그대로)
```

## 파일

| 파일 | 내용 |
|---|---|
| `base/namespace.yaml` | `echo-pool` |
| `base/pgbouncer.yaml` | ConfigMap(ini, `host=db-writer`) · Service `echo-pgbouncer:6432` · Deployment(replica 1, `pgbouncer` + 관리 사이드카 `admin`) |
| `base/secret.example.yaml` | `echo-pgbouncer-secret` 만드는 법(손으로, 값은 저장소에 없음) |
| `aws-tokyo/db-writer.yaml` | 도쿄 표지판. 평소 `echo-pg.echo-data.svc.cluster.local`(A) |
| `gcp-seoul/db-writer.yaml` | 서울(고객 GKE) 표지판. 평소 `__A_HOST__`(A NLB DNS) |
| `migrate/echo-data-pgbouncer-alias.yaml` | 앱 주소를 안 바꾸고 넘기는 별칭(`echo-data/echo-pgbouncer` → `echo-pool/echo-pgbouncer`) |
| `../aws-tokyo/40-networkpolicy.yaml` · `../gcp-seoul/40-networkpolicy.yaml` | DB 5432 허용 목록(마지막 단계에 적용) |

PgBouncer 는 **1개**다. 보여 줄 것은 PgBouncer 가용성이 아니라 DB 정합성이고, 2개면 PAUSE 를 파드마다 보내야 해서 하나라도 빠지면 정지 창에 쓰기가 샌다.

## 옮기는 순서 (끊김 없이 — 옛 것을 옆에 둔 채)

전제: 쓰기 담당 A, 이전·컷오버 계획 없음, 시연 시간 밖.

```bash
EKS=aws-tokyo; GKE=gke_team-echo-final_asia-northeast3-a_echo-dev-customer-gke   # 서울 B 는 고객 클러스터(인프라 16)
cd replication/k8s/pool
```

1. **DNS 반영 시간 재기**(아래 절). 느리면 2단계 전에 방식을 바꾼다
2. **Secret**: 클러스터마다 `base/secret.example.yaml` 의 명령(app_rw 검증자는 A 에서 읽는다. A·B 검증자가 같은지 먼저 `../scripts/sync-role-verifiers.sh --check`)
3. **풀 계층 띄우기**(옛 PgBouncer 는 그대로, 앱은 아직 옛 쪽):
   ```bash
   kubectl --context $EKS apply -k aws-tokyo
   A_HOST=$(kubectl --context $EKS -n echo-data get svc echo-pg-external -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   kubectl kustomize gcp-seoul | sed "s|__A_HOST__|$A_HOST|" | kubectl --context $GKE apply -f -
   ```
   확인: 새 PgBouncer 로 `select 1` 과 쓰기 1건(두 클러스터 모두 A 에 기록되는지), `SHOW DATABASES` 의 host 가 db-writer
4. **앱을 새 풀로**: 클러스터마다 `migrate/echo-data-pgbouncer-alias.yaml`(파일 머리말의 delete → apply). 앱 DATABASE_URL 은 그대로
5. **컷오버 스크립트를 새 방식으로** + 리허설(cutover → rollback, 누락 0·중복 0, 쓰기 정지 시간 기록). 바뀌는 곳은 "스크립트·Job 변경" 절
6. **NetworkPolicy**: `../gcp-seoul/40-networkpolicy.yaml` 적용(GKE 는 바로 집행). 도쿄는 EKS 집행을 켠 뒤(`40-networkpolicy.yaml` 머리말). 적용 뒤 복제 streaming·관제탑 데이터 확인·앱 쓰기가 그대로인지 확인 → 각 kustomization 에 넣는다
7. **정리**: 두 NetworkPolicy 의 옛 PgBouncer 허용 줄 삭제, DB 의 `pgbouncer_auth` 역할·`pgbouncer_user_lookup` 함수 삭제(두 DB), `echo-pg-secret` 의 `PGB_AUTH_PASSWORD`·`userlist.txt` 키 삭제, `../{aws-tokyo,gcp-seoul}/20-pgbouncer.yaml` 을 kustomization 에서 뺌

되돌리기: 4단계까지는 별칭 Service 를 지우고 `../<클라우드>/20-pgbouncer.yaml` 을 다시 apply 하면 원상. 3단계 자원(`echo-pool` 네임스페이스)은 지워도 앱에 영향이 없다.

## 컷오버 때 쓰기 담당 바꾸기 (새 방식)

| | 도쿄 `db-writer` | 서울 `db-writer` |
|---|---|---|
| A 가 쓰기 담당(평소·롤백 뒤) | `echo-pg.echo-data.svc.cluster.local` | A NLB DNS |
| B 가 쓰기 담당(컷오버 뒤) | **B 의 DNS 이름** | `echo-pg.echo-data.svc.cluster.local` |

```bash
# 양쪽 PAUSE → 복제 따라잡기·구독 정리(지금과 같음) → 표지판 →  새 연결이 새 주소로 → RESUME
kubectl -n echo-pool patch svc db-writer --type merge -p '{"spec":{"externalName":"<새 주소>"}}'
kubectl -n echo-pool exec deploy/echo-pgbouncer -c admin -- psql -h 127.0.0.1 -p 6432 -U pgbouncer_admin -d pgbouncer -tAc "RECONNECT app;"
kubectl -n echo-pool exec deploy/echo-pgbouncer -c admin -- psql -h 127.0.0.1 -p 6432 -U pgbouncer_admin -d pgbouncer -tAc "RESUME app;"
```

**B 의 DNS 이름**: ExternalName 은 IP 를 받지 못한다. 서울 B 외부 LB(`echo-pg-external`)는 IP 만 있으므로 DNS 이름이 필요하다 — 예: Cloudflare **DNS only**(프록시 끔) A 레코드 `pg-b.<도메인>` → 외부 LB IP. 인증서는 자체 서명 + `sslmode=require` 라 이름이 바뀌어도 된다.

## DNS 반영 시간 (1단계에서 잰다)

ExternalName 은 DNS 별칭이라, 바꾼 뒤 옛 주소가 캐시에 남는 동안 PgBouncer 가 옛 DB 로 새 연결을 낼 수 있다.

- PgBouncer: `dns_max_ttl = 1` 로 1초
- 클러스터 DNS: EKS CoreDNS 는 kubernetes 플러그인 TTL(기본 5초)·`cache 30`, GKE kube-dns 는 보통 30초 — **잰 값으로 판단한다**
- 재는 법: 시험 네임스페이스에 ExternalName 하나 + 파드에서 1초마다 `getent hosts`, 바꾼 시각부터 새 주소가 나올 때까지
- RESUME 은 새 주소가 보인 뒤에. 길면 쓰기 정지가 그만큼 는다 → 길면(> 5초) ExternalName 대신 **selector 없는 Service + EndpointSlice(IP)** 로 바꾼다(ClusterIP 고정, 뒤 IP 만 교체 — DNS 를 거치지 않는다)

## 스크립트·Job 변경 (5단계, 아직 안 함)

- `scripts/common.sh`: `pgb()` 는 DB 파드(`PGB_AUTH_PASSWORD`) 대신 `echo-pool` 의 `admin` 사이드카로, `repoint()`·`persist_backend()` 는 ini `sed`·ConfigMap patch 대신 `db-writer` patch 로. `B_CTX` 기본값을 고객 클러스터로(#100 리뷰)
- 판정 "자기 쪽이 쓰기 담당": ini 의 host 대신 `db-writer` 의 `externalName` 을 읽는다
- 컷오버 Job RBAC(`cutover-job/manifests/echo-data-rbac.yaml`): `echo-pool` 에 Role(`services/db-writer` get·patch, `pods/exec` create — admin 사이드카) 추가. `echo-data` 의 ConfigMap patch 권한은 옛 PgBouncer 를 지운 뒤 뺀다
- 관제탑 구독(echo-was, 지민): 두 클러스터의 `db-writer.externalName` 과 PgBouncer `SHOW POOLS` 를 주기적으로 읽어 화면에 표시, **두 표지판이 서로 다른 DB 를 가리키면 경보**(split brain 감지). 필드 계약은 따로 맞춘다
