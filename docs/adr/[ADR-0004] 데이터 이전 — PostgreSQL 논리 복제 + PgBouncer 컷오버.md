* **날짜:** 2026-11-03
* **작성자:** 이도현
* **상태:** 제안됨 (구현 착수 기준)

## 1. Context (배경)

11/1·11/2 회의에서 재난 시나리오가 **AWS 도쿄(Primary, A) → GCP 서울(Standby, B)**로 확정됐다. 이전 엔진의 핵심은 데이터 이동이다(인프라 이동은 Terraform). 관리 대상 앱(이슈 #4)은 **웹앱 + PostgreSQL**이고, 데이터 대조용 "순번 쓰기 엔드포인트"가 있다.

데이터 이전 방식에 세 가지 선택지가 있었다.

| 안 | 방식 | 평가 |
| --- | --- | --- |
| A | Debezium CDC (별도 캡처 → Redis/스트림) | 이기종 sink용이라 과하다. 같은 Postgres A→B 이전에 이중 구축. **기각** |
| B | 동기 요청 큐 (Kafka, 요청 시점에 큐잉) | 앱이 dual-write/큐를 거쳐야 해 침습적이고 앱에 결합된다. 100% 정합성은 재난에서 불가(팀 합의). **기각** |
| C | PostgreSQL 네이티브 논리 복제 + 컷오버 | A→B로 살아있는 복제본을 만들고, 컷오버 때만 짧게 쓰기를 멈춘다. 앱 비침습·네이티브. **채택** |

이전은 "같은 DBMS를 A에서 B로 옮겨 붙이는" 일이다. PostgreSQL 논리 복제(Logical Replication, publication/subscription)가 바로 이 일을 위해 있는 기능이다.

## 2. Decision (결정)

**데이터 이전은 PostgreSQL 네이티브 논리 복제로 하고, 컷오버는 PgBouncer로 짧게 쓰기를 멈췄다 넘긴다.**

### 소스 DB는 클러스터 안 self-managed PostgreSQL

- A(도쿄 EKS)·B(서울 GKE) 클러스터 안에 Postgres를 직접 띄운다. Managed(RDS/Cloud SQL) 대신 self-managed라, `wal_level=logical`·복제 슬롯·복제 유저를 완전히 제어하고 cross-cloud subscription이 간단하다. lock-in 탈출 서사와도 맞는다.

### 논리 복제 뼈대

- **A(원본):** `wal_level=logical`, `CREATE PUBLICATION`(대상 테이블), 복제 슬롯·복제 유저.
- **B(대상):** 초기 데이터 복사 후 `CREATE SUBSCRIPTION`으로 A에 붙어 변경을 지속 반영한다.
- B는 "계속 반영되는 최신 사본"이 된다. 복제 지연(Replication Lag)만큼 뒤처지고, 그 지연이 곧 RPO다.

### 컷오버는 PgBouncer로 (쓰기 정지 → 따라잡기 → 전환)

앱은 DB에 직접이 아니라 **PgBouncer**(커넥션 풀·프록시)로 접속한다. 컷오버 순서는 이렇다.

```
1) PgBouncer PAUSE        → A로의 쓰기를 잠깐 멈춘다 (드레인)
2) 복제 지연 0 대기         → B가 A를 따라잡을 때까지 (≤ 1초, NFR-03)
3) 시퀀스 맞춤             → B의 시퀀스를 max(PK)+여유로 setval
4) B 승격 · 접속 repoint    → PgBouncer 백엔드를 B로 바꾼다
5) PgBouncer RESUME       → 이제 쓰기가 B로 간다
```

쓰기 정지 시간 = 1~4 구간이다. 이 값을 **측정해서 그대로 공개**한다(완료 기준).

### 시퀀스 맞춤 (논리 복제의 함정)

논리 복제는 행 데이터(INSERT/UPDATE/DELETE)는 옮기지만 **시퀀스와 DDL은 옮기지 않는다**. 그래서 컷오버 직후 B에서 새 INSERT가 이미 복제된 PK와 충돌할 수 있다. 막으려면 컷오버 전에 B의 시퀀스를 `setval(seq, (SELECT max(id) FROM t) + 여유)`로 원본보다 앞세운다.

### 검증은 순번 쓰기로 (누락 0 · 중복 0)

- #4 앱의 순번 쓰기 엔드포인트가 단조 증가 번호를 계속 쓴다(#10의 10 rps 부하).
- 컷오버 전후로 A·B의 순번을 대조해 **누락 0·중복 0**을 확인한다. 컷오버 복제 지연 ≤ 1초(NFR-03)도 측정한다.

### 롤백·복구는 역방향 복제 (#8)

- 컷오버(A→B) 후 **역방향 복제 B→A**를 세워 A를 fallback으로 살려 둔다.
- 장애 주입 시 헬스체크 폴링/수동 버튼/오류율 문턱으로 판단해, 같은 컷오버 절차로 **60초 안에 A로 100% 복귀**한다(NFR-05). 상세는 #8.

### 백업은 별도 트랙 (#14)

이전(라이브 복제)과 백업(내구 복구 재료)은 다르다. 백업은 **base backup + 연속 WAL 로그(PITR)**로 간다. `pg_receivewal`로 WAL을 object storage에 실시간 스트리밍하면, 사본과 원본의 차이를 로그로 계속 메워 gap을 초 단위로 줄인다. "그냥 복사"가 아니다. 이 방식이면 **Debezium은 필요 없다**(ADR-0003은 이 결정으로 대체된다 — 별도 정리).

## 3. Consequences (결과 및 영향)

### 🟢 장점

- **앱을 건드리지 않는다.** 논리 복제는 DB 레벨이라 앱 코드 수정이 없다.
- **네이티브라 단순하다.** Debezium·Kafka 같은 추가 컴포넌트 없이 Postgres 기능만으로 된다.
- **컷오버 쓰기 정지가 짧다.** 복제가 거의 따라온 상태에서 PgBouncer로 잠깐만 멈춘다.
- **검증이 명확하다.** 순번 대조로 누락·중복을 숫자로 증명한다.
- **되돌릴 수 있다.** 역방향 복제로 A를 살려 둬 60초 복귀가 가능하다.

### 🔴 단점 / 개선안

- **RPO가 0이 아니다.** 비동기 복제라 컷오버 직전 몇 초가 빠질 수 있다. 컷오버 때 쓰기를 멈춰 그 창을 0으로 만들지만, 재난(갑자기 끊김)에는 쓰기 정지를 못 하므로 마지막 지연분이 유실될 수 있다. 측정·공개로 정직하게 다룬다.
- **시퀀스·DDL은 수동이다.** 논리 복제가 안 옮기므로 시퀀스 맞춤을 절차에 넣어야 하고, 스키마 변경 중 이전은 피한다.
- **대용량 초기 복사 부담.** 테이블이 크면 초기 `copy_data`가 오래 걸린다. 데모 규모에선 작게 유지한다.
- **cross-cloud 복제 경로가 필요하다.** A(도쿄)→B(서울) 연결이 있어야 한다. 공개 엔드포인트 + TLS + 방화벽 허용, 또는 VPN. CIDR 비중복은 이미 지켜져 있다(architecture.md).
- **self-managed 운영 부담.** 클러스터 안 Postgres를 우리가 운영한다. 데모 범위라 감당 가능하되, 운영이면 Managed가 편하다.

## 4. 참고자료

### 내부 문서

* [ADR-0001](<./[ADR-0001] 데이터 정합성 — 복제 시점이 아니라 복구 기준점으로.md>) — 비동기·RPO>0·failover=promote·검증 원칙. 이 ADR이 그 원칙을 Postgres 논리 복제로 구체화한다.
* [ADR-0003](<./[ADR-0003] CDC 캡처 — 직접 구현 대신 Debezium Server 도입.md>) — Debezium 도입 결정. 이전을 논리 복제로 가면서 **대체된다**(별도 정리 예정).
* GitHub 이슈: #4(대상 앱·PostgreSQL), **#7(논리 복제 + 컷오버)**, #8(롤백·역방향 복제), #10(측정·부하), #14(백업 CDC 이벤트 — 재정의 필요).
* `docs/architecture.md`(서동옥) — AWS Primary 구조와 DR 3단계. 데이터 복제·전환이 "이도현" 몫으로 지정됨.

### 외부 자료

* [PostgreSQL Logical Replication][pg-logical] — publication/subscription. 시퀀스·DDL 미복제가 공식 문서에 명시.
* [PgBouncer PAUSE/RESUME][pgbouncer] — 컷오버 때 커넥션을 멈췄다 재개하는 근거.
* [Continuous Archiving and PITR][pg-pitr] — base backup + 연속 WAL. 백업 트랙(#14)의 근거.

[pg-logical]: https://www.postgresql.org/docs/current/logical-replication.html
[pgbouncer]: https://www.pgbouncer.org/usage.html
[pg-pitr]: https://www.postgresql.org/docs/current/continuous-archiving.html
