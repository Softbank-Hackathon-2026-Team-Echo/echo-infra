# 온프레 k3s (이슈 #2)

리눅스 기기 한 대를 Echo 의 **온프레 환경**으로 만든다. k3s 위에 관리 대상 앱(echo-demo-app + PostgreSQL 17 + PgBouncer)을 올리고, Cloudflare Tunnel 로 `https://<이름>.echoport.uk` 공개 주소를 붙인다. 설계 원칙은 **어느 기기에서든 같은 방법**이다. EC2·맥 노트북 안 리눅스 VM·사무실 PC가 모두 같은 `install.sh` 를 쓰고, CPU 는 amd64·arm64 둘 다 된다.

```text
                         ┌──────────── 온프레 기기 (리눅스 아무거나) ────────────┐
브라우저 ─HTTPS─▶ Cloudflare ◀─나가는 연결─ cloudflared ─▶ Traefik ─Host─▶ demo-app ─▶ PgBouncer ─▶ PostgreSQL
                         │                (k3s 파드 2개)   (k3s 기본)                (transaction)   (local-path)
                         └────────────────────────────────────────────────────────┘
                           들어오는 포트 0개. 공인 IP·공유기 설정이 필요 없다.
```

## 두 층

| 층 | 무엇 | 파일 |
|---|---|---|
| ① 기기 준비 (기기마다 다름, 얇게) | 리눅스 한 대를 마련하고 `install.sh` 를 그 안에서 돌린다 | `hosts/ec2-ssm.sh` (EC2), `hosts/lima.sh` (macOS), 그 밖의 리눅스는 직접 실행 |
| ② 온프레 설치 (모든 기기 같음) | k3s → 앱·DB → 터널 커넥터 → 기기 안 확인 | `install.sh`, `manifests/` |

`install.sh` 는 다시 돌려도 같은 결과가 된다. 있는 것은 두고 바뀐 값만 반영하며, DB 비밀번호는 처음 한 번만 만든다.

| 환경 변수 | 기본값 | 뜻 |
|---|---|---|
| `DEMO_HOST` | `demo.onprem.localhost` | 앱 주소(Ingress host). 터널 공개 주소와 같아야 한다 |
| `CF_TUNNEL_CREDENTIALS_FILE` | 없음 | 터널 자격 증명 JSON. 없으면 터널 없이 기기 안에서만 확인한다 |
| `ECHO_ENVIRONMENT` | `onprem` | 앱 화면·장부에 남는 환경 이름 |
| `DEMO_IMAGE` | GHCR 공개 이미지 digest | echo-demo-app `image` 워크플로가 게시(amd64+arm64). 클라우드 로그인 없이 받는다 |
| `K3S_VERSION` | `v1.36.5+k3s1` | k3s 버전 고정 |
| `SWAP_SIZE_MB` | `2048` | 메모리 3GB 미만이고 스왑이 없으면 만든다(0 이면 안 만듦) |

## 터널 준비 (관리 기기에서 한 번)

터널은 지민 개인 Cloudflare 계정의 `echoport.uk` 영역에 있다. 자격 증명은 저장소에 두지 않는다.

```bash
brew install cloudflared
cloudflared tunnel login                                    # 브라우저에서 echoport.uk 승인 → ~/.cloudflared/cert.pem
cloudflared tunnel create --credentials-file ./tunnel.json echo-onprem-demo
cloudflared tunnel route dns echo-onprem-demo demo-onprem-<무작위 8자>.echoport.uk   # 프록시 CNAME 생성
```

- 터널 하나에 커넥터가 여러 기기에서 붙으면 Cloudflare 가 요청을 나눠 보낸다. 기기를 옮길 때는 이전 기기의 `cloudflared` 를 먼저 내린다(`k3s kubectl -n cloudflared delete deploy/cloudflared`).
- 커넥터는 모든 주소를 Traefik 으로 넘긴다. 앱을 더할 때는 Ingress 하나 + `cloudflared tunnel route dns` 한 줄이면 되고 터널 설정은 바꾸지 않는다.
- 주소는 `echoport.uk` 바로 아래 한 단계라 Cloudflare 무료 인증서(`*.echoport.uk`)가 덮는다.

