# 실행기 자격 증명 계약 (이슈 #3, 2026-11-03)

echo-was 실행기(F1 원터치 배포)가 쓰는 자격 증명이다. 저장소·클러스터 어디에도 장기 키를 두지 않는다(NFR-17). 값은 [aws-outputs.md](aws-outputs.md)·[gcp-outputs.md](gcp-outputs.md) 출력값이 단일 출처다.

## 1. 빌드 실행기 (GitHub Actions, echo-was 저장소 `main`)

이미지 빌드 → ECR `echo/app` 과 Artifact Registry `echo/app` 에 **같은 digest** push → digest 를 echo-was 에 돌려준다.

| 클라우드 | 자격 증명 | 권한 |
|---|---|---|
| AWS | `ci_build_role_arn` (OIDC, `main` 브랜치만) | ECR `echo/*` push |
| GCP | `ci_build_service_account` + `ci_workload_identity_provider` (WIF, `main` 만) | AR `echo` writer |

워크플로 골격:

```yaml
permissions: { id-token: write, contents: read }
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with: { role-to-assume: <ci_build_role_arn>, aws-region: ap-northeast-1 }
  - uses: google-github-actions/auth@v2
    with: { workload_identity_provider: <ci_workload_identity_provider>, service_account: <ci_build_service_account> }
  - run: gcloud auth configure-docker asia-northeast3-docker.pkg.dev --quiet
  - run: aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.ap-northeast-1.amazonaws.com
  # 빌드 1회 → 두 레지스트리에 push. digest 가 같도록 같은 이미지를 태그만 바꿔 push 한다 (또는 crane copy).
```

빌드 저장소를 더하려면 두 루트의 `ci_build_repositories` 에 넣는다. GitHub OIDC `sub` 는 이름 형식과 불변 ID 형식(`repo:ORG@<id>/NAME@<id>:…`) 둘 다 허용한다.

## 2. 배포 실행기 (echo-was 일꾼, GKE `echo-was` 네임스페이스)

일꾼은 Workload Identity 로 관제탑 GSA(`control_plane_service_account`)가 된다. 이 하나의 신원으로 두 클러스터에 간다.

| 대상 | 방법 | 권한 |
|---|---|---|
| GKE `echo-dev-gke` | GSA 그대로 (`gcloud container clusters get-credentials` 또는 GKE API) | 프로젝트 `roles/container.developer` |
| EKS `echo-dev-eks` | ① GKE 메타데이터 서버에서 GSA ID 토큰: `GET http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=sts.amazonaws.com&format=full` (헤더 `Metadata-Flavor: Google`) ② `aws sts assume-role-with-web-identity --role-arn <executor_role_arn> --web-identity-token <토큰> --role-session-name echo-was` ③ 받은 임시 키로 `aws eks update-kubeconfig --name echo-dev-eks --region ap-northeast-1` | Access Entry `AmazonEKSClusterAdminPolicy` (해커톤 범위. 네임스페이스 생성이 필요해 클러스터 범위) |

ID 토큰은 1시간짜리다. 일꾼은 배포마다 새로 받는다. Python 이면 `google.auth` 의 `fetch_id_token(audience="sts.amazonaws.com")` 과 `boto3` `sts.assume_role_with_web_identity` 로 같은 일을 한다.

## 3. 트래픽 전환

`entrypoint_weights_url` 에 `PUT /weights {"aws":90,"gcp":10}` (Bearer 토큰은 Secret Manager `entrypoint_token_secret`, GSA 에 `secretmanager.secretAccessor` 를 주면 일꾼이 직접 읽는다 — 필요하면 요청).

## 4. 정리할 것 (echo-was 가 GKE 로 옮겨진 뒤)

- 지민이 손으로 만든 `echo-was-deploy` 역할·정책·Access Entry, 도쿄 ACM 인증서는 삭제한다. Terraform 으로 옮기지 않는다.
