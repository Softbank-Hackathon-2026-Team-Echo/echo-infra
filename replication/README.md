# #7 PostgreSQL 논리 복제 + PgBouncer 컷오버 — 로컬 PoC

[SPEC](../specs/infra-7-postgres-logical-replication-cutover.md) · [ADR-0004](../docs/adr/[ADR-0004] 데이터 이전 — PostgreSQL 논리 복제 + PgBouncer 컷오버.md)

이전 메커니즘을 **로컬에서 먼저 증명**한다(목업 우선 → 실제 연결). Docker로 Postgres 두 개(A=도쿄 역할, B=서울 역할)와 PgBouncer를 띄우고, 논리 복제 → 무손실 컷오버 → 검증까지 한 줄기로 돌린다.

## 무엇을 증명하나

- A→B 네이티브 논리 복제가 된다.
- PgBouncer로 **쓰기를 잠깐 멈췄다** B로 넘기면 **누락 0·중복 0**이다(#7 완료 기준).
- 컷오버 **쓰기 정지 시간**을 숫자로 뽑는다.
- 논리 복제가 안 옮기는 **시퀀스를 맞춰** 컷오버 후 PK 충돌이 없다.

## 검증 결과 (로컬 실행 2026-11-03)

실제로 돌려 확인했다.

- ✅ A→B 논리 복제 즉시 반영.
- ✅ 동시 쓰기(고빈도) 중 컷오버 → **최종 500행, n 1~500 연속, 누락 0 · 중복 0**. 컷오버는 `max(n)=79` 시점에 끼어들었고 쓰기는 B 로 끊김 없이 이어졌다.
- ✅ 시퀀스 맞춤 동작 (컷오버 후 B 의 새 `id` 가 `max(id)+1000` 부터, PK 충돌 없음).
- ✅ PgBouncer A→B repoint (`PAUSE`→`RELOAD`→`RESUME`) 동작, edoburu 이미지가 마운트 `.ini` 를 읽음.
- ✅ **쓰기 정지 시간 ≈ 0.30s**(두 번 실행 0.321s·0.299s). 초기 PoC 의 8.86s 는 각 단계를 `docker compose exec`(컨테이너 기동 ≈0.5~1s)로 따로 호출한 **오케스트레이션 오버헤드**였다. 임계 구간(PAUSE→RESUME)을 **pg_a 안 단일 exec** 로 모아 각 단계를 로컬 도커 네트워크 psql(ms)로 돌리고, 시간도 컨테이너 안 시계로 재니 실제 정지 창이 드러났다. 내역: PAUSE 드레인 ~0.04s · B 따라잡기 ~0.07s · (시퀀스·repoint·RESUME) ~0.19s.
- ✅ **컷오버 시점 복제 지연 ≈ 0.07~0.09s ≤ 1s (NFR-03)** — PAUSE 후 B 가 A 를 따라잡는 데 걸린 시간.

> 이 숫자는 로컬 docker 1호스트의 값이다. 실제 도쿄↔서울 cross-cloud 에서는 PAUSE→RESUME 창 자체는 비슷하되 "B 따라잡기"가 RTT·복제 지연만큼 늘 수 있다. 실제 연결 단계에서 다시 측정한다(SPEC "실제 연결").

## 구성

```
writer ──▶ PgBouncer(6432) ──▶ pg_a (55441)  ──논리 복제──▶  pg_b (55442)
                 │  컷오버 때 백엔드를 A→B 로 바꾼다 (PAUSE→RELOAD→RESUME)
                 └────────────────────────────────▶ pg_b
```

## 전제

- Docker Desktop (compose v2). 포트 55441·55442·6432 비어 있어야 함.
- 로컬 PoC라 **trust 인증**이다. 실제 배포는 TLS + Secrets Manager (ADR-0004).

## 실행

```bash
cd replication

bash scripts/up.sh            # A·B·PgBouncer 기동 + 논리 복제 설정

# 터미널 2개로:
bash scripts/writer.sh        # (터미널 A) 순번 쓰기 계속
# 몇 초 뒤, 다른 터미널에서:
bash scripts/cutover.sh       # 무손실 컷오버 (쓰기 정지 시간 출력)

bash scripts/verify.sh        # 누락·중복 대조 → "누락 0 · 중복 0" 기대
bash scripts/down.sh          # 정리 (pgbouncer → pg_a 복원)
```

writer는 Ctrl-C로 멈춘다. 컷오버 중 writer는 잠깐 멈췄다 B에서 이어 쓴다.

## 컷오버 절차 (cutover.sh)

1. **PAUSE** — PgBouncer가 A로의 쓰기를 멈추고 진행 중 트랜잭션을 비운다.
2. **따라잡기 대기** — B의 `max(n)`이 A와 같아질 때까지.
3. **시퀀스 맞춤** — B의 id 시퀀스를 `max(id)+1000`으로. (논리 복제는 시퀀스를 안 옮긴다)
4. **구독 중지** — B가 A로부터 더 받지 않게 `ALTER SUBSCRIPTION ... DISABLE`.
5. **repoint + RELOAD** — pgbouncer.ini의 `host=pg_a`를 `pg_b`로 바꾸고 RELOAD.
6. **RESUME** — 이제 쓰기가 B로 간다. 1~6 구간이 쓰기 정지 시간.

> **측정**: 1~6을 `pg_a` 안 **단일 `docker compose exec`** 로 돌리고 `t0`(PAUSE 직전)·`t1`(RESUME 직후)을 **컨테이너 안 시계**로 잰다. 단계마다 host 에서 `docker compose exec` 를 새로 띄우지 않으므로 컨테이너 기동 오버헤드가 빠지고, 실제 배포(직접 psql·영속 연결)의 쓰기 정지 창에 가까워진다. 이를 위해 compose 에서 `./pgbouncer` 를 `pg_a` 에도 `/pgbouncer-conf` 로 마운트했다(이 PoC 전용 배선. 실제 배포는 repoint 가 컷오버 API·설정 반영이라 이 마운트가 필요 없다).

## 이 PoC가 다루지 않는 것

- 실제 클러스터(EKS/GKE) 배포, cross-cloud 연결 (SPEC "실제 연결" 단계)
- 역방향 복제·롤백 (#8), 백업·PITR (#14), 트래픽 전환 (#6)

## 실제 배포로 갈 때 바뀌는 것

- `pg_a`·`pg_b` → 각 클러스터 안 self-managed PostgreSQL (StatefulSet)
- `CONNECTION` 문자열 → 도쿄↔서울 간 TLS 경로 + 복제 유저 비밀(Secrets Manager/Secret Manager)
- trust → scram 인증, PgBouncer `auth_query`
- 컷오버 트리거 → API 서버(#6)·진입점(#5)과 연결