## 기기별 실행

### AWS EC2 (시연 기기, 서울 t3.small)

```bash
# 1) 기기 만들기 — terraform/environments/aws/onprem-demo (backend.hcl 은 .example 복사)
terraform -chdir=terraform/environments/aws/onprem-demo init -backend-config=backend.hcl
terraform -chdir=terraform/environments/aws/onprem-demo apply
# 2) 터널 자격 증명을 SSM SecureString 에 (한 번). 기기가 직접 읽는다 — 명령 기록에 비밀값이 남지 않는다
aws ssm put-parameter --type SecureString --name /echo/onprem-demo/cf-tunnel-credentials --value file://tunnel.json
# 3) 설치 (SSM Run Command, 들어오는 포트 없음)
DEMO_HOST=demo-onprem-<8자>.echoport.uk onprem/hosts/ec2-ssm.sh <instance_id> --tunnel
```

기기 안에 들어가 볼 때는 `aws ssm start-session --target <instance_id>`(session-manager-plugin 필요)를 쓴다. SSH 22 는 열지 않는다.

### macOS (노트북을 온프레로)

```bash
brew install lima
DEMO_HOST=demo-onprem-<8자>.echoport.uk CF_TUNNEL_CREDENTIALS_FILE=./tunnel.json onprem/hosts/lima.sh
limactl stop echo-onprem        # 멈추기 · limactl delete -f echo-onprem 지우기
```

### 그 밖의 리눅스 (사무실 PC·라즈베리파이 등, systemd 필요)

```bash
sudo DEMO_HOST=demo-onprem-<8자>.echoport.uk CF_TUNNEL_CREDENTIALS_FILE=./tunnel.json ./install.sh
```

지우기는 `sudo /usr/local/bin/k3s-uninstall.sh`(k3s·데이터 전부).

## 확인

```bash
curl https://<DEMO_HOST>/healthz     # {"status":"ok"}        DB 안 봄
curl https://<DEMO_HOST>/readyz      # {"status":"ready"}     PgBouncer → PostgreSQL
curl https://<DEMO_HOST>/api/info    # {"environment":"onprem",...}
```

11/3 확인한 기기:

| 기기 | CPU | 결과 |
|---|---|---|
| M1 맥북 안 Lima VM (Ubuntu 24.04) | arm64 | 설치 + 터널 공개 주소 200, 재실행 12초(바뀐 것 없음) |
| AWS 서울 EC2 t3.small (Ubuntu 24.04, 2GB + 스왑 2GB) | amd64 | 설치 1분 35초, 공개 주소 200, 쓰기 5건 누락 0·중복 0, 공인 IP 80 직접 접속 차단 |

## echo-was 실행기 연결 (k3s 창구 + 실행기 신원)

echo-was 실제 실행기(API 서버 3-2)는 이 k3s 에 고객 앱을 직접 배포한다. 기기에 들어오는 포트는 여전히 0개다. 창구(쿠버네티스 API)도 같은 터널로 연다.

```text
echo-was 일꾼 ─HTTPS(Bearer SA 토큰)─▶ Cloudflare(K3S_API_HOST) ─터널─▶ cloudflared ─HTTPS(클러스터 CA 검증)─▶ kubernetes.default.svc
```

