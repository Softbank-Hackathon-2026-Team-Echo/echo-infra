# 인프라·이전 엔진 12.1: 컷오버·롤백 스크립트 멱등화 + 결과 표에 계획 id

- 상태: 구현 (로컬 시험 통과, 운영 시험 전)
- 확인일: 2026-11-05
- 노션 계획서: https://app.notion.com/p/DB-infra-12-40f8bee9ada480b69563c0e7f643b1c3 (4-2절 I4·I5)
- GitHub 이슈: echo-infra #66 · 상위 #12 · 결정 #65
- 저장소: `echo-infra` · 브랜치 `feat/cutover-idempotent-plan-id`
- 작성: 이도현
- 근거: SPEC infra-7(컷오버)·infra-8(롤백), #57(결과 표), echo-was #73(쓰기 담당 판정)

## 1. 목표

`cutover.sh`·`rollback.sh` 를 **다시 돌려도 안전하게** 만든다. 컷오버 Job(12.2)과 echo-was 이전 계획 단계(API 서버 17)가 같은 명령을 다시 시도할 수 있어야 하기 때문이다. 결과 표에는 **계획 id** 를 남겨 echo-was 가 시간 창 없이 행을 찾게 한다.

## 2. 현재 맥락과 확인된 사실

- 두 스크립트는 지금 누가 쓰기 담당인지 보지 않고 바로 PAUSE 한다. 이미 넘어간 상태에서 다시 돌리면 쓰기 정지가 다시 생기고, 구독·백엔드가 뒤섞일 수 있다.
- 실패 처리는 "따라잡기 실패 → RESUME → exit 1" 하나뿐이다. 그 밖의 실패는 `set -e` 로 그 자리에서 끝나 PgBouncer 가 PAUSE 로 남을 수 있었다.
- 결과 표 `echo_ops.cutover_runs` 에는 계획 id 가 없다. echo-was API 서버 16 은 시간 창(계획 끝 ~ 다음 계획 생성)으로 찾는다. `paused_at` 은 스크립트를 돌린 컴퓨터의 시계다.
- 표는 `echo_pub FOR ALL TABLES` 로 복제된다. 칸 더하기(DDL)는 복제되지 않는다.

## 3. 범위

### 포함
- 쓰기 담당 판정 `writer_side`(구독 방향 + 두 PgBouncer 백엔드가 같은 쪽일 때만 그쪽, 아니면 `PARTIAL`)
- 시작 전 확인 `preflight`: 같은 `PLAN_ID` 기록이 있으면 `ALREADY_DONE`, 도착이 이미 쓰기 담당이면 `ALREADY_WRITER` 로 PAUSE 없이 `exit 0`. 판단 불가면 `exit 2`
- 실패 단계별 처리 `guard_on_error`(ERR trap): 시작 전 → 1, 쓰기 정지 중 → 양쪽 RESUME 후 1, 전환 중 → RESUME 하지 않고 2
- 결과 표 칸: `plan_id uuid`, `mode text`(`NORMAL`·`PROMOTE`, 검사 제약), `rpo_estimate_ms integer`, 고유 색인 `(plan_id, kind) WHERE plan_id IS NOT NULL`
- `PLAN_ID` 형식 검사(uuid 가 아니면 SQL 에 넣지 않고 1)
- 로컬 시험 `replication/k8s/scripts/tests/run.sh`
- README: 종료 코드 표, 부분 상태 복구 표

