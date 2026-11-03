# 인프라·이전 엔진 2: 온프레 k3s 구축 + 퍼블릭 URL 노출 SPEC

- 상태: 구현·적용 완료 (11/3)
- GitHub 이슈: echo-infra #2 `[인프라·이전 엔진 2] 온프레 k3s 구축 + 퍼블릭 URL 노출`
- 저장소: `echo-infra` · 브랜치 `feat/onprem-k3s`
- 작성: 김지민

## 1. 목표

완료 기준(이슈 원문): 온프레에 배포한 앱에 외부에서 퍼블릭 URL로 접속된다. 어느 PC·VM을 쓸지는 11/1 회의 결정을 따른다.

11/1 회의 기록에는 기기를 정한 문구가 없어 11/3 지민이 아래처럼 정했다. 11/2 20시 회의의 "온프레 #2 는 일단 범위 밖" 기록은 담당(지민)이 진행하는 것으로 바뀐다.

## 2. 결정

| # | 결정 | 선택 | 이유 |
|---|---|---|---|
| D-1 | 시연 기기 | 클라우드 VM 하나를 온프레로 간주 | 시연 편의. 개발·리허설은 맥에서 한다 |
| D-2 | VM 위치 | AWS 서울 EC2 t3.small (나중에 바꿔도 됨) | 출발 환경(도쿄)과 다른 곳, 크레딧 사용, 프리 플랜 허용 기종 |
| D-3 | 설계 원칙 | **어느 기기에서든 같은 방법** | 시연은 VM 이어도 노트북·사무실 PC로 옮길 수 있어야 한다 |
| D-4 | 공개 방식 | Cloudflare Tunnel (나가는 연결) | D-3: 공인 IP·포트 개방·공유기 설정 없이 동작. DNS 가 이미 Cloudflare |
| AD-1 | 위치 | `onprem/`(install.sh·manifests·hosts) + `terraform/environments/aws/onprem-demo/`(별도 state) | 기기 준비(①)와 설치(②)를 나눈다 |
| AD-2 | k3s | `v1.36.5+k3s1` 고정, 기본 Traefik | 11/3 stable |
| AD-3 | 터널 | 지민 Cloudflare 계정의 이름 있는 터널 `echo-onprem-demo`, 자격 증명은 기기 안 Secret 에만 | 저장소 비밀값 0건 |
| AD-4 | 이미지 | echo-demo-app `image` 워크플로가 GHCR 공개 이미지(amd64+arm64) 게시, digest 고정 | ECR·AR 은 클라우드 로그인이 필요해 D-3 에 어긋남 |
| AD-5 | DB | 클러스터 안 PostgreSQL 17 + PgBouncer(transaction), local-path, 비밀번호는 설치 때 무작위 1회 | 로컬 compose·CI 와 같은 구성 |
| AD-6 | 주소 | `demo-onprem-<무작위 8자>.echoport.uk`, `ECHO_ENVIRONMENT=onprem` | 한 단계라 무료 인증서가 덮음 |
| AD-7 | EC2 접속 | 인바운드 0, SSM Run Command·Session | 실제 온프레처럼 들어오는 문이 없다 |
| AD-8 | 범위 밖 | Envoy 세 번째 갈래(#13), echo-was 실제 온프레 실행기(#3), 랜선 분리 장면(#13) | 이슈 범위 유지 |

## 3. 만든 것

- `onprem/install.sh`: 리눅스(amd64·arm64, systemd) 기기에서 k3s → 앱·DB → (선택) 터널 커넥터 → `/healthz`·`/readyz`·`/api/info` 확인. 재실행 안전, 작은 기기는 스왑 자동.
- `onprem/manifests/`: 네임스페이스, 앱·DB·PgBouncer·Ingress, cloudflared(2개, 모든 주소 → Traefik).
- `onprem/hosts/lima.sh`(macOS), `onprem/hosts/ec2-ssm.sh`(EC2, 자격 증명은 SSM SecureString 에서 기기가 직접 읽음).
- `terraform/environments/aws/onprem-demo/`: 기본 VPC, 인바운드 없는 보안 그룹, SSM 역할(+ `/echo/onprem-demo/*` 읽기), Ubuntu 24.04 t3.small(크레딧 standard, IMDSv2, gp3 20GB 암호화).

## 4. 확인 (11/3)

| AC | 확인 |
|---|---|
| 외부에서 퍼블릭 URL 접속 | EC2: `https://demo-onprem-3okaz96x.echoport.uk` `/healthz`·`/readyz`·`/api/info`(`environment=onprem`)·화면 200, 쓰기 5건 201·누락 0·중복 0 |
| 어느 기기에서든 | M1 Lima VM(arm64)에서 같은 스크립트·같은 터널로 공개 주소 200(`environment=onprem-lima`), 재실행 12초 |
| 들어오는 포트 없음 | 보안 그룹 인바운드 0개, 공인 IP 80 직접 접속 연결 안 됨 |
| 저장소 비밀값 0 | 터널 자격 증명·DB 비밀번호는 기기 안 Secret 과 SSM SecureString 에만 |

## 5. 비용

EC2 t3.small 서울 약 $0.02/시간 + 공인 IPv4 $0.005/시간 + gp3 20GB → 하루 약 $0.65(크레딧). Cloudflare Tunnel·GHCR 공개 이미지 무료. 지우기: `terraform destroy`(state 버킷은 남음), 터널은 `cloudflared tunnel delete echo-onprem-demo`.
