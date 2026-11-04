# 인프라·이전 엔진 7.1: DR 실제 적용 — 서울 B · cross-cloud 복제 · TLS + 리허설 1회

- 상태: 진행
- 확인일: 2026-11-04
- 노션 태스크: https://app.notion.com/p/40d8bee9ada481b1a913da48ddacc3b1
- GitHub 이슈: echo-infra #32 `[인프라·이전 엔진 7.1] DR 실제 적용: 서울 B · cross-cloud 복제 · TLS + 리허설 1회`
- 저장소: `echo-infra` · 구현 위치 `replication/k8s/`
- 담당: 서동옥(이슈 · B · 구독 · 리허설) · 이도현(도쿄 A 적용 · 이 SPEC)
- 근거: [SPEC infra-7](infra-7-postgres-logical-replication-cutover.md) · [SPEC infra-8](infra-8-rollback-reverse-replication.md) · [ADR-0004](../docs/adr/[ADR-0004] 데이터 이전 — PostgreSQL 논리 복제 + PgBouncer 컷오버.md) · PR #27(배선 코드)

## 1. 목표

infra-7·8 에서 로컬로 검증한 논리 복제·컷오버·롤백을 **실제 두 클러스터(EKS 도쿄 A → GKE 서울 B)** 에서 한 바퀴 돌린다. 클라우드 사이 통로를 열고, `rehearsal.sh` 1회로 **쓰기 정지 시간 · 누락 0 · 중복 0 · 복귀 시간**을 실측해 `replication/k8s/rehearsals/` 에 남긴다. 1차 기능 F8(데이터 동기화)·F9(롤백).

## 2. 현재 맥락과 확인된 사실

