# 도쿄 A Postgres (Primary) — EKS 배포 1차안

[SPEC infra-7](../../../specs/infra-7-postgres-logical-replication-cutover.md) · [ADR-0004](../../../docs/adr/[ADR-0004]%20데이터%20이전%20—%20PostgreSQL%20논리%20복제%20+%20PgBouncer%20컷오버.md)

로컬 PoC(`replication/`)에서 검증한 메커니즘을 **실제 EKS(도쿄, `echo-dev-eks`)** 로 옮기는 첫 조각이다. 이번 범위는 **A 내부(ClusterIP)까지** — self-managed Postgres(publisher) + PgBouncer. B(서울) cross-cloud 연결·TLS·외부 노출은 다음 단계다.

> ⚠️ **이 매니페스트는 아직 실제 클러스터에 apply 해 검증하지 않았다.** 검토·적용용 1차안이다. apply 는 사람이, 공유 EKS 변경이므로 인프라 담당(서동옥) 확인 뒤에 한다(CLAUDE.md).

## 무엇이 들어있나

| 파일 | 내용 |
|---|---|
| `00-namespace.yaml` | `echo-data` 네임스페이스(이전 엔진 데이터 전용) |
| `secret.example.yaml` | **예시**. 실제 Secret 은 손으로 만든다(저장소에 비밀값 0건, NFR-17) |
| `10-postgres.yaml` | Postgres StatefulSet(`wal_level=logical`) + 헤드리스 Service + 초기화(계정·`echo_pub` 발행) |
| `20-pgbouncer.yaml` | PgBouncer Deployment + Service(앱 접속구 `echo-pgbouncer:6432`) + scram/auth_query 설정 |

## PoC 와 달라진 점 (실제 배포로 옮기며)

- `docker-compose` → **StatefulSet + PVC(`ebs-csi-default-sc`)**. 데이터는 EBS 볼륨에 영속. (클러스터 기본 SC 이름이 `gp3`가 아니라 `ebs-csi-default-sc` 임을 `kubectl get sc` 로 확인함)
- trust 인증 → **scram-sha-256 + PgBouncer `auth_query`**(`pgbouncer_auth` + `public.pgbouncer_user_lookup` SECURITY DEFINER).
- 비밀번호 → **수동 k8s Secret**(`echo-pg-secret`). 저장소엔 예시만.
- 발행 → `CREATE PUBLICATION echo_pub FOR ALL TABLES`(앱이 만드는 테이블을 모두 복제).

## 적용 절차 (사람이, 인프라 담당 확인 뒤)

```bash
export AWS_PROFILE=echo
aws eks update-kubeconfig --name echo-dev-eks --region ap-northeast-1

kubectl apply -f 00-namespace.yaml

# Secret 은 손으로 (secret.example.yaml 의 주석 참고, 값은 각자 생성)
SUPER=$(openssl rand -base64 24); APP=$(openssl rand -base64 24)
REPL=$(openssl rand -base64 24); PGB=$(openssl rand -base64 24)
kubectl create secret generic echo-pg-secret -n echo-data \
  --from-literal=POSTGRES_PASSWORD="$SUPER" \
  --from-literal=APP_PASSWORD="$APP" \
  --from-literal=REPL_PASSWORD="$REPL" \
  --from-literal=PGB_AUTH_PASSWORD="$PGB" \
  --from-literal=userlist.txt="\"pgbouncer_auth\" \"$PGB\""

kubectl apply -f 10-postgres.yaml
kubectl -n echo-data rollout status statefulset/echo-pg
kubectl apply -f 20-pgbouncer.yaml
kubectl -n echo-data rollout status deploy/echo-pgbouncer
```

## 검증 (apply 뒤 이걸로 확인해야 "동작"이라 말할 수 있다)

```bash
# 1) 논리 복제 켜졌나
kubectl -n echo-data exec echo-pg-0 -- psql -U postgres -d app -tAc "SHOW wal_level;"   # logical 기대

# 2) 발행·복제 유저 생겼나
kubectl -n echo-data exec echo-pg-0 -- psql -U postgres -d app -tAc \
  "SELECT pubname FROM pg_publication;"                                                  # echo_pub
kubectl -n echo-data exec echo-pg-0 -- psql -U postgres -d app -tAc \
  "SELECT rolname, rolreplication FROM pg_roles WHERE rolname IN ('app_rw','repl_user','pgbouncer_auth');"

# 3) 앱 경로(PgBouncer→Postgres, scram) 가 뚫리나 — app_rw 로 PgBouncer 를 통해 접속
kubectl -n echo-data run psql-probe --rm -it --restart=Never --image=postgres:17 -- \
  env PGPASSWORD="$APP" psql "host=echo-pgbouncer port=6432 dbname=app user=app_rw" -c "SELECT 1;"
```

누락·중복 대조 같은 무손실 검증은 B 를 붙이고 컷오버를 돌려야 가능하다(다음 단계).

## 다음 단계 (아직 안 함)

1. **A 외부 노출** — B 가 cross-cloud 로 `repl_user` 접속을 하도록 NLB(또는 사설 경로) + **TLS(서버 인증서, SAN=endpoint)** + 보안그룹 allowlist(GCP `nat_ip`).
2. **B(서울 GKE) 미러** — 같은 StatefulSet + `CREATE SUBSCRIPTION`(CONNECTION = A endpoint, `sslmode=verify-full`, 비밀은 Secret Manager).
3. **컷오버/롤백** — 로컬 `cutover.sh`·`rollback.sh` 의 단계(PAUSE→따라잡기→시퀀스 맞춤→repoint→RESUME)를 실제 PgBouncer(ConfigMap RELOAD)로 옮기고 cross-cloud 에서 재측정(NFR-03·05).
4. **hardening** — 이미지 digest 고정, 수동 Secret → Secrets Manager + External Secrets, 최소 권한, NetworkPolicy.
