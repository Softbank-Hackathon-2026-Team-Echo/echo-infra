> 출처: 김지민 개인 보관 `archive/softbank-hackathon-2026/rehearsal-2026-11-04-dashboard/README.md`(저장소 밖) · 수집 시각 2026-11-05 03:19 KST · 저장소에 올림: 김지민 (11/5) \
> 원문 그대로이며 정리본이 아닙니다. 바꾼 곳: 없음(머리 3줄만 더함)

# 대시보드로 한 실제 이전 리허설 (2026-11-04 12:27~12:37 KST)

- 환경: 운영 `app.echoport.uk`(M5 Aside, Saccharine1211), 조직 echo-demo, 서비스 demo(`3ffcae98…`, 대표 주소 `demo-y6cz3jrc`), 실제 실행기(EXECUTOR_MODE real, 진입점 http)
- 부하: GKE loadgen 50 rps → 진입점(대표 주소 Host). 별도로 M1에서 대표 주소 `/api/info`를 약 1초 간격으로 호출(`probe_fwd.txt`)
- 자기 승인: 리허설 동안만 켬(설정 > Members) → 끝나고 끔(API `allowSelfApproval: false` 확인)

## 결과

| # | 계획 | 화면 흐름 | 결과 | 걸린 시간 | 판정한 요청 | 실패 요청 |
|---|---|---|---|---|---|---|
| 1 | 0afea61b aws→gcp (PLANNED) | 재난 시뮬레이션(M7.2 도쿄) → 대상 선택 → AI 사전 점검(브라우저 가짜) → 패치 승인 → 계획 만들기 → 승인 | SUCCEEDED | 9초(예상 17초) | 132 | 0 |
| 2 | bcd99f7a gcp→aws (FAILBACK) | 재난 시뮬레이션 끝내기 → 결과 화면 Start failback → 만들기 → 승인 | SUCCEEDED | 13초 | 143 | 0 |
| 3 | d455be83 aws→gcp (PLANNED) | 계획 화면 → 만들기 → 승인 → 진행 중 Roll back → 확인 | ROLLED_BACK(ABORTED, rollback SUCCEEDED) | 3초 | 0 | — |

- 외부 측정: 229회 호출 모두 200. 응답 환경이 aws→gcp(12:32:06~10), gcp→aws(12:34:23)로 바뀜.
- 진입점: 끝 가중치 `{"aws":100,"gcp":0}`, 5xx 누적 aws 1(리허설 전부터 있던 1건) · gcp 0.
- 서비스 상태: aws-tokyo SERVING 100, gcp-seoul·onprem STANDBY 0.

## 발견한 것

1. 실패 주입(Inject a failure)을 고르면 서버가 거절: "simulate is only accepted with fake executors". 실제 모드에서는 설계대로 막히지만, 화면이 선택지를 그대로 보여 줌(프론트 숨김 필요).
2. 사람이 중단한 3번 계획(서버 mode=PLANNED)의 제목이 "Failback d455be83 rolled back"으로 나옴. 프론트 `isFailback` 추측이 서버 `mode`와 다름.
3. 데이터 확인 단계 "lag 0.3 s"는 가짜(`FakeDataSyncChecker`)인데 결과 화면 RPO·최대 지연 칸에 simulated 표시가 없음. p95는 진입점 `/summary` 실측.
4. 재난 시뮬레이션이 켜져 있으면 Start failback이 잠김("still inside an active disaster radius") — 설계대로. 시연 대본에 "재난 종료 → 복귀" 순서를 넣어야 함.
5. 대시보드에서 계획을 만드는 입구는 Evacuation(재난) 흐름뿐. 일반 이전은 계획 화면 URL(`evacuation/plan?service=&target=`)을 직접 열어야 함. 재난 대상 목록에 옛 가짜 서비스 `shop`이 함께 뜸.

## 정리

부하 끔(loadgen 0/0), loadgen TARGET_HOST 원래 값 `shop.echoport.uk`로 되돌림, 자기 승인 끔, 측정 루프 종료. 시뮬레이션 재난은 끝냄(브라우저 sessionStorage).
