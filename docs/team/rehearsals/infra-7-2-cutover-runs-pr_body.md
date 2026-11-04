> 출처: 김지민 개인 보관 `archive/softbank-hackathon-2026/infra-7-2-cutover-runs/pr_body.md`(저장소 밖) · 수집 시각 2026-11-05 03:19 KST · 저장소에 올림: 김지민 (11/5) \
> 원문 그대로이며 정리본이 아닙니다. 바꾼 곳: 없음(머리 3줄만 더함)

GitHub 이슈: https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-infra/issues/57

## 🎯 목적

`cutover.sh`·`rollback.sh`가 찍는 쓰기 정지 시간·누락·중복은 지금 터미널에만 남습니다. 그래서 이전 결과 화면의 그 칸이 `—`로 나옵니다. 이 값을 고객 DB 표 `echo_ops.cutover_runs`에 남기고, echo-was가 데이터 확인 단계와 같은 `echo_monitor` 연결로 읽게 합니다. echo-was 쪽 읽기는 [echo-was#63](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-was/issues/63)에서 합니다.

동옥님이 지금 작업하기 어려우셔서 지민이 대신 진행했습니다([이슈 댓글](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-infra/issues/57#issuecomment-6631917920)).

## 🛠 작업 요약

- `common.sh`
  - `ops_table_ensure`: A·B 양쪽에 표와 `echo_monitor` 읽기 권한을 만듭니다(이미 있으면 그대로 둠). 켜진 구독 중 이 표가 빠진 것만 `REFRESH PUBLICATION` 합니다.
  - `record_run`: RESUME 뒤 새 primary에서 `verify.sh`와 같은 질의로 장부를 대조하고 한 줄을 `INSERT` 합니다. 실패해도 경고만 찍고, 컷오버·롤백은 성공으로 둡니다.
- `cutover.sh`·`rollback.sh`: 쓰기 정지 창 밖에서 시작할 때 `ops_table_ensure`를 부르고, 끝에 `record_run`을 부릅니다. 쓰기 정지 창 안의 명령은 바꾸지 않았습니다.
- `subscribe.sh`: 구독을 만들기 전에 `ops_table_ensure`를 부릅니다. A를 새로 세워도(11/5 01:00 재구축 리허설) 표가 다시 생깁니다.
- 새 `ops-table.sh`: 표만 따로 만들고 상태를 찍습니다.
- README: 파일 표, echo-was 접점, 주의(복제되는 표에 `bigserial` 금지)

설계에서 지킨 것은 두 가지입니다.
- `echo_pub`이 `FOR ALL TABLES`라 새 표도 복제됩니다. 표가 한쪽에만 있으면 복제 전체가 멈추므로 양쪽에 먼저 만듭니다.
- 키는 uuid입니다. 논리 복제는 시퀀스를 넘기지 않아서, 일련번호를 쓰면 롤백 때 A가 같은 번호를 다시 내 키가 충돌합니다.

## ✅ 확인 (11/4 22:30~22:45 KST, 운영 A 도쿄 EKS · B 서울 GKE)

| 확인 | 결과 |
|---|---|
| 적용 전 상태 | A = primary(`echo_sub` streaming), B = 구독자, 장부 168/168, 표 없음 |
| `ops-table.sh` 1회 | A·B에 표 생성, `echo_monitor` 읽기 = true, B `echo_sub`에 표 추가(`srsubstate = r`) |
| `ops-table.sh` 재실행 | 변경 없음(멱등), REFRESH 다시 안 함 |
| 복제 | A에 시험 행 INSERT → 3초 뒤 B에 보임 → A에서 DELETE → 양쪽 0행. B 구독 오류 수 0, A walsender `echo_sub:streaming`, 장부 168/168 그대로 |
| `record_run`의 INSERT 식 | B에서 `BEGIN … ROLLBACK`으로 21:12 리허설 시각을 넣어 시험: `write_pause_ms 8525 · drain 1140 · catchup 770 · switch 6615` (스크립트 출력 8.525s와 같음) |
| 검사 | `bash -n` 5개 파일 통과, `shellcheck -S warning`은 원래 있던 SC2034(`i` 미사용) 2건만 |

## 미검증

- **`cutover.sh` → `rollback.sh`를 실제로 한 번 돌려 행 2개가 생기는지:** 쓰기 정지(약 9초)가 생기는 운영 작업이라 아직 돌리지 않았습니다. 시간을 정해 따로 돌립니다. 이것이 이슈 완료 기준 2·3번입니다.
- **CI:** 이 저장소에는 쉘 스크립트 CI가 없습니다. 위 로컬 검사가 전부입니다.

## 📋 체크리스트

- [x] 비밀값 없음(비밀번호는 지금처럼 파드 env에서만 읽음)
- [x] 쓰기 정지 창 안의 명령 변경 없음
- [ ] 실제 컷오버·롤백 1회(이슈 완료 기준)
