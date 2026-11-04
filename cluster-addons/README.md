# cluster-addons — 클러스터 공유 문 (API 서버 3-2 §7 P3·P4)

echo-was 실제 배포 실행기(`EXECUTOR_MODE=real`)는 앱마다 Ingress 를 만들고, 환경마다 **공유 문 하나**가 그 Ingress 들을 받는다. 환경별 앱 주소는 `{서비스}-{suffix}.{환경 하위 도메인}`, 대표 주소는 `{서비스}-{suffix}.echoport.uk`(진입점 경유). 둘 다 같은 Ingress 규칙으로 들어온다.

| 환경 | 공유 문 | 파일 | 주소 |
|---|---|---|---|
| GKE 서울 | ingress-nginx (class `nginx`), **내부** L4 LB | `gke/ingress-nginx-values.yaml` | 설치 뒤 `kubectl -n ingress-nginx get svc ingress-nginx-controller` 의 EXTERNAL-IP(10.60.x.x) |
| EKS 도쿄 | ALB 그룹 `echo-apps` 닻 Ingress (class `alb`), 공개 ALB 이지만 **진입점 VM·GKE NAT 만 허용** | `eks/anchor-ingress.yaml` | `kubectl -n echo-apps-anchor get ingress anchor` 의 ADDRESS |

왜 내부·제한인가: 앱(echo-demo-app)에 인증이 없다. 손님은 모두 진입점(34.158.202.103)으로 들어오고, 환경별 주소는 일꾼의 헬스체크가 VPC·NAT 안에서 부른다. 공개가 필요해지면 GKE 는 annotation 한 줄, EKS 는 `inbound-cidrs` 한 줄을 바꾼다(동옥 확인 뒤).

## 적용된 값 (2026-11-03 밤, 동옥)

| 항목 | 값 | 상태 |
|---|---|---|
| GKE ingress-nginx 내부 IP | `10.60.0.8` | 설치됨, 진입점 VM 에서 404 확인 |
| EKS 닻 ALB | `echo-dev-apps-1403429363.ap-northeast-1.elb.amazonaws.com` | 80·443(ACM), SG 는 34.158.202.103·34.64.211.218 |
| ACM `*.aws-tokyo.echoport.uk` | `arn:aws:acm:ap-northeast-1:706878591119:certificate/a3bc8739-5af0-43d9-b7ad-64e64639dfe8` | 11/3 23:33 ISSUED, 11/4 닻 Ingress 443 적용. 진입점 VM 에서 `https://probe.aws-tokyo.echoport.uk/` 404 + Amazon 인증서 확인 |
| cert-manager 와일드카드 | `ingress-nginx/wildcard-gcp-seoul-tls` | 적용됨(지민). 진입점 VM 에서 `https://probe.gcp-seoul.echoport.uk/` 404 + Let's Encrypt 인증서 확인 |

진입점 업스트림은 11/4 01:30 공유 문으로 바꿨다(`aws` = 닻 ALB:80, `gcp` = 10.60.0.8:80, Envoy 가 본 healthy aws 2·gcp 1). 그 뒤로 진입점으로 오는 요청은 실행기가 올린 앱 Ingress 에만 닿고, 수동 `demo-app/` 은 더 쓰지 않는다(실제 배포가 한 번 성공한 뒤 내린다). 닻의 `/healthz` 는 Envoy 헬스체크용 고정 200 이다.

## 설치 (사람이, 데스크톱에서)

```bash
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
# GKE
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --kube-context gke_team-echo-final_asia-northeast3-a_echo-dev-gke \
  -n ingress-nginx --create-namespace -f cluster-addons/gke/ingress-nginx-values.yaml --wait
# EKS: AWS Load Balancer Controller(권한은 Terraform lbc.tf 의 Pod Identity, 컨트롤러는 helm) → 닻 Ingress
VPC=$(aws ec2 describe-vpcs --region ap-northeast-1 --filters Name=tag:Name,Values=echo-dev --query 'Vpcs[0].VpcId' --output text)
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --version 3.6.2 -n kube-system --kube-context echo-dev-eks \
  --set clusterName=echo-dev-eks --set region=ap-northeast-1 --set vpcId=$VPC --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller --set replicaCount=1
kubectl --context echo-dev-eks apply -f cluster-addons/eks/anchor-ingress.yaml
```

## 그 다음

