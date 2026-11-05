# 인프라·이전 엔진 12.3: 원본 DB 장애 시 다른 클라우드 DB 승격(promote)

- 상태: 구현 (로컬 시험 통과, 운영 시험 전)
- 확인일: 2026-11-05
- 노션 계획서: https://app.notion.com/p/DB-infra-12-40f8bee9ada480b69563c0e7f643b1c3 (4-2절 I6·I7, 4-4절)
- GitHub 이슈: echo-infra #68 · 상위 #12 · 결정 #65(4번: EMERGENCY 에서만 승격 — 김지민 동의 11/5)
- 저장소: `echo-infra` · 브랜치 `feat/db-promote-on-source-failure` (12.1 `feat/cutover-idempotent-plan-id` 위)
- 작성: 이도현

## 1. 목표

원본 A(도쿄)가 죽어 `cutover.sh` 를 쓸 수 없을 때 **B(서울)만으로 쓰기 담당을 B 로 올리고**, A 가 살아나면 A 를 B 의 사본으로 다시 맞춰 정상 롤백 경로로 돌아오게 한다. 잃었을 수 있는 범위와 실제로 잃은 행을 기록에 남긴다.

## 2. 현재 맥락과 확인된 사실

- `cutover.sh` 는 A PgBouncer PAUSE, A `pg_stat_replication` 따라잡기 확인이 필요하다 → A 가 죽으면 쓸 수 없다.
- 재난 긴급 이전(echo-was API 서버 9)은 트래픽만 B 로 옮긴다. B PgBouncer 는 여전히 A 를 백엔드로 두므로 A 가 죽으면 서울 앱 쓰기가 전부 실패한다.
- B 의 `echo_sub` 는 A 가 죽으면 연결을 계속 다시 시도한다(켜져 있음). B 의 데이터는 마지막으로 받은 곳까지다.

## 3. 범위

### 포함
- `promote.sh`: A 에 닿으면 거부(종료 1, `FORCE_PROMOTE=1` 로만 우회). B PAUSE → 시퀀스 맞춤 → `echo_sub` DISABLE → B 백엔드를 B 로 → RESUME → 기록(`kind=CUTOVER, mode=PROMOTE, rpo_estimate_ms`). 같은 `PLAN_ID` 면 `ALREADY_DONE`, B 가 이미 쓰기 담당이면 `ALREADY_WRITER`
- `cutover.sh` 분기: A 에 닿지 않으면 `ALLOW_PROMOTE=true` 일 때만 `promote.sh` 로 넘어가고, 아니면 종료 1
- `resync-a.sh`(사람이 실행): A 백엔드를 B 로 → A 에만 남은 장부 행 보고 → B 옛 구독 `echo_sub` 정리(A 슬롯 포함) → A 복제 대상 표 비움 → A 가 B 를 구독(`copy_data=true`) → 초기 복사 대기
- `common.sh`: `a_reachable`(요청 제한 5초 × 3회), `b_side_state`(B 만 보고 WRITER·REPLICA·PARTIAL)
- ConfigMap 유지(12.1 `persist_backend`): `promote.sh` 는 RESUME 뒤 B ConfigMap 을, `resync-a.sh` 는 A 백엔드를 B 로 바꾼 뒤 A ConfigMap 을 맞춘다. 다시 실행하면 B 가 WRITER 일 때 먼저 맞춘다
- 절차서 5·6절, k8s README, 시험 13~18

