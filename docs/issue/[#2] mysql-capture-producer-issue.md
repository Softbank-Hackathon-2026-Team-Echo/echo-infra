# [#2][capture] Debezium Server로 온프레 MySQL을 캡처한다

> 선행: #1(이벤트 포맷 채택). [ADR-0003](<../adr/[ADR-0003] CDC 캡처 — 직접 구현 대신 Debezium Server 도입.md>), [ADR-0001](<../adr/[ADR-0001] 데이터 정합성 — 복제 시점이 아니라 복구 기준점으로.md>), [데이터 정의 1번](<../관리해야 하는 데이터 정의.md>) 참고.
> 이 이슈는 **온프레 self-managed MySQL 전용**이다. Managed DB는 provider-native 경로라 다루지 않는다.

### 배경

온프레 로컬 DB의 변경분을 플랫폼으로 흘려보내야 한다. 애플리케이션에 부하를 주는 트리거(Trigger) 대신, MySQL 내부 트랜젝션 로그인 Binlog를 읽어 변경만 뽑아낸다(CDC).

ADR-0003에서 이 캡처를 **직접 구현하지 않고 Debezium Server로** 하기로 정했다. 그래서 이 이슈는 Producer 코드를 짜는 게 아니라, **Debezium Server를 배포·설정해 Redis Stream에 이벤트가 뜨게** 만드는 일이다. 그림의 "Producer (자동 추가)" 박스가 이 Debezium Server 컨테이너다.

### 설계

**1. DB 전제를 맞춘다 (Debezium 요구사항)**

Debezium도 결국 Binlog를 읽으므로, 다음이 먼저 켜져 있어야 한다.

- Binlog를 **ROW 포맷 + GTID**로 켠다. (STATEMENT면 `NOW()`·`UUID()` 같은 비결정 쿼리가 재생 때 틀어진다. GTID로 "어디까지 읽었는지"를 정확히 끊는다.)
- **캡처 전용 계정**을 둔다. 최소 권한(`REPLICATION SLAVE`·`REPLICATION CLIENT`·대상 테이블 `SELECT`)만. 애플리케이션 계정과 섞지 않는다.

**2. Debezium Server를 컨테이너로 배포한다**

- 온프레 환경(Docker)에 Debezium Server 컨테이너를 자동 배치한다.
- **source = MySQL connector**, **sink = Redis Stream**으로 설정한다(YAML/properties). 코드가 아니라 설정이다.
- 안정판 **Debezium 3.6** 기준. (Debezium Server는 Java 21+ 이미지)

**3. offset은 Redis offset backing store로 둔다**

- Debezium이 "어디까지 읽었는지"(GTID)를 Redis에 저장하게 한다. 재시작하면 마지막 offset부터 이어 읽는다.
- **주의(DBZ-9190):** 설정했는데도 in-memory로 도는 사례가 있다. 배포 후 로그로 실제 Redis offset store가 적용됐는지 확인한다.

**4. 초기 snapshot은 Debezium에 맡긴다**

- 처음 붙을 때 Debezium이 consistent snapshot을 떠서 복제본을 시드하고, 이후 Binlog 스트리밍으로 넘어간다. 우리가 따로 초기 덤프를 만들지 않는다.

**5. 이벤트 포맷은 그대로 받는다**

- Debezium envelope(`before`·`after`·`op`·`source.gtid`·`ts_ms`)를 Redis Stream으로 받는다. 변환 없이 #1에서 정한 "우리가 쓰는 필드"로 매핑만 한다.

### 작업

- MySQL Binlog(ROW + GTID) 설정과 캡처 계정 생성 절차를 문서화한다(runbook).
- Debezium Server 배포 매니페스트 + 설정(MySQL source + Redis Stream sink + Redis offset store).
- 온프레 환경에 자동 배치되게 배선한다.

### 완료 조건

- 테스트 DB에 INSERT/UPDATE/DELETE를 넣으면 Redis Stream에 Debezium 이벤트가 순서대로 올라온다.
- Debezium Server를 재시작하면 마지막 GTID offset부터 이어 읽는다(앞부분을 다시 보내지 않는다). 로그로 Redis offset store 적용을 확인했다.
- 처음 붙을 때 초기 snapshot이 흘러나온다.
- 캡처 계정이 애플리케이션 계정과 분리되어 있다.

### 이번에 하지 않는 것

- Consumer 쪽 적용(#3).
- Base Snapshot·Binlog 백업 저장(#4). Debezium의 snapshot은 시드용이지 백업 아카이브가 아니다.
- Managed DB 캡처(provider-native 경로).
