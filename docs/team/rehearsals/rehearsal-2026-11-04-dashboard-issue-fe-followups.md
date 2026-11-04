> 출처: 김지민 개인 보관 `archive/softbank-hackathon-2026/rehearsal-2026-11-04-dashboard/issue-fe-followups.md`(저장소 밖) · 수집 시각 2026-11-05 03:19 KST · 저장소에 올림: 김지민 (11/5) \
> 원문 그대로이며 정리본이 아닙니다. 바꾼 곳: 없음(머리 3줄만 더함)

## 배경

11/4 12:27~12:37 KST에 운영 대시보드(`app.echoport.uk`, echo-demo 조직)만으로 실제 실행기 이전을 세 번 돌렸습니다. 대상 서비스는 `demo`(echo-demo-app)이고, 진입점에 초당 50건 부하를 건 상태였습니다.

| # | 계획 | 결과 |
|---|---|---|
| 1 | aws-tokyo → gcp-seoul (재난 시뮬레이션 → 대상 선택 → AI 사전 점검 → 계획 → 승인) | 성공 9초, 실패 요청 0 |
| 2 | gcp-seoul → aws-tokyo (결과 화면 Start failback) | 성공 13초, 실패 요청 0 |
| 3 | aws-tokyo → gcp-seoul 진행 중 Roll back | 되돌림 성공 3초 |

화면 흐름은 끝까지 잘 동작했습니다. 다만 실제 모드에서 아래 네 가지가 드러났습니다.

## 고칠 것

### 1. 실제 모드에서 "Inject a failure (demo)" 숨기기

- 지금: 계획 화면(`evacuation/plan`)에서 실패 주입을 고르고 Create plan을 누르면 서버가 400 "simulate is only accepted with fake executors"로 거절합니다. 실제 실행기에서는 일부러 막아 둔 것이라 서버 동작은 의도한 대로입니다.
- 바꿀 것: 대상 환경 연결이 실제(`services/{id}` 응답의 `environments[].simulated: false`)이면 이 선택지를 숨기거나 비활성화하고 이유를 한 줄 보여 주세요. 가짜 환경에서는 지금처럼 둡니다.

### 2. 이전 종류(Failback 여부)는 서버 `mode` 칸으로 판단하기

- 지금: `src/lib/migration-mode.ts`의 `isFailback()`이 앞선 성공 이전을 거꾸로 되짚는지로 추측합니다. 3번 계획은 서버가 `mode: "PLANNED"`로 기록했는데, 화면 제목은 "Failback d455be83 rolled back"으로 나왔습니다. 바로 앞 성공 계획이 2번(복귀)이었기 때문입니다.
- 바꿀 것: 이전 계획 응답에는 이미 `mode`(`PLANNED` / `FAILBACK` / `EMERGENCY`) 칸이 있습니다(echo-was `specs/api-8-3-plan-mode.md`). `schema.d.ts`를 갱신하고 제목·배지를 `mode`로 정해 주세요. 서버 규칙상 "복귀의 복귀"는 새 이전(PLANNED)입니다.

### 3. 데이터 확인 단계 값에 가짜 표시 붙이기

- 지금: 데이터 확인 단계(Data sync check)의 복제 지연 값 "0.3 s"는 서버의 가짜 확인기가 주는 고정값입니다. 데이터 이전 엔진(infra #7)이 아직 붙지 않았기 때문입니다. 그런데 진행·결과 화면의 Replication lag, Max replication lag 칸에는 simulated 표시가 없습니다. 계획 응답의 `simulated`는 `false`라 화면이 알 방법도 없습니다.
- 바꿀 것: 데이터 엔진이 붙을 때까지 이 값들에 simulated 배지를 항상 붙여 주세요(심사 규칙상 목업은 밝혀야 합니다). 서버가 단계별 가짜 여부 칸을 줄지는 API 서버 쪽에서 정해 이 이슈 댓글로 알리겠습니다.
- 참고: p95는 진입점 실측값이라 그대로 두면 됩니다.

### 4. 재난 없이 일반 이전을 시작하는 입구 만들기

- 지금: 계획을 만드는 화면 입구는 Evacuation(재난 시뮬레이션 → AI 사전 점검) 흐름뿐입니다. 재난 없이 옮기려면 `evacuation/plan?service=<id>&target=<환경 id>` 주소를 직접 열어야 합니다.
- 바꿀 것: 서비스 상세의 More actions(또는 환경 행)에 "Migrate to…" 같은 입구를 두고, 대상 환경을 고르면 위 계획 화면으로 보내 주세요. 원장 데모 필수 장면 "가동 중 앱 클라우드 간 이전"은 재난과 별개로도 보여 줄 수 있어야 합니다.

## 참고 (고칠 것 아님)

- 재난 시뮬레이션이 켜져 있으면 결과 화면의 Start failback이 잠깁니다("still inside an active disaster radius"). 설계대로이니, 시연 대본(프론트 11)에 "End simulation → Start failback" 순서를 넣으면 됩니다.
- 시험에 쓰던 가짜 배포 기록 서비스 `shop`은 지웠습니다. 이제 echo-demo에는 `demo` 서비스 하나만 있습니다.

## 완료 기준

- [ ] 1. 실제 환경 대상 계획 화면에서 실패 주입이 숨겨지거나 비활성화되고, 가짜 환경에서는 그대로 보임
- [ ] 2. 제목·배지가 서버 `mode` 값과 일치(PLANNED 계획이 Failback으로 나오지 않음)
- [ ] 3. 데이터 확인 단계 값에 simulated 표시
- [ ] 4. 서비스 상세에서 재난 없이 이전 계획 화면으로 갈 수 있음

@kimdoyoung1110 의견은 이 이슈 댓글로 남겨 주세요. 서버 쪽 확인이 필요한 부분은 제가 답하겠습니다.