### 제외
- echo-was 가 `ALLOW_PROMOTE` 를 넘기는 일(API 서버 17, echo-was#75: EMERGENCY 계획만)
- A 를 막는 강제 차단(fencing). A 클러스터가 반쯤 살아 도쿄 앱이 A 에 계속 쓰는 경우는 `resync-a.sh` 1단계(A 백엔드를 B 로)에서 막고, 그 사이 쓰기는 2단계에서 "A 전용 행"으로 보고된다
- 운영 시험(A NLB 허용 목록 막기)은 서동옥 님과 시간을 맞춘 뒤

## 4. 설계

```text
cutover.sh (ALLOW_PROMOTE=true, A 닿지 않음) ─exec─▶ promote.sh
promote.sh   a_reachable? ─예─▶ 거부(1)
             B 기록·상태: ALREADY_DONE / ALREADY_WRITER(0) · PARTIAL(2) · REPLICA ─▶ 계속
             rpo 기준 시각 = B pg_stat_subscription.last_msg_receipt_time ?? max(demo.seq_write.wrote_at)
             paused: PAUSE B → setval      switching: DISABLE echo_sub → repoint B echo-pg → RESUME B
             record_run CUTOVER A B … PROMOTE rpo
resync-a.sh  A 닿음 + B WRITER 확인 → A 백엔드 B 로 → A 전용 행 보고 → DROP SUBSCRIPTION echo_sub (B)
             → TRUNCATE echo_pub 표 (A) → CREATE SUBSCRIPTION echo_sub_rev copy_data=true (A) → 초기 복사 대기
             끝 상태 = 정상 컷오버 뒤(writer_side = B) → rollback.sh 가능
```

## 5. 완료 기준 (이슈 #68)

- [x] A 를 막고(로컬: 컨테이너 정지) `ALLOW_PROMOTE=true cutover.sh` → promote 로 넘어가 B 쓰기 성공 — 시험 15
- [x] 결과 행에 `mode=PROMOTE`·`rpo_estimate_ms`. 막기 직전 A 에만 쓴 행 수를 남김 — 시험 15·17 (`resync-a.sh` 가 1건 n=63 보고)
- [x] `ALLOW_PROMOTE` 없으면 A 가 막혀 있어도 승격하지 않고 종료 1 — 시험 14
- [x] A 를 다시 연 뒤 `resync-a.sh` 로 A 가 B 를 따라오고, `rollback.sh` 로 A 복귀까지 — 시험 17·18 (롤백 장부 대조에 잃은 1건이 누락 1 로 나옴)
- [x] 절차서에 "원본 장애 승격"·"A 다시 맞추기" 절 — `docs/design/롤백 절차서 (B→A).md` 5·6절
- [ ] 운영(A NLB 막기) 한 바퀴

## 6. 시험 결과 (로컬, 2026-11-05)

`bash replication/k8s/scripts/tests/run.sh` — 12.1 시나리오 1~10-1 + 12.3 시나리오 11~18, **76개 통과 · 실패 0** (12.1 의 ConfigMap 유지 반영 뒤).

| # | 시나리오 | 결과 |
|---|---|---|
| 12 | A 에 닿는데 `promote.sh` | 종료 1, B 그대로(REPLICA) |
| 13 | B 구독을 잠시 끄고 A 에만 n=63 쓰기 → A 정지 → B 구독 켬 | 재난 흉내 |
| 14 | `ALLOW_PROMOTE` 없이 `cutover.sh` | 종료 1, B 그대로 |
| 15 | `ALLOW_PROMOTE=true PLAN_ID=P6 cutover.sh` | promote 분기, B WRITER, 기록 PROMOTE·rpo 있음, B 쓰기 성공 |
| 16 | 다시 실행 | 같은 계획 ALREADY_DONE, 다른 계획 ALREADY_WRITER |
| 17 | A 재기동 → `resync-a.sh` | A 전용 1건(n=63) 보고, writer_side = B, A 장부 = B 장부, B→A 복제 흐름 |
| 18 | `PLAN_ID=P8 rollback.sh` | A 복귀, 기록 ROLLBACK·누락 1·중복 0 |

`rpo_estimate_ms` 는 상한이다. 시험처럼 쓰기가 드물면 크게(약 53초) 나온다. 시연처럼 부하기가 계속 쓰면 A 가 죽은 시점에 가까워진다.

## 7. 위험

- **쓰기 담당 둘(split-brain)**: A 가 살아 있는데 B 를 올리는 것이 가장 위험하다. `a_reachable` 이 닿으면 거부하고, echo-was 는 EMERGENCY 계획에서만 `ALLOW_PROMOTE` 를 넘긴다(#65 결정 4). 클라우드 사이 망만 끊기고 A 가 살아 있는 경우 운영자 쪽(kubectl)에서도 A 에 닿지 않을 수 있다 → 그 사이 A 에 들어온 쓰기는 `resync-a.sh` 가 개수로 보고하고 지운다(손실로 기록).
- `resync-a.sh` 는 A 의 복제 대상 표를 비운다. B 가 쓰기 담당인지(`b_side_state = WRITER`) 확인한 뒤에만 진행한다.
