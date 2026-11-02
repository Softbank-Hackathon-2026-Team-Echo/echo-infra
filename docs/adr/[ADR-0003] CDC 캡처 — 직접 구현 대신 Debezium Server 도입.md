* **날짜:** 2026-11-02
* **작성자:** 이도현
* **상태:** 제안됨 (구현 착수 기준)

## 1. Context (배경)

데이터 정의 문서와 ADR-0001은 온프레미스 DB를 CDC(Change Data Capture)로 캡처해 복제·백업한다고 정했다. 다만 "캡처를 직접 구현할지, Debezium 같은 오픈소스를 쓸지"는 판단 항목으로 남겨뒀다. 이제 구현을 시작하므로 이 문서에서 정한다.

직접 구현하면 다음을 전부 우리가 만들어야 한다.

* DB별 트랜잭션 로그 파싱 (MySQL Binlog, PostgreSQL WAL, …)
* 복제본을 시드하는 초기 consistent snapshot
* "어디까지 읽었는지" offset 추적과 재시작 이어받기
* DB 종류가 늘 때마다 새 캡처 구현

이건 작업량이 크고, 이미 성숙한 선례(Debezium)가 푸는 문제다.

## 2. Decision (결정)

**CDC 캡처는 Debezium Server + Redis Stream sink로 한다.** 직접 Producer를 구현하지 않는다.

### 왜 Debezium Server인가

Debezium은 세 가지 실행 형태가 있다. 우리는 **Debezium Server(단독 실행)**를 쓴다.

| 형태 | 채택 | 이유 |
| --- | --- | --- |
| **Debezium Server** | ✅ | Kafka 없이 컨테이너 하나로 실행. Redis Stream 등 다양한 sink 지원. 우리 언어와 무관 |
| Kafka Connect | ❌ | Kafka 인프라가 따라와서 과하다 |
| Embedded Engine | ❌ | Java 전용. Consumer를 다른 언어로 짜면 안 맞는다 |

### 구체적으로 정한 것

