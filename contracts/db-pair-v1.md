# db-pair/v1 — 정적 Job 인계 계약

관련: echo-infra#105(명시 DB쌍 Job), echo-was#116(지원쌍 사전판정·DB 바인딩). 1단계 계약이며 현 실행 이미지·VAP·엔진을 활성화하지 않는다.

## 신뢰 경계

WAS 운영자 관리 등록표의 organization_id/service_id/environment_id/deployment_id→DB registry id 결합만 사용한다. host/command/credentials/secret/volume 주입 금지. B는 고객 GKE app DB, GCP_B2는 온프레 demo DB 사본이므로 대체 불가.

기존 KIND/PLAN_ID/ALLOW_PROMOTE에 SOURCE_DB, TARGET_DB, EXPECTED_WRITER_DB, DB_PAIR_CONTRACT_VERSION, DB_PAIR_REGISTRY_SHA256, ORGANIZATION_ID, SERVICE_ID, SOURCE_ENVIRONMENT_ID, TARGET_ENVIRONMENT_ID, SOURCE_DEPLOYMENT_ID, TARGET_DEPLOYMENT_ID를 추가한다. KIND는 슬롯 A→B cutover, B→A rollback, 명시 재난 A→B promote. GCP→AWS PLANNED도 rollback이다. 누락 시 임의 A/B 기본으로 내리지 않는다.

해시는 WAS Pydantic 기본값 포함 configuration(mode=json)을 sort_keys=True, separators=(',',':'), ensure_ascii=False로 직렬화한 UTF-8 SHA256이다. fixture registry는 configuration 원문과 registry_sha256를 묶는다. validator는 내용을 다시 해시한다. wrapper hash만 믿지 않는다.

## 결과 계약

receipt 필수: planId, sourceDbId, targetDbId, contractVersion, registrySha256, writerDbId(=target). ALREADY_WRITER/exit0도 예외가 아니며 행수·누락·중복 검사도 유지한다. WAS actual JUDGE가 이를 소비하지만 현재 Postgres reader/엔진은 아직 생산하지 않는다. 불일치는 DATA_INTEGRITY_FAILED·MANUAL, 자동 DB rollback 금지.

## 증거 수준

스키마·Job fixture는 짝 WAS 실제 생성 함수에서 뽑았다. validator의 observed_writer 인자는 caller가 주는 시험 값이다. 독립 DB 조회·증거 신선도·서버 admission 검사를 수행하지 않으며 live attestation이 아니다. WAS는 route/writer_path/data_sync/job_contract/writer의 UTC 증거(기본300초)를 생성·승인·worker/Job 직전에 재검사하지만 실제 DB 조작을 허용하지 않는다. 실제 Kubernetes executor도 pair 요청은 DB_PAIR_WORKER_NOT_READY로 송신 전 차단한다.

## 6방향 현재 / 목표

| 방향 | 이번 명시쌍 실행 | 잠재 adapter | 필요한 다음 입력 |
|---|---|---|---|
| AWS→GCP | NOT_READY | A/app→B/app cutover/promote만 | live writer·복제 증거·명시쌍 엔진·VAP·receipt |
| GCP→AWS | NOT_READY | B/app→A/app rollback만 | 역복제·재동기화·writer·receipt, 역방향 재난승격 설계 |
| AWS→onprem | 미등록/adapter 없음 | 없음 | 정확한 DB binding·복제/접속·쌍 엔진 |
| onprem→AWS | 미등록/adapter 없음 | 없음 | 기존 AWS 사본 인수·승격·앱 기동·재동기화 |
| GCP→onprem | 미등록/adapter 없음 | 없음 | 반대방향 복제·온프레 접속·쌍 엔진 |
| onprem→GCP | 미등록/adapter 없음 | 없음 | 기존 B2 인수·승격·앱 기동·재동기화 |

## 2단계 작업·소유권·필수 입력 (요청/재배정 아님)

| 작업 | 제안 소유자 / 원장 | 필수 입력·파일 |
|---|---|---|
| 실제 명시쌍 선택·PAUSE 직전 writer 검증·멱등 | 데이터 이전 담당 이도현 / echo-infra#105(명시 DB쌍 Job), 현재 assignee 없음 | cutover-entry.sh, replication/k8s/scripts/{common,cutover,rollback,promote}.sh, 등록 DB endpoint/구독/슬롯·허용 방향, 원본 접근 불가 시 fencing/RPO |
| 이미지·VAP 계약 | 서동옥과 데이터 담당 접점 / 같은 이슈 | 실제 사용할 digest, 새 env allowlist, 등록표 배포 version, 서버 dry-run 허용/거부 증거, 기존 Job 호환 정책 |
| cutover_runs receipt·reader | 데이터 담당+지민 / echo-infra#105(명시 DB쌍 Job), echo-was#116(지원쌍 사전판정·DB 바인딩) | A/B 양쪽 additive 컬럼/복제 호환, planId·쌍·hash·version·writer receipt, WAS postgres_cutover_runs.py 및 계획 상세 공개 |
| 온프레 복제 기반 인수·승격·재동기화 | 서동옥(기존 지정)+데이터 담당 / echo-infra#107(온프레 복제·승격), echo-infra#104(복제 인수, 미지정) | 기존 PR108/109·OPEN PR110 기반 재사용, 고객 B≠B2, replica DB 이름/환경·복제 상태·TLS 경로, 단일 writer·실패/복귀 기준 |
| 서비스 트래픽·앱→writer | 진입점 담당+지민 / echo-infra#103(온프레 가중치, 미지정) | 서비스별 origin/가중치·온프레 TLS, 네 방향 app→현재 writer 접속 증거 |
| 통합 인수 | 지민 조율 / echo-infra#106(이전 통합시험, 미지정) | 위 계약, 방향별 정상/다른 tenant/뒤집힌 쌍/재난/partial/복귀·단일 writer·RPO·행수 증거, 운영 리허설 별도 승인 |
| 화면 | 도영 / echo-frontend#98(미지원 표시) | WAS supported/status/reasons/freshness/게이트/ready 필드, false·UNKNOWN failclosed |

새 이슈/중복 착수 댓글/Slack·Notion 요청은 만들지 않았다. 이 문서가 다른 사람의 착수 약속이나 운영 권한을 대신하지 않는다. Terraform·클라우드·Secret·DB 직접 조회/변경·새 자원·배포·병합 금지 유지.
