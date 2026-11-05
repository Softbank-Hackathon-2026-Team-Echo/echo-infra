# 인프라 9 후속: 온프레 시연 기기 공인 IP 를 EIP 로 고정

- 상태: 구현 · 적용 (지민 승인 11/5 23:50 "비용 없으면 그대로 진행")
- 확인일: 2026-11-05
- GitHub 이슈: echo-infra #9 (OTel 수집기) 후속
- 저장소: `echo-infra` · 브랜치 `feat/onprem-eip`
- 작성: 김지민

## 1. 목표

진입점 Prometheus remote write(9090) 방화벽 `echo-dev-entry-remote-write` 가 온프레 EC2 공인 IP/32 하나만 연다. 지금 IP(3.36.77.175)는 자동 할당이라 기기를 멈췄다 켜면 바뀌고, 그러면 온프레 수집기의 remote write 가 막힌다. EIP 로 고정해 허용 목록이 바뀌지 않게 한다.

## 2. 확인된 사실 (11/5, 읽기 전용)

| 사실 | 근거 |
|---|---|
| `i-051fe56358de1235a` `echo-onprem-demo` 는 이 루트 state(`aws/onprem-demo/terraform.tfstate`)의 `aws_instance.host` | S3 state |
| 공인 IP 3.36.77.175 는 자동 할당, 리전 EIP 0개 | `ec2 describe-instances`·`describe-addresses` |
| 들어오는 트래픽은 cloudflared 터널(나가는 연결)이라 IP 와 무관 | `onprem/README.md` |

## 3. 범위

- 포함: `aws_eip.host`(domain vpc) + `aws_eip_association.host` + 출력 `public_ip`, 문서 두 줄(`docs/manual-resources.md`, `onprem/README.md`)
- 제외: `associate_public_ip_address` 변경(인스턴스 재생성), 들어오는 규칙(0개 유지), GCP dev 루트를 remote state 로 묶기(tfvars 손 갱신 유지)

## 4. 완료 기준

- `-target=aws_eip.host -target=aws_eip_association.host` plan 이 2 add · 0 change · 0 destroy (인스턴스 replace 없음)
- apply 뒤 `describe-instances` PublicIp = EIP, SSM·터널(온프레 환경 주소 200) 복구
- GCP dev tfvars `entrypoint_remote_write_cidrs = ["<EIP>/32"]` → 방화벽 1 change · 0 destroy, 진입점 a·b 에서 `http_requests_total{cloud_provider="onprem"}` 새 샘플

## 5. 영향·되돌리기

- 연결 순간 나가는 IP 가 바뀌어 기존 TCP(수집기 remote write·cloudflared·SSM)가 다시 붙는다(수십 초). 방화벽 갱신 전까지 온프레 9090 은 막힌다
- 비용: 공인 IPv4 는 연결 여부와 무관하게 $0.005/시간. 연결하면 자동 IP 가 풀려 EIP 로 바뀌므로 추가 비용 0. 기기를 멈추면 EIP 는 놀고 있는 IP 로 같은 값이 계속 붙는다
- 되돌리기: 두 자원 `-target` destroy(자동 IP 를 새로 받음, 값이 바뀜) → tfvars CIDR 를 새 IP 로 → 방화벽 apply
