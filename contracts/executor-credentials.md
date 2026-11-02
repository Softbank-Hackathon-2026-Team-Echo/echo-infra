# 실행기 자격 증명 계약 (이슈 #3, 2026-11-03)

echo-was 실행기(F1 원터치 배포)가 쓰는 자격 증명이다. 저장소·클러스터 어디에도 장기 키를 두지 않는다(NFR-17). 값은 [aws-outputs.md](aws-outputs.md)·[gcp-outputs.md](gcp-outputs.md) 출력값이 단일 출처다.

## 1. 빌드 실행기 (GitHub Actions, echo-was 저장소 `main`)

이미지 빌드 → ECR `echo/app` 과 Artifact Registry `echo/app` 에 **같은 digest** push → digest 를 echo-was 에 돌려준다.

| 클라우드 | 자격 증명 | 권한 |
|---|---|---|
| AWS | `ci_build_role_arn` (OIDC, `main` 브랜치만) | ECR `echo/*` push |
| GCP | `ci_build_service_account` + `ci_workload_identity_provider` (WIF, `main` 만) | AR `echo` writer |

워크플로 골격 (빌드 1회 → 두 레지스트리에 같은 manifest 로 push, digest 는 액션 출력으로 받는다):

```yaml
permissions: { id-token: write, contents: read }
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with: { role-to-assume: <ci_build_role_arn>, aws-region: ap-northeast-1 }
  - uses: aws-actions/amazon-ecr-login@v2
  - id: gcp
    uses: google-github-actions/auth@v2
    with: { workload_identity_provider: <ci_workload_identity_provider>, service_account: <ci_build_service_account>, token_format: access_token }
  - uses: docker/login-action@v3
    with: { registry: asia-northeast3-docker.pkg.dev, username: oauth2accesstoken, password: "${{ steps.gcp.outputs.access_token }}" }
  - uses: docker/setup-buildx-action@v3
  - id: build
    uses: docker/build-push-action@v6
    with:
      push: true
      tags: |
        <account>.dkr.ecr.ap-northeast-1.amazonaws.com/echo/app:<sha>
        asia-northeast3-docker.pkg.dev/team-echo-final/echo/app:<sha>
      cache-from: type=gha
      cache-to: type=gha,mode=max
  # steps.build.outputs.digest 가 두 레지스트리에서 같다. 이 값을 echo-was 에 돌려준다.
```

빌드 저장소를 더하려면 `terraform/modules/github-repos` 의 목록에 넣고 두 루트를 apply 한다. GitHub OIDC `sub` 는 이름 형식과 불변 ID 형식(`repo:ORG@<id>/NAME@<id>:…`) 둘 다 허용한다.

## 2. 배포 실행기 (echo-was 일꾼, GKE `echo-was` 네임스페이스)

일꾼은 Workload Identity 로 관제탑 GSA(`control_plane_service_account`)가 된다. 이 하나의 신원으로 두 클러스터에 간다.

| 대상 | 방법 | 권한 |
|---|---|---|
| GKE `echo-dev-gke` | 일꾼이 같은 클러스터 안에 있으므로 **in-cluster config** 가 가장 싸다(gcloud 불필요). 그러려면 KSA `echo-was` 에 ClusterRoleBinding 이 필요하다(요청하면 매니페스트를 준다). 밖에서 붙을 땐 GSA 액세스 토큰(메타데이터 서버, 1시간) + `gke_cluster_endpoint` 로 kubeconfig 를 만든다 | 프로젝트 `roles/container.developer` (GSA 경로) |
| EKS `echo-dev-eks` | ① GSA ID 토큰: `google.auth` `fetch_id_token(audience="sts.amazonaws.com")` (메타데이터 서버 `…/service-accounts/default/identity?audience=sts.amazonaws.com`) ② `boto3` `sts.assume_role_with_web_identity(RoleArn=<executor_role_arn>, WebIdentityToken=…)` ③ 임시 키로 `eks.describe_cluster` 1회 → endpoint·CA 캐시 ④ bearer 토큰은 presigned `GetCallerIdentity`(`k8s-aws-v1.` 접두, 15분) 로 로컬 생성. CLI 로 하면 `aws eks update-kubeconfig --name echo-dev-eks --region ap-northeast-1` | Access Entry `AmazonEKSClusterAdminPolicy` (해커톤 범위. 네임스페이스 생성이 필요해 클러스터 범위. GKE 쪽과 비대칭) |

임시 키는 1시간(ID 토큰도 1시간)이라 만료 전까지 재사용하고, 배포마다 새로 받지 않는다. 지금은 API 와 일꾼이 **같은 GSA** 다. 인터넷에 열린 API 가 뚫리면 두 클러스터 권한이 같이 넘어가므로, 시간이 나면 일꾼 전용 KSA·GSA(`echo-dev-executor`)로 분리한다(API 팀과 조율).

## 3. 트래픽 전환·측정 (`entrypoint_weights_url`, Bearer 토큰은 Secret Manager `entrypoint_token_secret`)

| 실행기 | 호출 | 응답 |
|---|---|---|
| TrafficExecutor·MainRouteExecutor | `PUT /weights {"aws":90,"gcp":10}` (합 100) | 반영된 가중치. Envoy 가 수 초 안에 바꾼다 |
| MetricsProvider | `GET /summary?window=30s` | `{"ts","window","weights","total":{"rps","error_ratio"},"envs":{"aws":{"rps","error_ratio","p95_ms","healthy_hosts","hosts","weight"},…},"prometheus":"ok"}` |
| HealthChecker(보조) | `GET /status` | 환경별 hosts·healthy (Envoy admin 기준) |

`/summary` 는 Prometheus(5초 스크레이프) 값이라 전환 직후 몇 초는 비어 있을 수 있다(`null`). RTO 는 가중치 변경 시각과 `envs.<대상>.rps` 가 올라온 시각의 차, 실패 요청 수는 `error_ratio × rps × 초` 로 echo-was 가 계산해 이전 기록에 남긴다(#10). 8080 은 `entrypoint_admin_cidrs`(echo-was 가 있는 클러스터의 NAT IP)에만 열려 있다. GSA 에 `secretmanager.secretAccessor` 를 주면 일꾼이 토큰을 직접 읽는다 — 필요하면 요청.

## 4. 정리할 것 (echo-was 가 GKE 로 옮겨진 뒤)

- 지민이 손으로 만든 `echo-was-deploy` 역할·정책·Access Entry, 도쿄 ACM 인증서는 삭제한다. Terraform 으로 옮기지 않는다.
