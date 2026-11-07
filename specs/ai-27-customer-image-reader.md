# AI #27 고객 이미지 읽기 권한

현재 runner SA는 고객 GAR 저장소 downloadArtifacts 권한이 없어 실제 SBOM 수집이 거절된다. `customer_image_repository` 지정 시 해당 저장소에만 `roles/artifactregistry.reader` 1개를 부여한다. 기본 null이면 생성하지 않는다. push·클러스터·프로젝트 전체 권한·장기 키를 추가하지 않는다.

2026-11-07 실제 state 대상 검토 plan: `team-echo-final / asia-northeast3 / echo`, member `echo-sandbox-runner@team-echo-final.iam.gserviceaccount.com`; add 1/change 0/destroy 0. `-target`으로 이 권한과 의존 SA만 확인했다. 다른 인프라 변경의 전체 drift 판정이 아니다. 미적용.

적용 전 담당자가 저장소 범위와 plan을 검토한다. 실제 운영 tfvars에도 변수를 유지해야 이후 apply가 권한을 제거하지 않는다. 기존 동시 작업 tfvars를 덮어쓰지 않는다. 적용 뒤 echo-runner 사용자/VM 서비스 계정으로 고객 `repository@sha256`를 Trivy CycloneDX로 읽어 확인한다. 키를 모델·고객 컨테이너로 전달하지 않는다. 회수는 변수 null로 바꾼 plan을 검토한 뒤 같은 멤버만 제거한다.

[Trivy GAR 인증 문서](https://trivy.dev/docs/dev/guide/advanced/private-registries/gar/). ADC/VM identity 사용; 읽기 성공과 WAS의 RUNNER_SBOM 저장 성공은 별도 인수한다.

## 2026-11-07 21:38 KST 적용 전 보안 시험 — 보류

사용자는 reader 적용 대신 보안 룰 선검사를 요청했다. C-CFG-1 후보/기존 설정 모두 WARN(동일 MEDIUM7·LOW2, 신규0), plan은 reader1건이다. 하지만 기존 VM echo-runner의 기본 BuildKit 빌드 RUN에서 비밀값 없는 메타데이터 hostname 경로 HTTP200이 확인됐다. network=none 빌드/health 런타임 대조군은 접근 실패했다. 토큰·Secret·본문 미수집. 기존 infra#78의 고객 코드 메타데이터 차단 조건을 충족하지 못하므로 IAM 적용은 보류한다. 이 reader가 기존 접근 경로를 새로 만든 것은 아니며, 추가 시 노출 가능한 VM 신원 범위가 넓어지는 문제다.

현재 C-IAM-2 자동검사는 WAS API 쓰기 거절만 확인하므로 VM 격리를 대신하지 않는다. 빌드 경계를 보완하고 메타데이터·내부망 거부/필요 다운로드 허용/기존 빌드 회귀를 검증한 뒤 plan을 재검토한다. 저장소 권한은 해당 저장소의 모든 이미지를 읽는 범위이며 고객 서비스/digest별로 제한하지 않는다. 사용자 IAM 승인·apply·운영 변경·팀 회신 없음. 상세는 공통 작업 공간 `notes/20261107-ai27-reader-security-review.md`와 `notes/evidence/ai-27-reader-security-20261107.json`에 기록했다.