- **클라우드 간 통로 = 공인 L4 LB + 상대 NAT IP /32 만 허용 + TLS.** VPN·전용선은 두지 않는다(#27, 11/3 플랫폼 아키텍처 그림). Cloudflare Tunnel 은 온프레 전용이다(#20·#36).
- 도쿄 A (EKS `echo-dev-eks`, ns `echo-data`, 11/4 이도현 직접 조회)
  - `echo-pg-0`·`echo-pgbouncer` Running. `ssl=on`(자체 서명 `CN=echo-pg-a`), `listen_addresses=*`.
  - 발행 `echo_pub` = `app` DB, `FOR ALL TABLES`. `repl_user`(REPLICATION) 있음.
  - pg_hba 마지막 줄 `host all all all scram-sha-256` → NLB 경유 접속을 비밀번호로 받는다.
  - PgBouncer ini = emptyDir(패치 적용). `repoint` 의 `sed -i` + `RELOAD` 동작 확인.
  - AWS Load Balancer Controller 실행 중.
  - **NLB 적용(11/4 이도현)**: `echo-pg-external` → `echo-dev-pg-a-cb5bc23aab2d0c23.elb.ap-northeast-1.amazonaws.com:5432`. `active`, 대상(ip) healthy, 보안 그룹 5432 인바운드 = `34.64.211.218/32` 하나, 로컬 PC(허용 밖) 접속 차단 확인. `preserve_client_ip=false` 라 Postgres 에는 NLB 내부 IP 로 보인다.
  - `app` DB 에 **테이블 없음** — 시연 앱이 아직 이 DB 를 쓰지 않는다.
- 서울 B (GKE `echo-dev-gke`, 서동옥 11/4 02:10 구축, 직접 조회 안 함)
  - Postgres 17.11 + TLS + PgBouncer. 지금은 PgBouncer 가 B 자신을 본다.
  - 역방향용 LB `echo-pg-external` `34.22.85.222:5432` ← AWS NAT `18.180.171.76/32` 만.
- 시연 앱(echo-demo-app) 스키마 = `demo.seq_write`(`sql/schema.sql`). `subscribe.sh` 가 같은 DDL 을 B 에 선반영한다.
- 논리 복제는 시퀀스·DDL 을 옮기지 않는다. 시퀀스는 `cutover.sh`·`rollback.sh` 가 `demo.seq_write` 기준으로 맞춘다.

## 3. 범위

### 포함

- 도쿄 A 외부 노출 NLB(`aws-tokyo/30-expose.yaml`) 적용과 허용 목록 확인.
- B PgBouncer repoint, `subscribe.sh`(정방향 구독), `lag.sh` 확인.
- demo-app `DATABASE_URL` 을 각 환경 PgBouncer 로.
- `rehearsal.sh` 1회(컷오버 → 롤백) + `verify.sh` 대조, 결과 파일.
- echo-was DataSyncChecker 용 `echo_monitor`(pg_monitor 역할) 계정 전달.

### 제외

- 컷오버를 echo-was 이전 흐름에서 자동 실행(`DbCutoverExecutor`) — 김지민 합의 뒤.
- 정합성 대조의 흐름 안 자동 실행 (#12), 결과 자동 기록 (#10).
- 인증서 검증(`verify-full`) — 자체 서명 유지, 해커톤 범위 한계(#23).
- 온프레 복제본 · PITR (#14).

## 4. 설계 (단계)

```
[EKS 도쿄 A]                                         [GKE 서울 B]
 echo-pg ── NLB echo-dev-pg-a :5432 ◀── TLS ── GCP NAT 34.64.211.218 ── echo-pg (echo_sub 구독)
        └─ 허용: 34.64.211.218/32                                          echo-pgbouncer → A(컷오버 전)
 echo-pg ── AWS NAT 18.180.171.76 ── TLS ──▶ LB 34.22.85.222 :5432 ── echo-pg (롤백용 역방향)
```

| # | 단계 | 담당 | 확인 |
|---|---|---|---|
| 1 | `kubectl apply -k aws-tokyo` (NLB 포함, 라벨 `echo/managed-by=dohyun-manual` 은 파일에 있음) — ✅ 11/4 | 이도현 | NLB `active`, DNS 발급, `diff -k` 빈 출력 |
| 2 | NLB 보안 그룹 확인 | 이도현 | 5432 인바운드 = `34.64.211.218/32` 하나 |
| 3 | 허용 목록 밖(로컬 PC)에서 접속 시도 | 이도현 | **연결 실패가 정상** |
| 4 | NLB DNS 를 #32 에 기록, `repl_user` 비밀을 B Secret 으로 전달 | 이도현 → 서동옥 | 비밀은 이슈·Slack 공개 채널에 쓰지 않는다 |
| 5 | B 에서 A 접속 시험 `psql "host=<NLB> dbname=app user=repl_user sslmode=require"` | 서동옥 | TLS 접속 성공 |
| 6 | B PgBouncer → A repoint, `A_HOST=<NLB> subscribe.sh` | 서동옥 | `lag.sh` streaming, 지연 수 초 이내 |
| 7 | demo-app `DATABASE_URL` → 각 환경 `echo-pgbouncer.echo-data.svc.cluster.local:6432/app` (`{ns}-env` Secret) | 서동옥 · 김지민 | A `app` DB 에 `demo.seq_write` 쓰기 확인 |
| 8 | `rehearsal.sh` → `verify.sh` | 서동옥 + 이도현 | `rehearsals/` 에 결과, 누락 0 · 중복 0 |
| 9 | `echo_monitor` 생성 → GCP Secret Manager | 서동옥 | echo-was `DATA_SYNC_*` 설정은 김지민과 |

- **되돌리기**: `kubectl -n echo-data delete svc echo-pg-external` → NLB 도 함께 지워진다. 다른 리소스는 건드리지 않는다.
- **비용**: NLB 시간 요금 + AWS→GCP 전송 요금. AWS 크레딧(11/20 종료) 안에서 쓴다.

## 5. 완료 조건 (#32 와 같음)

- 도쿄 A → 서울 B 논리 복제가 두 클러스터에서 돈다(TLS, 허용 목록이 상대 NAT /32 하나인 LB).
- `rehearsal.sh` 1회: 컷오버·롤백 시각, 쓰기 정지 시간, 누락 0 · 중복 0 표가 `replication/k8s/rehearsals/` 에 남는다.
- demo-app `DATABASE_URL` 이 각 환경의 PgBouncer 를 본다.
- echo-was DataSyncChecker 용 복제 지연 SQL 과 `echo_monitor` 계정이 전달된다.

## 6. 위험 · 확인할 것

- **GCP NAT 가정**: B Postgres(구독)와 echo-was 가 `34.64.211.218` 로 나간다는 전제. 틀리면 5번에서 접속이 막힌다 → 허용 목록을 고친다.
- **앱이 PgBouncer 를 안 거치면** PAUSE 로 쓰기가 멈추지 않아 무손실이 깨진다. 7번 전에는 리허설을 `writer.sh`(스크립트 쓰기)로만 한다.
- **스키마 변경**: 논리 복제는 DDL 을 옮기지 않는다. 시연 앱 스키마가 `demo.seq_write` 밖으로 늘면 `subscribe.sh`·시퀀스 맞춤·`verify.sh` 를 같이 고친다.
- `common.sh` 의 `PATH`(Homebrew gcloud)·`B_CTX` 는 실행자 PC 기준이다. Windows 에서는 따로 맞춘다.

## 7. 이번에 하지 않는 것

- 자동 컷오버 · 자동 롤백 · 오류율 롤백 (#8 · echo-was).
- 정합성 대조 자동화 · 측정 자동 기록 (#12 · #10).
- 인증서 검증 · 사설 경로(VPN).
- 온프레 복제본 · 백업 PITR (#14).
