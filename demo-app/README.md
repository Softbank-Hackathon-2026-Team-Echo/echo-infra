# demo-app — 관리 대상 앱을 EKS·GKE 에 올리는 매니페스트

지민의 [echo-demo-app](https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-demo-app)(순번 쓰기 + 화면)을 두 클라우드에 **같은 묶음**(앱 + PgBouncer + PostgreSQL 17)으로 올린다. 온프레는 `onprem/install.sh` 가 같은 묶음을 k3s 에 올린다. 진입점(Envoy)은 환경별 주소 하나씩만 알면 되므로, 이 디렉터리의 목적은 **`entrypoint_upstreams` 에 적을 주소를 만드는 것**이다.

| 환경 | 오버레이 | 외부 주소 | 왜 |
|---|---|---|---|
| GKE 서울 | `overlays/gcp` | 내부 패스스루 LB IP (`10.60.0.7`) | 진입점 VM 이 같은 VPC 라 공개 IP 가 필요 없다 |
| EKS 도쿄 | `overlays/aws` | 공개 NLB DNS (IP 대상, AWS Load Balancer Controller) | 진입점(GCP)에서 인터넷으로 온다. 앱에 인증이 없어 진입점 VM·GKE NAT 에서만 받는다 |

이미지는 digest 로 고정(`base/kustomization.yaml`, `onprem/install.sh` 와 같은 값). 디스크는 클러스터 기본 StorageClass(GKE `standard-rwo`, EKS `ebs-csi-default-sc`). 손으로 올리는 리소스라 `managed-by=dongok-manual` 라벨을 붙인다(CLAUDE.md).

## 올리기

```bash
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"   # gke-gcloud-auth-plugin
kubectl --context gke_team-echo-final_asia-northeast3-a_echo-dev-gke apply -k demo-app/overlays/gcp
kubectl --context echo-dev-eks apply -k demo-app/overlays/aws    # aws eks update-kubeconfig --profile echo --region ap-northeast-1 --name echo-dev-eks --alias echo-dev-eks
```

DB 비밀번호는 **Secret `echo-demo/demo-db`**(키 `password`, `database-url`)에서만 읽는다. 저장소에는 없고, 클러스터마다 운영자가 처음 한 번 만든다(`onprem/install.sh` 의 "DB 비밀번호 생성" 과 같은 방식: 무작위 값, `database-url = postgresql://demo:<값>@demo-pgbouncer:6432/demo`). Secret 이 없으면 파드가 `CreateContainerConfigError` 로 기다린다.

주소 확인:

```bash
kubectl --context gke_team-echo-final_asia-northeast3-a_echo-dev-gke -n echo-demo get svc demo-app   # EXTERNAL-IP (내부)
kubectl --context echo-dev-eks -n echo-demo get svc demo-app                                        # EXTERNAL-IP (NLB DNS)
```

그 값을 `terraform/environments/gcp/dev/terraform.tfvars` 의 `entrypoint_upstreams` 에 적고 `make plan CLOUD=gcp` → apply → 진입점 VM 에서 `sudo google_metadata_script_runner startup`. NLB DNS 는 Service 를 지웠다 다시 만들면 바뀐다.

## 아직 아닌 것

- DB 는 환경마다 따로다. 도쿄 A → 서울 B 논리 복제(`replication/`, 도현)와 잇는 것은 다음 단계(`DATABASE_URL` 만 바꾸면 된다).
- echo-was 의 실제 배포 실행기(인프라 3)가 생기면 이 수동 적용은 그 실행기가 대신한다.
