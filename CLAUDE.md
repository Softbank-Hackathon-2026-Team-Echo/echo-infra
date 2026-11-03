# Echo 인프라·이전 엔진 (echo-infra)

Team Echo 멀티 클라우드 관리 플랫폼의 **인프라와 이전 엔진**이다. AWS(EKS)·GCP(GKE)·온프레(k3s) 환경을 Terraform·Argo CD 로 세우고, 서비스 이전(트래픽 전환·데이터 동기화·롤백)을 맡는다. 지금은 AWS state 버킷(bootstrap)과 AWS 기반 SPEC 까지 있다.

- **스택**: Terraform 1.16.x, AWS provider ~> 6.67.0, Google provider ~> 8.9.0, tflint
- **배경·실행·세팅**: [README.md](README.md) 참조 (여기서 중복하지 않는다)
- **원장**: 본선 필수 기능 정리 `final_features_v6.md`(F1~F17, NFR). 기능 번호는 이 원장을 따른다.

---

## 규칙 문서 (반드시 따른다)

작업 전 아래 문서를 우선한다. **충돌 시 우선순위: 용어 사전 > 코드 규칙 > 일반 관례.**

| 문서 | 언제 본다 |
|---|---|
| [.claude/rules/term-dictionary.md](.claude/rules/term-dictionary.md) | 용어·식별자를 정할 때. 팀 기준은 echo-was 용어 사전이고, 여기는 인프라 추가 용어만 |
| [.claude/rules/terraform-conventions.md](.claude/rules/terraform-conventions.md) | Terraform 코드(버전·구조·이름·태그·비밀값·검사·참고 코드 가져오기)를 쓸 때 |
| [.claude/rules/git-conventions.md](.claude/rules/git-conventions.md) | 커밋 메시지·브랜치명을 정할 때 — Conventional Commits 규칙 |

## 설계 문서

| 문서 | 언제 본다 |
|---|---|
| [specs/](specs/) | 작업 단위 SPEC. 이슈 1개 = 브랜치 1개 = SPEC 1개 |
| [contracts/aws-outputs.md](contracts/aws-outputs.md) · [contracts/gcp-outputs.md](contracts/gcp-outputs.md) | 다른 파트에 넘기는 출력값 이름을 바꾸거나 더할 때. 대역 표는 aws-outputs.md 가 단일 출처 |
| [docs/references.md](docs/references.md) | 다른 저장소 코드를 가져오거나 참고할 때 |

---

## 구조

```text
terraform/
├─ bootstrap/{aws,gcp}/        # state 버킷 (관리자 로컬 state 1회 적용)
├─ environments/aws/dev/       # AWS 환경 루트 (VPC·EKS·ECR·Budgets·CI 역할)
├─ environments/gcp/dev/       # GCP 환경 루트 (VPC·NAT·GKE·Artifact Registry·Budgets·CI 연합)
├─ environments/aws/onprem-demo/ # 시연에서 온프레로 간주하는 EC2 한 대 (서울, 인바운드 0)
└─ modules/                    # 재사용 모듈 (필요할 때)
onprem/                    # 온프레 k3s: 어느 리눅스 기기든 install.sh 하나로 (hosts/ = 기기별 준비)
entrypoint/                # 고정 진입점 Envoy·weights-api·Prometheus·Grafana (entrypoint.tf 가 VM 에 싣는다)
replication/               # 이전 엔진 — 논리 복제·컷오버·롤백 PoC(docker) + 도쿄 A 실배포 매니페스트(k8s/aws-tokyo/)
contracts/                 # 다른 파트와의 출력값 계약
specs/                     # 작업 SPEC
scripts/check.sh           # fmt → validate → tflint
docs/references.md         # 참고·가져온 코드 기록
```

---

## 핵심 원칙 (요약)

- **저장소에 비밀값 0건**(NFR-17). 실제 `*.tfvars`·`backend.hcl`·state·kubeconfig 는 커밋하지 않는다. 비밀번호는 Secrets Manager 에 두고 echo-was 는 `aws-sm:` 으로 참조한다.
- **apply 는 사람이 plan 을 확인한 뒤에만.** 계정·비용이 걸린 명령(apply·destroy)은 실행 전에 사용자에게 확인한다.
- **AWS CLI·Terraform 은 프로필 `echo`** 로 실행한다(`AWS_PROFILE=echo`). 다른 프로필(개인 계정)은 쓰지 않는다. GCP 는 `gcloud auth application-default login` 의 ADC 로, 서비스 계정 키 파일은 만들지 않는다.
- **출력값 이름은 contracts 가 단일 출처.** 바꾸면 PR 체크리스트에 적는다.
- **환경 하나를 명령 2개 이내로 다시 세운다**(NFR-16). 손으로 콘솔에서 만든 리소스는 남기지 않는다.
- **다른 파트의 결정은 대신 내리지 않는다.** DB 위치(#4·#7)는 데이터 담당이 정하고, 이 저장소는 요청이 오면 반영한다. (11/2 20시 회의: 고정 진입점 #5 와 측정·관측 #9·#10 은 인프라 담당이 맡는다. 온프레 #2 는 일단 범위 밖 → 11/3 담당 지민이 진행, `onprem/`)
- **AWS·GCP 리소스를 손으로 만들거나 dev 루트를 apply 하는 것은 인프라 담당(서동옥) 확인 뒤에 한다.** 급해서 먼저 만들었으면 `managed-by=<이름>-manual` 태그를 붙이고 이슈에 적는다. Terraform 으로 옮길 때 import 블록을 쓴다(PR #16 참고).
- 참고 코드는 파일 단위로 옮기고 출처를 커밋 본문과 `docs/references.md` 에 남긴다. 라이선스 없는 저장소는 허락 뒤에.

---

## 도구

- **버전**: Terraform `1.16.4`(`.terraform-version`), tflint `0.64.0`.
- **검사**: `bash scripts/check.sh` — `terraform fmt -check -recursive` → 루트별 `init -backend=false` + `validate` → `tflint --recursive`. provider 는 `~/.terraform.d/plugin-cache` 를 같이 쓴다.
- **품질 게이트**: Claude Code PreToolUse 훅(`.claude/settings.json`)이 `git add`·`git commit` 전 `scripts/check.sh`, `git push` 전 `terraform fmt -check` 를 돌려 실패 시 차단한다(180초 제한). 파일 편집은 Edit/Write 도구로 한다.
- **PR 본문**: `write-pr` 스킬(`.claude/skills/write-pr/`)이 `.github/PULL_REQUEST_TEMPLATE.md` 구조로 `docs/PR.md`(gitignore)를 작성한다. push·PR 생성은 사람이 한다.
