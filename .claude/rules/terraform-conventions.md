# Terraform 규칙

- **적용 대상**: `terraform/` 아래 모든 루트와 모듈
- **함께 보기**: 용어는 [term-dictionary.md](term-dictionary.md), 커밋·브랜치는 [git-conventions.md](git-conventions.md)

## 1. 버전

- Terraform `1.16.x` (`.terraform-version`), AWS provider `~> 6.67.0`. `.terraform.lock.hcl` 은 커밋한다.
- 버전을 올릴 때는 PR 하나로 따로 올린다.

## 2. 구조

```text
terraform/
├─ bootstrap/<cloud>/          # state 저장소. 관리자가 로컬 state 로 1회 적용
├─ environments/<cloud>/<env>/ # 실제 환경 루트. backend 는 bootstrap 출력값
└─ modules/<name>/             # 재사용 모듈
```

- 루트마다 `versions.tf`(terraform·provider·default_tags), `variables.tf`, `main.tf` 또는 주제별 파일, `outputs.tf`, `backend.hcl.example`.
- 다른 파트가 쓰는 출력값은 [contracts/](../../contracts/) 에 이름을 고정한다. 이름을 바꾸면 PR 체크리스트에 적는다.

## 3. 이름과 태그

- 리소스 이름 접두어는 `var.project`(`echo`). 사람이 읽는 이름은 `<project>-<env>-<역할>`(`echo-dev-eks`).
- 환경 이름은 RFC 1123 label 로 echo-was 환경 이름과 맞춘다(`aws-tokyo`).
- 모든 리소스는 provider `default_tags` 로 `project`·`env`·`managed-by`·`repo` 태그를 받는다.

## 4. 비밀값

- 저장소에 비밀값 0건(NFR-17). 실제 `*.tfvars`·`backend.hcl`·state·kubeconfig 는 커밋하지 않는다(`.gitignore`).
- 비밀번호는 `ephemeral` 리소스와 `*_wo` 인자로 state 에 남기지 않고 Secrets Manager 에 둔다. echo-was 는 `aws-sm:<이름|ARN>` 으로 참조한다.
- CI 는 장기 액세스 키 대신 GitHub OIDC 역할을 쓴다.

## 5. 검사

- `scripts/check.sh` = `terraform fmt -check` → 루트별 `init -backend=false` + `validate` → `tflint`. 커밋 전 훅이 같은 스크립트를 돌린다.
- `apply` 는 사람이 plan 을 확인한 뒤에만 한다. 자동 적용은 CI 를 만들 때 따로 정한다.

## 6. 참고 코드 가져오기

- 다른 저장소(예선 `iris-infra` 등)의 코드를 가져올 때는 **파일 단위로** 옮기고, 커밋 메시지 본문에 `원본: <repo>@<commit> <경로>` 와 바꾼 점을 적는다. [docs/references.md](../../docs/references.md) 표에도 남긴다.
- 라이선스가 없는 저장소는 원작자 허락을 받은 뒤에 가져온다.