| 무엇 | 어디 |
|---|---|
| 창구 주소 규칙 | `K3S_API_HOST` 를 주면 `manifests/cloudflared.yaml` 의 `# __K3S_API_RULE__` 자리에 들어간다. 원본 인증서는 클러스터 CA 로 검증(`caPool` + `originServerName`, `noTLSVerify` 아님) |
| 실행기 신원 | `manifests/echo-executor.yaml`: SA `echo-system/echo-executor` + 만료 없는 토큰 Secret `echo-executor-token` |
| 권한 | 클러스터: 네임스페이스 get·list·create·delete, 노드 get·list(환경 카드의 노드 수 읽기, 읽기 전용), RoleBinding get·create, ClusterRole `echo-app-deployer` bind 만. 앱 네임스페이스 안: 실행기가 만든 RoleBinding 으로 `echo-app-deployer`(Deployment·ReplicaSet·Service·Secret·Ingress 쓰기, Pod·로그·이벤트 읽기) |
| 울타리 | ValidatingAdmissionPolicy `echo-executor-managed-namespaces`: 이 SA 는 `app.kubernetes.io/managed-by=echo-was` 라벨 네임스페이스만 만들고 지우며, RoleBinding 은 그 안에서 `echo-app-deployer` → 자기 자신만 |

```bash
# 1) 창구 주소 DNS (관리 기기에서 한 번, 프록시 CNAME). 시연 기기는 k3s-k2f6xje5.echoport.uk
cloudflared tunnel route dns echo-onprem-demo k3s-<무작위 8자>.echoport.uk
# 2) 설치(다시 돌려도 됨) — 기존 앱·터널은 그대로, 창구 규칙·실행기 신원만 더해진다
DEMO_HOST=demo-onprem-<8자>.echoport.uk K3S_API_HOST=k3s-<8자>.echoport.uk onprem/hosts/ec2-ssm.sh <instance_id> --tunnel
# 3) 토큰을 echo-was 비밀 저장소로(평문이 SSM 출력·화면에 남지 않게 봉인해서 꺼낸다)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out k.pem && openssl pkey -in k.pem -pubout -out k.pub
onprem/hosts/ec2-ssm-executor-token.sh <instance_id> k.pub > sealed.txt
onprem/hosts/ec2-ssm-executor-token.sh --open k.pem < sealed.txt \
  | gcloud secrets versions add echo-dev-echo-was-onprem-executor-token --data-file=-
rm -f k.pem k.pub sealed.txt
```

확인: `curl https://<K3S_API_HOST>/version` → 401(토큰 없음, 창구까지 닿음). 토큰을 붙인 `GET /api/v1/namespaces/kube-system` 은 200, `kubectl --as=system:serviceaccount:echo-system:echo-executor create ns x` 는 정책으로 거절.

## 한계·다음 이슈

- **고정 진입점(Envoy)에 세 번째 갈래로 붙이기는 #13 몫이다.** Envoy 는 지금 `{서비스}.echoport.uk` Host 를 그대로 넘기는데, 온프레는 터널(Cloudflare)을 거쳐야 닿는다. Envoy 업스트림을 `demo-onprem-…echoport.uk:443` 으로 두면 TLS(SNI)와 Host 바꾸기(`host_rewrite_literal`)가 필요하다. 그대로 `*.echoport.uk` 를 보내면 와일드카드 레코드가 Envoy 자신을 가리켜 고리가 생긴다. 온프레 Ingress 가 고정 Host 도 받게 하는 방법도 있다.
- echo-was 의 실제 온프레 실행기(배포 = Ingress·디플로이먼트 적용 + DNS 한 줄)는 #3 몫이다. 지금 앱은 이 스크립트가 직접 올렸다.
- 실제 사무실 온프레라면 이 구성 그대로 공인 IP 없이 동작한다. 시연 기기가 EC2 인 것은 비용·편의 때문이고, EC2 의 공인 IP 는 나가는 길(NAT 대신)로만 쓴다. 이 IP 는 EIP 로 고정한다 — 진입점 9090 remote write 방화벽이 이 IP/32 만 허용하기 때문이다(`terraform output public_ip`, 멈췄다 켜도 그대로).
- DB 는 기기 디스크(local-path) 한 곳에만 있다. 백업·복제는 #7·#12·#14 몫이다.