* **Redis Stream sink를 쓴다.** ADR-0001에서 전송 통로로 Redis Stream을 쓰기로 했는데, Debezium Server에 Redis Stream으로 바로 내보내는 sink가 있다. 그래서 중간 변환 없이 붙는다.
* **이벤트 포맷은 Debezium envelope를 채택한다.** `before` / `after` / `op`(c·u·d·r) / `source`(gtid 포함) / `ts_ms` 구조를 그대로 받는다. 우리가 메시지 형식을 새로 설계하지 않는다(#1 범위가 줄어든다).
* **offset은 Debezium이 관리한다.** Redis offset backing store로 Redis에 저장한다. 재시작하면 마지막 offset부터 이어 읽는다.
* **초기 snapshot은 Debezium이 한다.** 처음 붙을 때 consistent snapshot을 떠서 복제본을 시드하고, 이후 로그 스트리밍으로 넘어간다. 우리 설계의 "처음 한 번 덤프"를 Debezium이 대신한다.
* **온프레미스의 캡처 모듈 = Debezium Server 컨테이너**다. 아키텍처 도식의 "Producer (자동 추가)" 박스가 이 컨테이너다. 대상 환경에 자동으로 배치한다.

### Debezium이 하지 않는 것 (계속 우리 몫)

캡처만 Debezium으로 대체된다. 아래는 그대로 우리가 만든다.

* **Consumer의 멱등 적용 (#3).** Debezium은 이벤트를 Redis에 넣는 데까지다. 그걸 타겟 복제본 DB에 멱등하게 반영하는 건 우리다. (Debezium JDBC sink는 Kafka Connect에서만 돌아 우리 경로엔 안 쓴다.)
* **Object Storage 백업 (#4).** Debezium의 snapshot은 스트림 시드용이지 복구용 백업 아카이브가 아니다. 풀 복구 재료는 별도로 둔다.
* **Checkpoint·카탈로그·Failover 오케스트레이션 (#5·#6).** 서비스 단위 상위 로직이다.
* **복구/promote 측 어댑터 (#7).** DB별 "기준점까지 맞춰 기동"은 캡처와 별개라 우리가 만든다.

## 3. Consequences (결과 및 영향)

### 🟢 장점

* **작업량이 크게 준다.** 가장 어려운 Binlog 파싱·초기 snapshot·offset 관리를 Debezium이 가져간다.
* **멀티 DBMS가 거의 공짜다.** MySQL·PostgreSQL·Oracle·SQL Server·MongoDB 커넥터가 이미 있다. 캡처 측 어댑터(#7)를 DB마다 새로 짜지 않아도 된다.
* **설계와 정합한다.** Redis Stream sink라 ADR-0001의 전송 통로에 그대로 얹힌다.
* **검증된 구현이다.** 프로덕션 선례가 많아 엣지 케이스(스키마 변경, 재시작, 재연결)가 이미 다뤄져 있다.

### 🔴 단점 / 개선안

* **외부 의존성이 생긴다.** Debezium Server는 Java 21+ 컨테이너다. 우리가 코드를 안 짜도 이 컨테이너를 배포·운영·버전관리해야 한다.
* **이벤트 포맷이 Debezium에 종속된다.** envelope 구조를 우리가 받는다. Consumer가 이 포맷에 묶이므로, 캡처를 다른 것으로 바꾸면 Consumer 매핑을 고쳐야 한다. (완화: Consumer에서 Debezium 포맷 → 내부 공통 형태로 한 번 정규화해 격리한다.)
* **offset 설정에 함정이 있다.** Redis offset backing store가 설정돼도 in-memory로 도는 사례(DBZ-9190)가 보고됐다. 배포 후 로그로 실제 적용 여부를 확인해야 한다.
* **Managed DB는 여전히 별도다.** RDS·Cloud SQL은 Debezium 커넥터로 붙을 수도 있지만 권한·플러그인 제약이 있어, 경우에 따라 provider-native(DMS 등)가 낫다. 이 ADR은 온프레 self-managed DB 기준이다.
* **버전 선택.** 안정판 Debezium 3.6(2026) 기준으로 간다. 3.7은 프리뷰라 쓰지 않는다.

## 4. 참고자료

### 내부 문서

* [ADR-0001](<./[ADR-0001] 데이터 정합성 — 복제 시점이 아니라 복구 기준점으로.md>) — CDC·Redis 전송 통로·offset·멱등 적용을 전제한 상위 설계.
* `docs/관리해야 하는 데이터 정의.md` — 1번(온프레 DB CDC)에서 "직접 구현 vs Debezium"을 판단 항목으로 남긴 곳. 이 ADR이 그 판단을 닫는다.
* 영향 이슈: #1(이벤트 포맷 채택으로 축소), #2(Debezium Server 배포·설정으로 재작성), #7(캡처는 Debezium, 복구 측만 어댑터).

### 외부 자료

* [Debezium Server 공식 문서][dbz-server] — 단독 실행과 sink 종류(Redis Stream 포함).
* [Debezium Releases][dbz-releases] — 3.6 안정판, 3.7 프리뷰. Debezium Server는 Java 21+.
* [Debezium Server + Redis Stream 튜토리얼 (DZone)][dbz-redis] — source connector + Redis sink 설정 예시.
* [DBZ-9190][dbz-9190] — Redis offset backing store가 적용 안 되고 in-memory로 도는 사례. 배포 후 로그 확인 근거.

[dbz-server]: https://debezium.io/documentation/reference/operations/debezium-server.html
[dbz-releases]: https://debezium.io/releases
[dbz-redis]: https://dzone.com/articles/debezium-server-with-postgresql-and-redis-stream
[dbz-9190]: https://issues.redhat.com/browse/DBZ-9190
