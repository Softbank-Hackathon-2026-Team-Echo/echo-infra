# AGENTS.md

이 저장소의 규칙은 [CLAUDE.md](CLAUDE.md)와 [.claude/rules/](.claude/rules/)를 따른다. 작업 전에 CLAUDE.md 의 규칙 문서 표에 있는 문서(용어 사전·Terraform 규칙·Git 규칙)를 먼저 읽고, 충돌하면 용어 사전 > 코드 규칙 > 일반 관례 순으로 따른다.

---

# 데이터·이전 엔진 파트 (이도현) — 인수인계

이 파트의 작업을 이어받는 에이전트가 먼저 읽는다. 담당은 데이터 **이전(migration)·백업·롤백**이다. 인프라(Terraform·진입점)는 다른 담당(서동옥)이다.

## 이 파트가 무엇인가

Team Echo 멀티 클라우드 플랫폼의 **데이터 이전**을 맡는다. 재난 시나리오는 **AWS 도쿄(A, Primary) → GCP 서울(B, Standby)**로 확정됐다. 관리 대상 앱은 **PostgreSQL**이다(이슈 #4).

핵심 결정은 셋이다.

* **이전 = PostgreSQL 네이티브 논리 복제 + PgBouncer 컷오버**(ADR-0004, 이슈 #7). Debezium·Kafka 안 쓴다.
* **백업 = base backup + 연속 WAL(PITR)**(이슈 #14). 그냥 복사가 아니라 로그를 쌓아 gap을 줄인다.
* **롤백 = 역방향 복제 B→A + 60초 복귀**(이슈 #8).

복구는 "서비스를 대상 환경에서 다시 가동(Failover)"이지, DB를 과거로 되돌리는 게 아니다(ADR-0001).

## 작업 방식 (제일 중요)

* **되돌리기 비용 큰 결정은 ADR로 먼저.** `docs/adr/`. 구현에 결정을 묻지 않는다.
* **작업 단위는 SPEC.** `specs/infra-N-*.md`. 이슈 1개 = 브랜치 1개 = SPEC 1개(CLAUDE.md).
* **모호하면 먼저 질문한다.** 선택지만 늘어놓지 말고 근거 있는 추천안을 하나 낸다.
* **검증 안 한 걸 "동작한다"고 쓰지 않는다.** PoC는 실제로 돌려서 확인한다(#7은 돌려서 누락0·중복0 확인함).
* **커밋·push·PR 생성은 사람이 한다.** 에이전트는 변경만 남긴다.
* **외부·비용 반영은 확인받고.** `terraform apply`·`destroy`, GitHub 이슈 수정 같은 건 사용자 확인 뒤에.
* **다른 파트 결정은 대신 내리지 않는다.** DB 위치는 데이터, 트래픽 전환은 진입점(#5·#6), 이미지 복제는 빌드·배포(#3).

## 말투 (문서 쓸 때)

세션에서 맞춰온 문체다. 문서 종류마다 다르다.

* **ADR**: `날짜/작성자/상태` → `## 1. Context` → `## 2. Decision` → `## 3. Consequences`(🟢 장점 / 🔴 단점·개선안) → `## 4. 참고자료`. **평서체 `~다`**, 결론 먼저, 대안 검토는 표로, 영어 기술 용어는 그대로.
* **설명·아키텍처 문서**: **합니다체**, 쉬운 비유(예: Binlog=변경 일기장, Checkpoint=세이브 포인트), 단계별 서술. "너무 전문적이라 불친절"은 피한다. 용어 정리 섹션을 앞에 둔다.
* **직역하면 어색한 기술 용어는 영어 원문 + 괄호로 뜻**을 단다. 예: `멱등(Idempotent, 두 번 해도 결과가 같은)`.
* 팀 용어 사전(echo-was)·Terraform/Git 규칙(`.claude/rules/`)을 따른다. 커밋은 Conventional Commits.

## 지금 상태 (2026-11-03)

* 🟢 **완성·검증:** #7 논리 복제 + 컷오버 **로컬 PoC**(`replication/`). 실제로 돌려 **누락 0·중복 0**(500행, n 1~500 연속) 확인. 시퀀스 맞춤·PgBouncer repoint 동작. **쓰기 정지 시간 측정을 실제 PAUSE→RESUME 창으로 좁혀 ≈0.30s 확인**(초기 8.86s는 단계마다 `docker compose exec` 오버헤드 → 임계 구간을 단일 exec·컨테이너 시계로 측정). 컷오버 시점 복제 지연 ≈0.07s ≤ 1s(NFR-03).
* 🟢 **완성·검증:** #8 롤백 **로컬 PoC**(`reverse.sh`·`rollback.sh`). 역방향 복제 B→A(재동기화)·무손실 롤백 왕복(A→B→A) 돌려 **누락 0·중복 0**(n 1~211 연속) 확인. **복귀 시간 ≈0.46s ≤ 60s(NFR-05)**. 수동 트리거=스크립트, Notion 절차서(`docs/design/롤백 절차서 (B→A).md`) 작성. 재난(B 급사) 자동 감지·오류율 자동 롤백(Should)은 실제 연결 단계.
* 🟢 **문서:** ADR-0004(이전), ADR-0003(Debezium **대체됨**), ADR-0001(정합성)·0002(랜섬웨어). SPEC `infra-7`·`infra-8`·`infra-14`. GitHub #14를 PITR 기준으로 갱신함.
* 🔴 **남음:** 아래 순서.

## 남은 작업과 순서

1. **#7 실제 연결.** PoC(`replication/`)를 EKS/GKE 안 self-managed Postgres(StatefulSet)로 올리고, 도쿄↔서울 **cross-cloud TLS 경로**와 복제 유저 비밀(Secrets Manager/Secret Manager)을 붙인다. trust→scram·PgBouncer `auth_query`. **실제 cross-cloud 에서 PAUSE→RESUME 창과 "B 따라잡기"(RTT·복제 지연만큼 늘 수 있음)를 다시 측정**해 NFR-03(≤1s) 재확인. (로컬 측정 창 좁히기는 완료: ≈0.30s.) 실제 클러스터·apply 는 인프라 담당(서동옥) 확인 뒤.
2. **#8 실제 연결.** 역방향 복제·계획적(무손실) 롤백 로컬 PoC 완료(≈0.46s, 누락0·중복0, Notion 절차서). 남음: 실제 cross-cloud 에서 복귀 시간 재측정, **재난(B 급사) 자동 감지·장애 주입 복귀(RPO 기록)**, 헬스체크 폴링·오류율 자동 롤백(Should, #9·#10 연계).
3. **#14 백업.** `pg_basebackup` + `pg_receivewal` 연속 WAL → object storage, cross-cloud 사본, PITR 복구 + 검증.
4. **낡은 문서 정리.** `docs/issue/[#1]~[#7]`(MySQL/Debezium, 팀 이슈 번호와 충돌)은 폐기. `docs/design/아키텍처 — CDC…`(MySQL, "대체됨" 배너만 있음)와 `관리해야 하는 데이터 정의`는 Postgres 기준 재작성.
5. **연계 접점.** #4(앱 순번 쓰기 엔드포인트), #10(10 rps 부하·측정 자동 기록), #5·#6(진입점·트래픽 전환)과 맞춘다.

## 파일이 어디 있나

* **결정(ADR):** `docs/adr/` — 0001 정합성, 0002 랜섬웨어(보류), 0003 Debezium(**대체됨**), 0004 이전(**현행**).
* **작업 SPEC:** `specs/infra-7`(컷오버)·`infra-8`(롤백)·`infra-14`(백업 PITR).
* **구현 PoC:** `replication/` — `docker-compose.yml` + `scripts/{up,writer,cutover,reverse,rollback,verify,down}.sh` + `README.md`(검증 결과 포함). 롤백 절차서 `docs/design/롤백 절차서 (B→A).md`.
* **데이터 정의:** `docs/관리해야 하는 데이터 정의.md`(생각 메모), `docs/design/관리해야 하는 데이터 정의 (정리본).md`(노션용, MySQL 흔적 남아 재작성 대상).
* **옛 설계(참고만):** `docs/design/아키텍처 — CDC 백업·복구 파이프라인.md`(MySQL/Debezium 전제, 대체됨 배너).
