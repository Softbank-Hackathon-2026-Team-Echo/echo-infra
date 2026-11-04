> 출처: 김지민 개인 보관 `archive/softbank-hackathon-2026/rehearsal-2026-11-04-2110/README.md`(저장소 밖) · 수집 시각 2026-11-05 03:19 KST · 저장소에 올림: 김지민 (11/5) \
> 원문 그대로이며 정리본이 아닙니다. 바꾼 곳: 없음(머리 3줄만 더함)

# 2차 리허설: Echo 이전 → DB 컷오버 → Echo 복귀 (2026-11-04 21:10~21:15 KST)

- 환경: 운영 `app.echoport.uk`(M5 Aside, Saccharine1211), 조직 echo-demo, 서비스 demo(`3ffcae98…`), 실제 실행기, 데이터 확인 `postgres`(echo-was #57)
- 부하: GKE loadgen 50 rps → 대표 주소. M1에서 `/api/info` 측정 루프(`probe.txt`)
- DB 컷오버·원복: 서동옥(echo-infra), Slack 스레드 1793791294.655649

| 순서 | 무엇 | 시각 | 결과 |
|---|---|---|---|
| 1 | Echo 이전 aws-tokyo → gcp-seoul (계획 8ce032aa, PLANNED) | 21:10:57~21:11:07 (10초) | SUCCEEDED, 데이터 확인 실측 지연 0초(A의 `echo_sub`) |
| 2 | DB 컷오버(동옥) | 21:12~21:13:21 완료 알림 | A에 `echo_sub_rev` 생김(21:13:11), B `pg_stat_replication` `echo_sub_rev` streaming(21:13:32), GKE PgBouncer → 로컬 `echo-pg` |
| 3 | Echo 복귀 gcp-seoul → aws-tokyo (계획 725b048d, FAILBACK) | 21:14:05~21:14:14 (9초) | SUCCEEDED, 데이터 확인 실측 지연 0초(B의 `echo_sub_rev`) |
| 4 | DB 원복(동옥) | 21:15 요청 | 동옥님 진행 |

- 진입점 5xx 누적: aws 33 → 33, gcp 1 → 1 (리허설 동안 증가 없음). 끝 가중치 `{"aws":100,"gcp":0}`.
- M1 측정 루프: 21:10:30~21:15 119회 중 200 114회, `000`(curl 5초 시간 초과) 5회. 리허설 전(21:05~21:09)에도 같은 빈도로 6회 있어 이전과 무관한 M1 측정 경로 문제로 본다(미확인).
- 화면 문구가 한국어로 바뀌어(`계획 만들기`) 낮 리허설 스크립트의 영어 버튼 이름을 고쳐 씀(`b_fwd2.js`).

## 정리
자기 승인 끔(`allowSelfApproval: false` 확인), loadgen 0/0, `TARGET_HOST` 원래 값 `shop.echoport.uk`로 되돌림, 측정 루프 종료.
