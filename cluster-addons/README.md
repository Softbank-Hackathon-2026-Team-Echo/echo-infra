# cluster-addons — 클러스터 공유 문 (API 서버 3-2 §7 P3·P4)

echo-was 실제 배포 실행기(`EXECUTOR_MODE=real`)는 앱마다 Ingress 를 만들고, 환경마다 **공유 문 하나**가 그 Ingress 들을 받는다. 환경별 앱 주소는 `{서비스}-{suffix}.{환경 하위 도메인}`, 대표 주소는 `{서비스}-{suffix}.echoport.uk`(진입점 경유). 둘 다 같은 Ingress 규칙으로 들어온다.

| 환경 | 공유 문 | 파일 | 주소 |
|---|---|---|---|
| GKE 서울 | ingress-nginx (class `nginx`), **내부** L4 LB | `gke/ingress-nginx-values.yaml` | 설치 뒤 `kubectl -n ingress-nginx get svc ingress-nginx-controller` 의 EXTERNAL-IP(10.60.x.x) |
| EKS 도쿄 | ALB 그룹 `echo-apps` 닻 Ingress (class `alb`), 공개 ALB 이지만 **진입점 VM·GKE NAT 만 허용** | `eks/anchor-ingress.yaml` | `kubectl -n echo-apps-anchor get ingress anchor` 의 ADDRESS |

왜 내부·제한인가: 앱(echo-demo-app)에 인증이 없다. 손님은 모두 진입점(34.158.202.103)으로 들어오고, 환경별 주소는 일꾼의 헬스체크가 VPC·NAT 안에서 부른다. 공개가 필요해지면 GKE 는 annotation 한 줄, EKS 는 `inbound-cidrs` 한 줄을 바꾼다(동옥 확인 뒤).

## 설치 (사람이, 데스크톱에서)

```bash
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
# GKE
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --kube-context gke_team-echo-final_asia-northeast3-a_echo-dev-gke \
  -n ingress-nginx --create-namespace -f cluster-addons/gke/ingress-nginx-values.yaml --wait
# EKS (AWS Load Balancer Controller 가 이미 kube-system 에 있다)
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