1. 두 주소를 진입점 업스트림으로: `terraform/environments/gcp/dev/terraform.tfvars` 의 `entrypoint_upstreams = { aws = "<ALB DNS>:80", gcp = "<nginx 내부 IP>:80" }` → `make plan CLOUD=gcp` → apply → VM `sudo google_metadata_script_runner startup`(IAP: `gcloud compute ssh echo-dev-entry --zone asia-northeast3-a --tunnel-through-iap`). 그 전까지는 `demo-app/` 수동 배치 주소가 업스트림이다.
2. Cloudflare(DNS 담당): `*.gcp-seoul.echoport.uk` A → nginx 내부 IP(VPC 안에서만 의미 있음), `*.aws-tokyo.echoport.uk` CNAME → ALB DNS, ACM 검증 CNAME(`terraform output acm_validation_records`, AWS dev 루트). 모두 DNS only.
3. ACM 이 ISSUED 되면 `eks/anchor-ingress.yaml` 의 `listen-ports` 에 `{"HTTPS":443}` 과 `alb.ingress.kubernetes.io/certificate-arn: <ARN>` 을 더해 다시 apply. echo-was aws 환경 config `certificateArn` 도 같은 ARN.
4. (P4 나머지) cert-manager + Let's Encrypt DNS-01 와일드카드(`*.gcp-seoul.echoport.uk`)를 Secret `ingress-nginx/wildcard-gcp-seoul-tls` 로. 파일은 `gke/cert-manager/`, Cloudflare API 토큰(P8)은 Secret Manager `echo-dev-echo-was-cloudflare-dns-token`(echoport.uk DNS 편집·영역 읽기만). ingress-nginx 를 먼저 설치해 `ingress-nginx` 네임스페이스가 있어야 한다.

   ```bash
   helm repo add jetstack https://charts.jetstack.io && helm repo update
   helm upgrade --install cert-manager jetstack/cert-manager --version v1.21.3 \
     --kube-context gke_team-echo-final_asia-northeast3-a_echo-dev-gke \
     -n cert-manager --create-namespace -f cluster-addons/gke/cert-manager/values.yaml --wait
   gcloud secrets versions access latest --secret=echo-dev-echo-was-cloudflare-dns-token \
     | kubectl --context gke_team-echo-final_asia-northeast3-a_echo-dev-gke -n cert-manager \
         create secret generic cloudflare-dns-token --from-file=api-token=/dev/stdin
   kubectl --context gke_team-echo-final_asia-northeast3-a_echo-dev-gke apply -f cluster-addons/gke/cert-manager/wildcard-gcp-seoul.yaml
   kubectl --context gke_team-echo-final_asia-northeast3-a_echo-dev-gke -n ingress-nginx get certificate wildcard-gcp-seoul   # READY True
   ```

   ingress-nginx 는 Secret 이 생기면 다시 시작하지 않아도 기본 인증서를 바꿔 쓴다. 확인: VPC 안(echo-was 파드)에서 `https://<아무 이름>.gcp-seoul.echoport.uk` 의 인증서 발급자가 Let's Encrypt 인지.

## GKE cert-manager 적용 상태와 확인 (11/4)

위 4) 는 **손으로 적용돼 있다**(Terraform·Argo CD 아님, 지민이 Helm·kubectl 로 적용, 라벨 `managed-by=jimin-manual`). 환경을 다시 세우면 4) 의 명령을 그대로 다시 돌린다. 손으로 만든 자원 전체 목록은 [docs/manual-resources.md](../docs/manual-resources.md).

| 대상 | 값 | 확인 명령 (GKE 컨텍스트 `gke_team-echo-final_asia-northeast3-a_echo-dev-gke`) | 정상 |
|---|---|---|---|
| Helm release | `cert-manager` v1.21.3, ns `cert-manager` | `helm -n cert-manager list` | STATUS `deployed` |
| 컨트롤러 3개 | cert-manager · cainjector · webhook | `kubectl -n cert-manager get deploy` | 모두 READY 1/1 |
| Cloudflare 토큰 Secret | `cert-manager/cloudflare-dns-token` (값은 Secret Manager 에서 옴) | `kubectl -n cert-manager get secret cloudflare-dns-token` | 존재 (값은 출력하지 않는다) |
| 발급자 | ClusterIssuer `letsencrypt-dns` | `kubectl get clusterissuer letsencrypt-dns` | READY True |
| 인증서 | Certificate `ingress-nginx/wildcard-gcp-seoul` → Secret `wildcard-gcp-seoul-tls` | `kubectl -n ingress-nginx get certificate wildcard-gcp-seoul` | READY True |
| 서버가 내주는 인증서 | `*.gcp-seoul.echoport.uk` | VPC 안(echo-was 파드)에서 `https://<아무 이름>.gcp-seoul.echoport.uk` | 발급자 Let's Encrypt |

2026-11-04 확인: Deployment 3개 1/1, ClusterIssuer·Certificate 모두 Ready(Certificate "is up to date and has not expired").
