> 출처: 김지민 개인 보관 `archive/softbank-hackathon-2026/infra-7-2-cutover-runs/done_comment.md`(저장소 밖) · 수집 시각 2026-11-05 03:19 KST · 저장소에 올림: 김지민 (11/5) \
> 원문 그대로이며 정리본이 아닙니다. 바꾼 곳: 없음(머리 3줄만 더함)

완료 기록(11/4 22:52 KST, 김지민): [PR #58](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-infra/pull/58) 병합(main `8f9ae8f`) 뒤, 운영 A(도쿄 EKS)·B(서울 GKE)에서 main 스크립트를 그대로 써서 `cutover.sh` → `rollback.sh`를 한 번씩 돌렸습니다. 쓰기 부하는 걸지 않았고(장부 168건 고정), 진입점은 aws 100%, 진행 중인 이전 계획은 없었습니다.

| 단계 | 스크립트 출력 | 결과 표 행 |
|---|---|---|
| 컷오버 A→B (22:51:59) | 쓰기 정지 5.817s (드레인 0.774 · 따라잡기 0.428 · 나머지 4.615) | `CUTOVER A→B 5817ms · 774/428/4615 · 168건 · 누락 0 · 중복 0` |
| 롤백 B→A (22:52:13) | 복귀 6.645s (드레인 0.714 · 따라잡기 0.288 · 나머지 5.644) | `ROLLBACK B→A 6645ms · 714/288/5644 · 168건 · 누락 0 · 중복 0` |

**완료 기준**
- [x] A·B 양쪽에 `echo_ops.cutover_runs`가 있고 `echo_monitor` 읽기 권한이 있다(`has_table_privilege` = true)
- [x] `cutover.sh` → `rollback.sh` 뒤 행 2개가 생기고 **양쪽에 같은 두 행**이 있다. 끝 상태: A walsender `echo_sub:streaming`, B `echo_sub` enabled, B 구독 오류 수 0
- [x] 행의 `write_pause_ms`가 스크립트 출력과 같다(5.817s ↔ 5817, 6.645s ↔ 6645)

**끝 상태(처음과 같음)**: A가 primary이고, A PgBouncer → `echo-pg`, B PgBouncer → A NLB입니다. 장부는 A·B 모두 168건(누락 0·중복 0)이고, 컷오버 동안 붙었던 역방향 구독 `echo_sub_rev`는 롤백이 지웠습니다.

**참고**
- 표는 `subscribe.sh`·`cutover.sh`·`rollback.sh`가 시작할 때마다 확인합니다. 그래서 11/5 01:00 AWS 재구축 리허설로 A를 새로 세워도 다시 생깁니다. A만 새로 세우고 구독을 다시 만들지 않을 때는 `scripts/ops-table.sh`를 한 번 돌려 주세요.
- 이 두 행은 echo-was가 아직 읽지 않습니다. 이전 계획 결과에 붙이는 일은 [echo-was#63](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-was/issues/63)에서 합니다.

@SeoDongOk 대신 진행해 두었습니다. 스크립트를 바꾼 곳은 PR #58에 있습니다.
