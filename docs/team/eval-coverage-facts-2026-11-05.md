> 출처: 지민 로컬 archive/submission(운영 GET·저장소·이슈 90건 읽기 전용 조사) · 수집 시각 2026-11-05 10:40 KST · 저장소에 올림: 김지민 (11/5)

# 평가 요소 대비 Team Echo 구현 현황 — 사실 표

> 수집 2026-11-05 10:30~10:50 KST, 전부 읽기(curl·gh api·운영 GET). 평가 기준 원문: `~/archive/softbank-hackathon-2026/README.md` 21~63행.
> 운영 조회는 M5 Aside 지민 세션(조직 echo-demo `acd45045…`, 서비스 demo `3ffcae98…`), 원자료 M1 `~/.hermes/cache/scratch/echo_orch/eval_cov_out.json`·`eval_cov_out2.json`, GitHub 원자료 `~/.hermes/cache/scratch/eval_gh/`.
> 저장소 기준: echo-was `9d825e7`(#69) · echo-infra `2d4eae8` · echo-frontend `d603e2d`(#65) · echo-ai-agent `7d521e4`(#13) 의 origin/main.

## (a) 데모 필수 3개 — 4칸

### ① 가동 중 앱을 클라우드 간 이전

| 칸 | 사실 |
|---|---|
| 운영에서 지금 되는 것 | 환경 3개 CONNECTED(aws-tokyo·gcp-seoul·onprem). 서비스 demo: aws-tokyo SERVING 100 · gcp-seoul STANDBY 0 IN_SYNC · onprem STANDBY 0 IN_SYNC, 모두 `simulated=false`. 이전 계획 7건 전부 `simulated=false`(SUCCEEDED 6 · ROLLED_BACK 1, 방향 aws→gcp PLANNED 4 · gcp→aws FAILBACK 3). 단계 고정 5개: PREFLIGHT → SHIFT 10 → SHIFT 50 → DATA_SYNC_CHECK(복제 지연) → SHIFT 100. 롤백 조건 칸 `maxErrorRatePercent 1 · maxP95Ms 800 · maxReplicationLagSeconds 1`. 대표 주소 `/api/info` = `{"environment":"aws-tokyo"}`, 온프레 주소 = `{"environment":"onprem"}` (둘 다 200) |
| 화면에 보이는 것 | echo-frontend `pages/migrations/{MigrationsPage,MigrationPage,LiveTab,ResultTab}`, `dashboard/{Topology,LiveMigrationPanel,MigrationStatusCard}`, `evacuation/PlanPage`(운영 API 서버 8에 붙음, api-contract 11/3 메모). 결과 탭에 쓰기 정지·누락·중복(PR #63) |
| 목업·시뮬레이션 | 재난 트리거(`DISASTER_API_READY=false`, `lib/api/disasters.ts` 브라우저 흉내, 모든 재난 `simulated: true`) · 대피 후보 점수(`EVACUATION_API_READY=false`, `lib/api/evacuation.ts` 고정 상수: 비용 `{onprem 90, gcp 58, aws 55}`·데이터 위치 점수) · 실시간 이벤트(`EVENTS_API_READY=false`). 시연 대본 장면 2(재난)·3(대피 준비)에 `simulated` 배지 명시 |
| 없는 것 | 재난 API(echo-was 이슈 #9 open, 운영 openapi에 `/disasters` 경로 없음, echo-was 열린 PR 0건 — #70·#71 아직 안 열림) · DB 컷오버가 이전 계획에 묶이지 않음(사람이 `cutover.sh` 실행, design-infra §10) · 온프레가 진입점 업스트림에 없음(aws·gcp 2개, design-infra §10) → 온프레로의 트래픽 전환 불가 · 최근 운영 이전 2건의 SHIFT 단계 `requestCount 0 · lowTraffic true`(부하기 꺼짐, 그 시각 트래픽 없이 판정) |

### ② 여러 환경의 보안·거버넌스 상태 시각화

| 칸 | 사실 |
|---|---|
| 운영에서 지금 되는 것 | `GET /security/matrix` 200: 정책 `sec-rules-2026.11.04`, phase PREPARATION, 행 3(환경) × 칸 4(iam·encryption·auditLog·policy) = 12칸 → UNKNOWN 9 · WARN 3(policy 칸, 3환경). 통제 13종 × 3환경 = 39 → UNKNOWN 32 · WARN 3(C-IMG-1) · PASS 3(C-IMG-2) · NA 1(온프레 C-AUD-2). findings 3건 전부 RULE·REAL(Trivy secret PASS, Gitleaks PASS, Trivy image WARN). 기한부 예외 4건 전부 ACTIVE(C-DST-1·C-DB-1 × aws-tokyo·gcp-seoul, 만료 11/11). 보안 게이트 코드 있음, `security_gate_enabled: bool = False`(app/core/config.py:243) |
| 화면에 보이는 것 | `pages/security/{SecurityPage,SecurityMatrixTable,FindingsTable,FindingSheet,CompareTab}` — 매트릭스·finding은 운영 API(PR #64), 감사 로그 화면 `pages/audit/AuditPage`(PR #65) |
| 목업·시뮬레이션 | 이전 전후 비교(Compare 탭·대피 SecurityComparison): `lib/api/security.ts` 환경 종류별 고정 값, 항상 `simulated`, "시뮬레이션 값에는 FAIL이 없다" 주석 |
| 없는 것 | `GET /security/compare` 서버 경로(openapi에 없음) · WAS 버전 범위 통제(C-IAM-2·C-AUD-1) 증거, TLS 주기 시험(C-TLS-1) — security.md "지금은 UNKNOWN" · 게이트 실사용(꺼짐) |

### ③ AI 에이전트가 샌드박스에서 점검·수정

| 칸 | 사실 |
|---|---|
| 운영에서 지금 되는 것 | 사전 점검 API 4경로(POST·GET·logs·cancel) + 러너 API 4경로(claim·heartbeat·events·result). 실행 `06732233…` SUCCEEDED, `simulated=false`, `aiReviewed=false`, `model=null`, `sandboxId=null`, steps INPUT_LOAD·CONFIG_DIFF·ANALYZE, configDiff 8건, findings 2건(RULE·WARN), patches 0. 감사 로그에 PRECHECK_REQUESTED(USER) → AGENT_RUN_CLAIMED·FINISHED(SYSTEM `ai-runner`). 러너는 샌드박스 VM `echo-sandbox-runner`(공인 IP 없음, IAP SSH만)에서 PR #14 Draft 코드(6e461ac)로 1회 실행 |
| 화면에 보이는 것 | `pages/evacuation/{PrecheckPage,PatchReview}` — 단계·패치 diff·승인 버튼 UI |
| 목업·시뮬레이션 | 화면 전체가 브라우저 시뮬레이션: `PRECHECK_API_READY=false`, `lib/api/prechecks.ts` "AI 사전 점검 API가 생기기 전까지 브라우저 안에서 흉내", 항상 `simulated`(샌드박스 id·검증 실패 차단·패치 승인·운영 변경 거부 장면 모두 가짜). 화면 문구 "AI 사전 점검 API가 아직 없습니다…" |
| 없는 것 | 운영 실행에서 모델 호출(model=null) · 샌드박스 컨테이너 사용(sandboxId null) · 패치 생성(이슈 #5 open) · 패치 승인·`APPLY_PATCH`(prechecks.md "아직 없다(2차)"; enum·모델 칸만 있음) · 사전 점검 목록 GET(openapi에 없음). 모델 호출 자체는 PoC만: echo-ai-agent `specs/ai-1-sdk-model-sandbox.md` §9 — `claude-opus-5-5`가 Tool Runner `workspace_exec`로 `print(1)` 실행, 로컬(11/4 17:45)·샌드박스 VM(19:49) 통과 |

## (b) 배점 5항목별 증거 (사실만)

### 완성도·데모 (30)
- 운영 주소 4곳 응답: app 200 · api openapi 200(경로 50, 메서드 64) · 시연 앱 클라우드 `/api/info` 200(aws-tokyo) · 온프레 200(onprem).
- 운영 실이전 7건(`simulated=false`), 컷오버 결과 붙은 것 2건: CUTOVER `writePauseMs 5556`, ROLLBACK `7119`, 둘 다 rowsTotal 169·누락 0·중복 0, `measuredBy INFRA_SCRIPT`(rehearsal-2026-11-05-night/after.md와 일치).
- 배포 요청 최근 20건 전부 `simulated=false`(MANUAL 9 · STANDBY_SYNC 10 · ROLLBACK 1; FAILED 1·CANCELLED 1 포함).
- 시연 대본 `echo-frontend/docs/demo-script.md`(PR #62 병합) 장면 7개, 리허설 기록 칸 1~5회 비어 있음, "운영 API 불통" 대응 "정하지 않았다".
- 화면 목업 플래그 4개 false: DISASTER·EVACUATION·PRECHECK·EVENTS. 보안 비교도 시뮬레이션.

### 클라우드 활용·운영 설계 (30)
- 추상화: `GET /environment-kinds` 3종(aws·gcp·onprem) 설정 스키마, 환경 어댑터(API 서버 2·12), 실제 실행기(api-3-2).
- 무중단 이전: 진입점 VM Envoy 가중치 10→50→100, 건수 판정(api-8-1·8-2), 논리 복제 + PgBouncer 컷오버(ADR-0004).
- 롤백: 이전 중단 → ROLLED_BACK(rollbackStatus SUCCEEDED) 1건, FAILBACK 3건, 배포 되돌리기 1건, 컷오버 롤백 7119ms. 롤백 절차서 `docs/design/롤백 절차서 (B→A).md`.
- 권한: 역할 ADMIN > DEVELOPER > VIEWER + 에이전트 토큰(GET·HEAD만, 쓰기 403 `AGENT_READ_ONLY`), 이전·예외·사전 점검 만들기는 "개발자(사람만)". 감사: 조직 안 쓰기 29개 경로가 같은 트랜잭션으로 기록(audit-logs.md). echo-demo 멤버 3명(ADMIN 1 · DEVELOPER 2), 에이전트 토큰 0개, `allowSelfApproval=true`(시연용 의도 변경, 개인 조직은 false) → 이전 7건 모두 `selfApproved`.
- 인프라 보안: 장기 키 없음(OIDC·WIF·STS), 온프레 인바운드 0(터널), 실행기 최소 권한 + ValidatingAdmissionPolicy, DB 계정 4종 분리(design-infra §8).
- 재구축: AWS 환경 Terraform 재구축 13분 3초, 실패 0(`docs/rehearsals/2026-11-05-rebuild-aws.md`).
- 운영 대응: CVE-2026-98432 — GKE 업그레이드 + 유지보수 제외(g3-upgrade, rc=0), 온프레 커널 설치·재부팅(공개 healthz 다운 57초), 진입점·EKS는 이미 수정판(verify.md, echo-infra `docs/team/security/cve-2026-98432-response.md`).
- 알려진 한계 표 9행(design-infra §10): 진입점 단일 장애점, 컷오버 분리, OTel 없음, 온프레 업스트림 없음 등.

### 팀 개발·문서화 (20)
- 병합 PR 121건(was 43 · infra 34 · frontend 35 · ai-agent 5 · secure 1 · demo-app 3). 이슈 90건(closed 45 · open 45), Project #4 항목 91개.
- 설계 문서 목차 `submission/design-docs-index.md`: 저장소 문서 83개 수록(API 35 · 인프라 21 · 보안 12 · AI 5 · 프론트 7 · 시연 앱 3), 노션 공용 문서 8, ADR 4(echo-infra `docs/adr/`), 노션 ADR 표 약 25행, 팀 결정 로그 D-001~D-094 94행, 허들 요약 5개(`docs/team/huddles/`), [결정] 이슈 5건, 노션 회의록 7, Slack 허들 캔버스 링크.
- echo-was SPEC 29개(`specs/`), API 문서 12개(`docs/api/`).
- 리허설 기록: 대시보드 실이전(11/4 12:27), 합동 리허설(11/4 21:10), 컷오버 원문 로그(11/4 22:51), 새벽 리허설 전후 대조(11/5 03:24~03:35), 재구축(11/5 01:00).

### 독창성 (10)
- 환경 범위 3종: AWS 도쿄 EKS · GCP 서울 GKE · 온프레 k3s(EC2, Cloudflare Tunnel). 좌표 칸 있음(도쿄 35.68,139.69 / 서울 37.57,126.98 ×2).
- UX: 재난(지진) 시나리오 대시보드·지구본(cobe)·토폴로지, 대피 후보 비교, 온보딩 O01~O03, 한·일 언어(locales ko·ja), 휴대폰 리모컨(이슈 #28 open). 재난·대피 부분은 브라우저 시뮬레이션.

### AI 활용 (10)
- 샌드박스: GCP 별도 VPC + VM(공인 IP 없음, SA 역할 0, 443만 나감), Docker 작업 공간 `--network none`, 격리 시험 통과(PoC §9).
- 모델 호출: PoC만(Tool Runner, `claude-opus-5-5`, 도구 `workspace_exec`·`read_file`·`write_file`). 운영 사전 점검은 규칙만(model=null, aiReviewed=false).
- 코드 변경(패치): 생성·검증·승인·반영 전부 없음(이슈 #5·#6 open, APPLY_PATCH 미구현). 화면의 패치 승인은 시뮬레이션.
- AI 에이전트 이슈 8건 전부 open(Project: In Progress 2 · Todo 6).

## (c) 테마 6개

| 테마 | 판정 | 근거 |
|---|---|---|
| 무중단 이전 | 있음 | 운영 이전 7건(`simulated=false`), 컷오버 쓰기 정지 5556ms·롤백 7119ms(누락·중복 0). echo-infra `entrypoint/`·`replication/k8s/scripts/{cutover,rollback}.sh`·ADR-0004·`docs/design/이전 엔진 원리 — 논리 복제·컷오버·롤백.md`. 단, 수 초 쓰기 정지(거의 무중단)·컷오버 수동 |
| 보안·거버넌스 통합 | 부분 | 매트릭스 API 운영(UNKNOWN 9/12칸), 예외 4 ACTIVE, 게이트 꺼짐, 비교 API 없음. echo-was `docs/api/security.md`·`specs/sec-*`(10개)·`app/services/security_gate.py`. 보안·거버넌스 이슈 12 중 closed 1 |
| 온프레 기능 재현 (IAM·시크릿·감사·모니터링·백업) | 부분 | IAM: GitHub 로그인+역할(api-6, `docs/api/auth.md`) · 시크릿: 앱 변수 Secret Manager(API 10, `docs/api/variables.md`) · 감사: 감사 로그 API·화면(24줄 조회) · 모니터링: 진입점 Prometheus·Grafana만(`entrypoint/config/`) · 백업 PITR: **SPEC Draft만**(`specs/infra-14-backup-base-wal-pitr.md`, 이슈 #14 open, 관련 브랜치 없음) |
| AI 리소스·데이터 레지던시 | 없음(화면 시뮬레이션만) | 대피 후보 "데이터 위치" 점수 = `lib/api/evacuation.ts` 고정 규칙(브라우저). 러너 suggestedFix에 "데이터 위치 규정 확인" 문구(규칙). 서버·인프라 저장소에 residency 관련 파일 0 |
| AI 에이전트 × 샌드박스 | 부분 | 샌드박스 VM·러너 API·러너 1회 실행(규칙만), 모델 PoC. echo-ai-agent `src/echo_agent/{sandbox,agent,tools}.py`, PR #14 Draft, `specs/ai-1-sdk-model-sandbox.md`, echo-was `docs/api/prechecks.md`·`docs/agent-runner.md` |
| 비용·OTel 횡단 모니터링 | 부분(비용 알림·진입점 지표만) | 비용: Terraform 예산 알림 `terraform/environments/{aws,gcp}/dev/budget.tf`(80%·100%) · 지표: 진입점 Prometheus/Grafana · OTel 수집기 없음(이슈 #9 In Progress, design-infra §10 "진입점 Prometheus 만") · 화면 비용 = 대피 점수 고정 상수 |

## (d) 이슈 집계 (gh issue list, 2026-11-05 10:40 KST)

| 말머리 | closed | open | Project #4 상태(같은 말머리) |
|---|---|---|---|
| API 서버 | 15 | 2 | Done 15 · Todo 2 |
| 인프라·이전 엔진 | 14 | 8 | Done 13 · In Progress 5 · Todo 3 (#42는 Project 밖) |
| DB 백업 | 0 | 1 | In Progress 1 |
| 보안·거버넌스 | 1 | 11 | Done 1 · In Progress 5 · Todo 6 |
| AI 에이전트 | 0 | 8 | In Progress 2 · Todo 6 |
| 프론트 | 15 | 15 | Done 15 · In Progress 13 · Todo 2 |
| 합계 | 45 | 45 | Project 91항목(PR 2 포함) |

open 제목:
- API 서버: was#9 [API 서버 9] 재난(지진) 이벤트 → 자동 이전 트리거 · was#52 [API 서버 15] 기존 DB 등록·도착지 DB 생성·저장소 분석
- 인프라·이전 엔진: infra#6 단계적 트래픽 전환 + 판정 규칙 · #8 롤백(수동·자동·역방향 복제·절차서) · #9 OpenTelemetry 수집기 · #12 DR 전략 웜 스탠바이·핫 레디 · #13 온프레 랜선 분리 데모 · #33 [5.1] 진입점 단일 장애점 PoC · #34 [14] 설계 문서 인프라 절·아키텍처 그림 · #46 [5.2] Cloudflare→진입점 Full(strict)
- DB 백업: infra#14 base backup + 연속 WAL (PITR)
- 보안·거버넌스: was#26 [2] 증거 수집·정규화 · #27 [3] 규칙표·실행 허용 판정 · #28 [4] 매트릭스·증거 API · #29 [5] 이관 직전·직후 검사 + 차단 · #30 [6] 사람 승인·사전 승인 DR 실행 계약 · #31 [11] 고객 앱 CI 보안 검사 · #32 [12] 보안 감사·화면 연동·DR 리허설 · infra#21 [7] Envoy 자동 전환 목적지 자격 · #22 [8] DB 쓰기 소유권 · #23 [9] 네트워크 허용표·TLS · #24 [10] 신원 분리·최소 권한
- AI 에이전트: ai#1 [결정] SDK·모델·샌드박스 PoC · #2 샌드박스 생성·실행·로그 · #3 권한 경계 · #4 사전 점검 · #5 AI 수정안 → 샌드박스 검증 · #6 검증 게이트 + 사람 승인 반영 · #7 AI 배포 보조 · #8 기능 격차 자동 매핑
- 프론트: fe#2 API 계약 · #7 보안 매트릭스 화면 · #8 에이전트 작업 화면 · #9 감사 로그·권한 화면 · #10 설계 문서 · #11 데모 동선·리허설 5회 · #14 [4.5] 환경변수 → 시크릿 참조 · #16 [5.5] 기능 격차 매핑 표 · #17 [6.3] 긴급 복구 화면(랜선 뽑기) · #18 [6.6] 복귀 화면 · #19 [7.5] 이전 전후 보안 비교 · #28 [14] 휴대폰 리모컨 · #45 [18] 성능 측정 · #51 [19] 리허설 후속 · #56 [22] 한·일 언어

열린 PR: echo-infra #45(AWS를 GCP에서 구독 + 인프라 패치 코드화) · echo-ai-agent #14 Draft(러프 러너). echo-was 0건 · echo-frontend 0건(#62는 병합됨).

주의: 이슈 open이어도 기능 일부가 운영에 있음(예: 보안·거버넌스 4 매트릭스 API·3 예외 API, 인프라 6·8 단계 전환·롤백, 프론트 7·9 화면). 반대로 closed라도 운영 미검증 부분은 이 표가 판정하지 않음.

## (e) 운영 조회 원자료 요약

| 항목 | 값 |
|---|---|
| openapi | 경로 50 · 메서드 64. 태그: organization 13 · environment 7 · service 7 · migration-plan 8 · security-exception 5 · auth 4 · precheck 4 · runner 4 · deploy-request 3 · service-variable 3 · security 2 · audit-log 1 · 태그 없음(healthz·livez·readyz) 3 |
| app.echoport.uk | 200 |
| 시연 앱 | `demo-y6cz3jrc…/api/info` → environment aws-tokyo, host app-7594f74c45-mhzf8 · `demo-onprem-3okaz96x…/api/info` → onprem, host demo-app-7f984d7667-j7mnx |
| 환경 | aws-tokyo(aws, ap-northeast-1, 35.68/139.69, CONNECTED 11/4 10:07Z) · gcp-seoul(gcp, asia-northeast3, 37.57/126.98, CONNECTED 11/4 10:07Z) · onprem(onprem, seoul, 37.57/126.98, CONNECTED 11/5 00:31Z) |
| 서비스 demo | ACTIVE, activeMigrationPlanId 없음. aws SERVING 100 · gcp STANDBY 0 IN_SYNC · onprem STANDBY 0 IN_SYNC |
| 이전 계획 | 7건(total 7): SUCCEEDED 6 · ROLLED_BACK 1(errorCode ABORTED, rollback SUCCEEDED). `result` 채워진 것 2건(11/4 18:28 CUTOVER 5556ms · 18:31 ROLLBACK 7119ms) |
| 배포 요청 | 최근 20건(total 20 페이지): SUCCEEDED 18 · FAILED 1 · CANCELLED 1, 전부 simulated=false |
| 보안 매트릭스 | 12칸: UNKNOWN 9 · WARN 3 · PASS 0 · FAIL 0. 통제 39칸: UNKNOWN 32 · WARN 3 · PASS 3 · NA 1 · FAIL 0 |
| findings | 3건(C-IMG-2 PASS ×2, C-IMG-1 WARN ×1), 전부 RULE·REAL |
| 기한부 예외 | 4건, ACTIVE 4 |
| 사전 점검 06732233 | SUCCEEDED · simulated false · aiReviewed false · model null · sandboxId null · configDiff 8 · findings 2(WARN) · patches 0 · 로그 3줄 |
| 감사 로그 | 24줄(전부). USER 20 · SYSTEM 4. 최근 5줄: ENVIRONMENT_UPDATED(onprem) · AGENT_RUN_FINISHED · AGENT_RUN_CLAIMED · PRECHECK_REQUESTED · SECURITY_EXCEPTION_APPROVED. 종류 11가지(그중 2줄은 이름 대신 `POST …/approve` 경로 문자열 — 이름 표 이전 기록) |
| 조직 설정 | echo-demo `allowSelfApproval=true`(개인 조직 false) |
| 멤버·역할 | 3명: ADMIN 1(Saccharine1211) · DEVELOPER 2(2023146015-sys, kimdoyoung1110). VIEWER 0. 에이전트 토큰 0 |

## (f) 미검증

- app.echoport.uk에 지금 배포된 프론트 커밋이 main `d603e2d`와 같은지(Cloudflare Pages 배포 목록 안 봄). 화면 판정은 저장소 코드 기준.
- 화면을 실제로 열어 보지 않음 — 목업 여부는 코드 플래그·주석·문구로만 판정.
- 운영 echo-was 이미지가 origin/main `9d825e7`과 같은지(openapi 경로로만 간접 확인).
- 보안 게이트를 켰을 때 실제 차단·C-AI-1 PASS 동작.
- 사전 점검 목록 API가 없어 실행이 06732233 하나뿐인지 확인 못 함(감사 로그상 PRECHECK_REQUESTED 1건).
- 감사 로그 24줄은 echo-demo 조직만(다른 조직·전체 쓰기 경로 29개 커버 여부는 문서·시험 이름 기준).
- 진입점 Grafana·Prometheus가 지금 떠 있는지, 예산 알림이 실제 생성됐는지(budget.tf는 메일 변수 없으면 안 만듦 — 콘솔 예산 USD 150 주석).
- PITR 작업이 이도현 로컬·다른 이름 브랜치에 있는지(원격 브랜치 이름 `pitr|backup` 0건, 관련 PR 0건만 확인).
- echo-was #70·#71(API 9·시험 속도) 진행 상황 — 원격에 PR·브랜치 안 보임.
- Notion 문서(ADR 표·회의록·최종발표 페이지) 내용은 이번에 읽지 않음(목차 문서의 수치 인용).
