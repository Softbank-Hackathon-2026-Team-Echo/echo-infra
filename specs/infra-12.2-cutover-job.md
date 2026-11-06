# 인프라·이전 엔진 12.2: 컷오버 Job — 이미지 · 전용 신원 · RBAC · VAP

- 상태: 운영 적용 (11/6 — 이미지 push·매니페스트 B·A apply, Job 실행 시험 전)
- 확인일: 2026-11-05
- 노션 계획서: https://app.notion.com/p/DB-infra-12-40f8bee9ada480b69563c0e7f643b1c3 (3절 안 C, 4-2절 I1~I3)
- GitHub 이슈: echo-infra #67 · 상위 #12 · 결정 #65(① 안 C — 서동옥·김형래 11/5 동의)
- 저장소: `echo-infra` · 브랜치 `feat/cutover-job`
- 작성: 이도현
- 근거: #65 김형래 리뷰(조건 1~4), #67 서동옥 리뷰(RBAC 는 쿠버네티스 매니페스트로, Job 이 PAUSE 중 죽으면 RESUME)

## 1. 목표

운영자 노트북에 기대던 컷오버를 **서울 GKE `echo-ops` 의 Job** 으로 옮긴다. echo-was(#75)는 Job 을 만들고 상태·로그만 읽는다. DB 권한은 Job 전용 신원에만 둔다.

## 2. 범위

### 포함
- 이미지 `replication/cutover-job/Dockerfile` + 진입점 `cutover-entry.sh`(kubeconfig 두 개, A·B 주소를 Service 에서 읽기, KIND → 스크립트)
- 쿠버네티스 매니페스트 `replication/cutover-job/manifests/`: echo-data Role(A·B), GKE·EKS 바인딩, echo-ops(네임스페이스·KSA·echo-was Role·VAP)
- Terraform: `gcp/dev/cutover.tf`(GSA + Workload Identity), `aws/dev/cutover.tf`(전용 역할 + access entry, 클러스터 정책 없음), Google OIDC 공급자 client id 에 컷오버 GSA 추가, 출력값 3개
- 스크립트: SIGTERM·INT·HUP 을 쓰기 정지 단계별로 처리(`guard_install`), promote 는 B 만 RESUME
- `.gitattributes`: 셸 스크립트 LF 고정(Windows 체크아웃에서 CRLF 면 컨테이너 bash 가 실패)
- 시험: `replication/cutover-job/tests/policy-test.sh`(k3s), `replication/k8s/scripts/tests/run.sh` 10-2(SIGTERM)

### 제외
- echo-was 쪽 Job 생성·판정(echo-was#75)
- echo-was 실행기 권한 축소(`container.developer`·EKS ClusterAdmin) → #24 후속(마감 뒤, 서동옥·김형래 합의)
- ~~운영 apply·이미지 push~~ → 11/6 적용, 적용 파일은 `replication/cutover-job/deploy/`(README "운영 적용 기록")

## 3. 완료 기준 (이슈 #67)

- [ ] 운영자가 Job 을 만들면 노트북 없이 컷오버 → 롤백이 끝나고 `cutover_runs` 에 행이 남는다 — **운영 적용 뒤**
- [x] ~~echo-was KSA 로 `echo-data` exec 거부~~ → #24 후속으로 옮김(지금 echo-was 권한이 더 넓음). 대신 **컷오버 신원**의 can-i 를 남김 — `policy-test.sh` 1·2
- [x] 템플릿과 다른 Job(이미지·SA·명령·환경 변수·볼륨·privileged)은 VAP 에 막힌다 — `policy-test.sh` 4·5 (15가지 거부, 클러스터 관리자 포함)
- [ ] 쓰기 정지 시간이 노트북 실행과 크게 다르지 않다 — **운영 적용 뒤** (Job 기동 시간은 정지 창 밖)
- [x] `scripts/check.sh` 의 fmt·validate — Docker `hashicorp/terraform:1.16.4` 로 fmt -check 통과, gcp·aws validate 통과 (tflint 는 이 PC 에 없어 못 돌림)

## 4. 시험 결과 (로컬, 2026-11-05)

| 시험 | 결과 |
|---|---|
| `replication/cutover-job/tests/policy-test.sh` (k3s v1.36.5-k3s1) | 38 통과 · 0 실패 |
| `replication/k8s/scripts/tests/run.sh` (Postgres 17 × 2, 10-2 SIGTERM 포함) | 79 통과 · 0 실패 |
| 이미지 빌드·실행 | kubectl v1.36.6, aws-cli 2.39.4, bc, uid 65532, 잘못된 KIND·클러스터 밖 실행 → 종료 1(바뀐 것 없음), 출력에 자격 증명 없음 |
| Terraform | fmt -check 통과, gcp/dev·aws/dev validate 통과 |

## 5. 위험

- 이미지를 다시 빌드하면 digest 가 바뀌어 VAP 를 다시 적용해야 한다(잊으면 Job 이 거부됨 → 안전한 쪽으로 실패)
- 도쿄가 죽으면 EKS `describe-cluster` 가 실패할 수 있다 → 진입점은 A 컨텍스트 없이 계속 가고, 스크립트의 `a_reachable` 이 "닿지 않음"으로 본다(promote 경로)
- SIGKILL·노드 유실은 잡을 수 없다 → echo-was 가 Job 실패를 보고 쓰기 담당을 다시 확인