### 제외
- 컷오버 Job·신원·RBAC(12.2, #67), promote(12.3, #68), echo-was 쪽 읽기 변경(API 서버 17, echo-was #75)
- `common.sh` 의 Mac 전용 PATH 제거(12.2). 이번에는 앞이 아니라 **뒤에** 붙이도록만 바꿨다(gcloud SDK 의 kubectl 이 시험용 kubectl 을 가리지 않게)

## 4. 설계

```text
cutover.sh / rollback.sh
  trap guard_on_error ERR            GUARD_PHASE=precheck
  plan_id_check                      uuid 아니면 exit 1
  ops_table_ensure                   표·새 칸·색인 (양쪽, 쓰기 정지 창 밖)
  preflight <kind> <from> <to>       ALREADY_DONE / ALREADY_WRITER → exit 0 · PARTIAL → exit 2
  GUARD_PHASE=paused     PAUSE → 따라잡기 → max(n) 대조 → 시퀀스 맞춤
  GUARD_PHASE=switching  구독 끄기·만들기 → repoint → RESUME
  GUARD_PHASE=done       결과 기록(plan_id, mode=NORMAL)
```

`writer_side` 판정표:

| B `echo_sub` 켜짐 | A `echo_sub_rev` 켜짐 | A PgBouncer 백엔드 | B PgBouncer 백엔드 | 결과 |
|---|---|---|---|---|
| 1 | 0 | `echo-pg`(자기 쪽) | A 주소 | A |
| 0 | 1 | B 주소 | `echo-pg`(자기 쪽) | B |
| 그 밖 | | | | `PARTIAL(…)` |

## 5. 완료 기준 (이슈 #66)

- [x] `cutover.sh` 를 두 번 연속 돌리면 두 번째는 `ALREADY_WRITER` 로 끝나고 쓰기 정지가 생기지 않는다 — 로컬 시험 6
- [x] `PLAN_ID=<uuid> cutover.sh` → `rollback.sh` 뒤 두 행에 `plan_id`·`mode` 가 있고 양쪽에 복제된다. 롤백 뒤 정방향 복제가 다시 흐른다 — 로컬 시험 4·7
- [ ] 칸을 더한 뒤에도 echo-was API 서버 16 이 그대로 동작한다 — 읽기 질의가 칸을 이름으로 고르므로 영향 없을 것으로 본다. **운영 시험에서 확인**
- [x] 종료 코드 0/1/2 표를 README 에 적는다
- [ ] 운영(A 도쿄·B 서울)에서 컷오버 → 롤백 한 바퀴 (Slack 공지 뒤)

## 6. 시험 결과 (로컬, 2026-11-05)

`replication/k8s/scripts/tests/run.sh` — Postgres 17 두 대(Docker) + 시험용 `kubectl`(exec 를 컨테이너로 넘김, PgBouncer 는 ini 파일·명령 기록으로 대신, `sslmode=require` → `disable`). **34개 통과 · 실패 0.**

| # | 시나리오 | 결과 |
|---|---|---|
| 1 | 처음 쓰기 담당 | A |
| 2 | 잘못된 `PLAN_ID`(SQL 주입 문자열) | 종료 1, PAUSE 0회 |
| 3 | A 가 쓰기 담당일 때 `rollback.sh` | `ALREADY_WRITER`, PAUSE 0회 |
| 4 | `PLAN_ID=P1` 컷오버 | 종료 0, 쓰기 담당 B, 기록 CUTOVER·NORMAL·누락 0·중복 0, A 로 역복제 |
| 5 | 같은 P1 으로 다시 | `ALREADY_DONE`, PAUSE 추가 없음 |
| 6 | 다른 P2 로 다시 | `ALREADY_WRITER`, 기록 없음 |
| 7 | B 에 10건 쓰고 P3 롤백 | 종료 0, 쓰기 담당 A, 장부 60·누락 0·중복 0, 정방향 복제 재개 |
| 8 | 쓰기 정지 중(시퀀스 맞춤) 실패 | 종료 1, 양쪽 RESUME, 쓰기 담당 A |
| 9 | 전환 중(역방향 구독 만들기) 실패 | 종료 2, RESUME 0회, `PARTIAL`, 다시 실행해도 2 |
| 10 | README 부분 상태 복구 첫 줄대로 되돌린 뒤 다시 | 쓰기 담당 A, 컷오버 성공, 장부 62·누락 0·중복 0 |

로컬 쓰기 정지 시간(3.8~4.9초)은 `docker exec` 기동 시간이 섞인 값이라 운영(5.4~5.6초, kubectl exec)과 비교 대상이 아니다.

## 7. 위험과 되돌리기

- 운영 표에 칸을 더하는 것은 `ADD COLUMN IF NOT EXISTS`(빈 칸)라 기존 행·읽기에 영향이 없다. 되돌릴 때는 칸을 남겨 둬도 된다.
- `set -E` 로 함수 안 실패에도 trap 이 걸린다. 의도하지 않은 곳에서 끝나면 종료 코드로 구분된다(1 = 바뀐 것 없음).
