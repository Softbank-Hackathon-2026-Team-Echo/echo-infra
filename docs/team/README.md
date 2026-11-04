# docs/team — 팀 작업 기록 원문

저장소 밖(팀 위키·개인 보관 폴더)에 있던 Team Echo의 작업 기록을 심사·멘토가 열 수 있도록 한곳에 모은 폴더입니다.

**원문 그대로, 정리본 아님(킥오프 규칙: 작업 중 메모를 다시 쓰지 않고 그대로 공유).** 각 파일 맨 위 머리 3줄에 출처·수집 시각·올린 사람을 적었고, 바꾼 곳(위키 내부 링크를 글자로 푼 것, 내부 IP를 `[가림]`으로 바꾼 것)도 그 머리에 적었습니다. 위키 파일은 YAML 머리(`---`)가 첫 줄에 있어야 GitHub에서 깨지지 않아 머리 3줄을 그 바로 뒤에 두었습니다.

## 폴더

| 폴더·파일 | 내용 | 원본 위치 |
|---|---|---|
| `decision-log.md` | 팀 결정 로그 D-001~D-094 (Slack·허들·노션·GitHub에서 매시간 수집, 버린 대안·이유·상태 포함) | 팀 위키 `concepts/decision-log.md` |
| `huddles/` | 허들·회의 요약 | 팀 위키 `summaries/` |
| `security/` | CVE-2026-98432 대응 기록 (확인 요청 검증 → 온프레·GKE 조치 전/후 기록) | 개인 보관 `cve-2026-98432/` |
| `rehearsals/` | 11/4 리허설 기록·컷오버 실행 로그 | 개인 보관 `rehearsal-2026-11-04-2110/`·`rehearsal-2026-11-04-dashboard/`·`infra-7-2-cutover-runs/` |

## 파일 목록

| 파일 | 한 줄 |
|---|---|
| [decision-log.md](decision-log.md) | 팀 결정 로그 (D-001~D-094) |
| [huddles/2026-10-30-31-slack-threads.md](huddles/2026-10-30-31-slack-threads.md) | 10/30~31 Slack 채널·스레드 요약 |
| [huddles/2026-11-01-huddles-and-decisions.md](huddles/2026-11-01-huddles-and-decisions.md) | 11/1 허들·결정 요약 |
| [huddles/2026-11-02-huddles-and-decisions.md](huddles/2026-11-02-huddles-and-decisions.md) | 11/2 20시 회의 허들 2개 요약 |
| [huddles/2026-11-03-20h-huddle.md](huddles/2026-11-03-20h-huddle.md) | 11/3 20시 회의 허들 요약 |
| [huddles/final-kickoff-deck.md](huddles/final-kickoff-deck.md) | 결선 킥오프 자료 요약 |
| [security/cve-2026-98432-response.md](security/cve-2026-98432-response.md) | CVE-2026-98432 확인 요청(11/4 23:35) 사실 검증 + 조치 결과(온프레 커널·GKE 업그레이드 전/후 기록 원문) |
| [rehearsals/rehearsal-2026-11-04-2110-README.md](rehearsals/rehearsal-2026-11-04-2110-README.md) | 2차 리허설: Echo 이전 → DB 컷오버 → Echo 복귀 (11/4 21:10~21:15) |
| [rehearsals/rehearsal-2026-11-04-dashboard-README.md](rehearsals/rehearsal-2026-11-04-dashboard-README.md) | 대시보드로 한 실제 이전 리허설 (11/4 12:27~12:37) |
| [rehearsals/rehearsal-2026-11-04-dashboard-issue-fe-followups.md](rehearsals/rehearsal-2026-11-04-dashboard-issue-fe-followups.md) | 위 리허설에서 나온 프론트 후속 이슈 초안 |
| [rehearsals/infra-7-2-cutover-runs-done_comment.md](rehearsals/infra-7-2-cutover-runs-done_comment.md) | 인프라 7.2 완료 기록 댓글 원문 (11/4 22:52) |
| [rehearsals/infra-7-2-cutover-runs-pr_body.md](rehearsals/infra-7-2-cutover-runs-pr_body.md) | 인프라 7.2 PR #58 본문 원문 |
| [rehearsals/infra-7-2-cutover-runs-cutover_run_1104.log](rehearsals/infra-7-2-cutover-runs-cutover_run_1104.log) | 11/4 22:51 `cutover.sh` → `rollback.sh` 실행 원문 로그 |

리허설 파일 이름은 원본 폴더 이름을 앞에 붙였습니다(두 폴더에 `README.md`가 있어 겹치기 때문).

올리지 않은 것: 스크립트(`*.sh`·`*.js`·`*.py`), 측정 원본 로그(`probe*.txt`·`*.log`, `cutover_run_1104.log` 제외), 스크린샷, CVE 검증의 `raw/`·`kpatch/` 폴더.

작성: 김지민 (2026-11-05)
