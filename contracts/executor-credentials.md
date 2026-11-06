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

## 3. 트래픽 전환·측정 (`entrypoint_weights_internal_url`, Bearer 토큰은 Secret Manager `entrypoint_token_secret`)

echo-was 는 GKE 에 있으므로 **내부 주소**(`http://10.60.0.6:8080`, 방화벽 `echo-dev-internal` 이 파드 대역을 허용)로 부른다. 토큰이 인터넷을 거치지 않는다. 공인 주소 `entrypoint_weights_url` 은 `entrypoint_admin_cidrs` 에서만 열리며 운영자 점검용이다.

| 실행기 | 호출 | 응답 |
|---|---|---|
| TrafficExecutor·MainRouteExecutor | `PUT /weights {"aws":90,"gcp":10}` (합 100) | 반영된 가중치. Envoy 가 수 초 안에 바꾼다 |
| 판정(건수 기반) | `GET /counters` | `{"ts","envs":{"aws":{"requests","errors_5xx","hosts"},"gcp":{…}}}` — Envoy 시작 이후 누적. Envoy admin 호스트 통계라 **즉시** 반영된다. 비율 적용 시점 값을 기준으로 잡고 1초마다 차이를 센다. 값이 줄면(호스트 교체·Envoy 재시작) 기준값을 다시 잡는다. Envoy 에 못 붙으면 503 |
| MetricsProvider(참고) | `GET /summary?window=30s` | `{"ts","window","weights","total":{"rps","error_ratio"},"envs":{"aws":{"rps","error_ratio","p95_ms","healthy_hosts","hosts","weight"},…},"prometheus":"ok"}` |
| HealthChecker(보조) | `GET /status` | 환경별 hosts·healthy (Envoy admin 기준) |

- 판정(건수 기반)은 echo-was 쪽(API 서버 8)이 한다: 비율 적용 시점 값을 기준으로 1초마다 차이를 세어 대상 환경 요청 N건이 차면 그 즉시 판정, 오류율이 허용치를 넘으면 즉시 실패, 단계별 최대 대기(예: 30초) 안에 N건이 안 차면 `INSUFFICIENT_TRAFFIC` 으로 실패→롤백. 대상 환경이 죽어 경로가 다른 환경으로 넘어가면 대상 건수가 안 올라 `INSUFFICIENT_TRAFFIC` 이 되는데 이것은 맞는 동작이다.
- `errors_5xx` 는 5xx 응답 + 연결 실패·시간 초과(클라이언트에는 503)의 합이다.
- `/summary` 는 Prometheus(5초 수집) 값이라 5초 이하 구간은 비어 있고(`null`) 전환 직후 몇 초도 비어 있을 수 있다. `error_ratio`·`p95_ms` 는 응답 코드·지연이 경로 클러스터(`aws_then_gcp`)에만 기록되는 Envoy 특성 때문에 "그 환경을 첫 순위로 하는 경로" 기준이다(환경이 건강하면 그 환경 값). 근거 화면·기록용으로만 쓴다.
- **진입점 하나 = 서비스 하나.** 가중치가 진입점 전체에 하나라 `PUT /weights` 는 모든 호스트의 비율을 함께 바꾼다. 앱이 둘 이상이면 Host 별 라우트와 `PUT /services/{public_host}/weights` 가 필요하다(후속).
- 시연용 합성 트래픽은 [entrypoint/loadgen](../entrypoint/loadgen/README.md)(GKE, 도쿄 밖)에서 진입점 공인 주소로 보낸다. 설계 문서에 "시연용 합성 트래픽"으로 밝힌다.
- GSA 에 `secretmanager.secretAccessor` 를 주면 일꾼이 토큰을 직접 읽는다 — 필요하면 요청.

## 4. 정리할 것 (echo-was 가 GKE 로 옮겨진 뒤)

- 지민이 손으로 만든 `echo-was-deploy` 역할·정책·Access Entry, 도쿄 ACM 인증서는 삭제한다. Terraform 으로 옮기지 않는다.

## 5. 실제 배포 실행기 환경 값 (API 서버 3-2, 2026-11-03)

echo-was 환경 행(`environments.config`)과 설정에 넣을 값. 주소·ARN 은 적용 뒤 확정값으로 바꾼다.

| 대상 | 칸 | 값 | 출처 |
|---|---|---|---|
| aws 환경 | `ingressDomain` | `aws-tokyo.echoport.uk` | AWS dev `var.apps_domain` |
| aws 환경 | `ingressGroup` | `echo-apps` | `cluster-addons/eks/anchor-ingress.yaml` |
| aws 환경 | `certificateArn` | `arn:aws:acm:ap-northeast-1:<ACCOUNT_ID>:certificate/<CERT_ID>`(ISSUED 뒤에 넣는다) | `acm.tf` 출력 `acm_apps_certificate_arn` |
| aws 환경 | `roleArn` | 비움 → 설정 `EXECUTOR_AWS_ROLE_ARN` = `executor_role_arn` 출력값 | §2 |
| gcp 환경 | `clusterLocation` | `asia-northeast3-a` | gcp-outputs |
| gcp 환경 | `ingressDomain` | `gcp-seoul.echoport.uk` | `cluster-addons/gke` |
| 설정 | `PUBLIC_BASE_DOMAIN` | `echoport.uk` | — |
| 설정 | `IMAGE_REGISTRY_MIRRORS` | `asia-northeast3-docker.pkg.dev/team-echo-final/echo=<ACCOUNT_ID>.dkr.ecr.ap-northeast-1.amazonaws.com/echo` | §1 |
| 설정 | `BUILD_GITHUB_WORKFLOW` | `customer-build.yml`(echo-was PR #39) | §1 |
| GSA | AR `echo` 읽기 | `google_artifact_registry_repository_iam_member.control_plane_reader`(온프레 받기 자격용, P6) | control-plane.tf |

공유 문·DNS·인증서 절차는 [cluster-addons/README.md](../cluster-addons/README.md).
