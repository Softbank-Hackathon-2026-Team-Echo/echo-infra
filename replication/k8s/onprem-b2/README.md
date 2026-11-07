# 온프레 → GCP 서울 B2 복제 (인프라 18)

온프레 PG(`echo-demo/demo-db`, DB `demo`)를 고객 클러스터의 전용 복제본 B2(`echo-data-onprem/onprem-pg`)가 논리 복제로 구독한다.
온프레 장애 시 B2 를 승격해 GKE 에서 서비스를 다시 켠다. 서울 B(`echo-data`, 도쿄 A 구독)와 이름·네임스페이스·Secret 이 모두 달라 시연 경로에 영향이 없다.

같은 발행을 AWS 도쿄 EKS 의 복제본도 구독한다. 사본이 온프레·GCP·AWS 세 곳에 있다.

```
온프레 demo-db (발행 echo_onprem_pub, FOR ALL TABLES)
  └─ TLS 5432, 보안 그룹은 두 NAT /32 만 (terraform aws/onprem-demo replication_source_cidrs)
       ├─ GCP B2 onprem-pg (구독 echo_onprem_sub)     — 고객 GKE echo-data-onprem, 출발 IP echo-dev-nat
       └─ AWS   onprem-pg (구독 echo_onprem_sub_aws) — echo-dev-eks echo-data-onprem, 출발 IP 도쿄 NAT echo-dev
```

| 위치 | 적용 | 구독 이름 |
|---|---|---|
| GCP 고객 클러스터 | `kubectl --context <gke> apply -k gcp` | `echo_onprem_sub` |
| AWS EKS | `kubectl --context echo-dev-eks apply -k aws` (디스크만 `ebs-csi-default-sc`) | `echo_onprem_sub_aws` |

구독 이름은 온프레 쪽 복제 슬롯 이름이 되므로 위치마다 달라야 한다.

## 온프레 쪽 (11/7 기기에 적용, 매니페스트 반영은 후속)

- 커널 CVE-2026-98432 완화: nft `table inet cve_2026_98432`(IPv4 옵션 패킷 drop), systemd `cve-2026-98432-mitigation` 로 재부팅 유지
- `ssl=on`(자체 서명 Secret `demo-db-tls`), `max_slot_wal_keep_size=2GB`
- 복제 계정 `repl_onprem`(REPLICATION + pg_read_all_data), 비밀번호 Secret `demo-db-repl`
- pg_hba 맨 앞: `hostnossl all repl_onprem all reject`, `hostssl demo repl_onprem all scram-sha-256`
  - 접속 출발지가 k3s ServiceLB 를 거치며 `10.42.0.1` 로 바뀌므로 pg_hba 로는 IP 를 제한할 수 없다. IP 제한은 보안 그룹이 맡는다.
- 발행 `echo_onprem_pub`, ServiceLB `demo-db-external`(5432)

## B2 세우기

```bash
# GCP: C=gke_team-echo-final_asia-northeast3-a_echo-dev-customer-gke, O=gcp / AWS: C=echo-dev-eks, O=aws
C=gke_team-echo-final_asia-northeast3-a_echo-dev-customer-gke; O=gcp; cd replication/k8s/onprem-b2
kubectl --context $C apply -f base/00-namespace.yaml
# B2 고유 비밀번호
openssl rand -hex 24 | tr -d '\n' | kubectl --context $C -n echo-data-onprem create secret generic onprem-b2-db --from-file=password=/dev/stdin
# 온프레 복제 비밀번호: SSM 출력을 화면에 찍지 않고 바로 Secret 으로
CID=$(aws ssm send-command --region ap-northeast-2 --instance-ids <instance_id> --document-name AWS-RunShellScript \
  --parameters 'commands=["k3s kubectl -n echo-demo get secret demo-db-repl -o jsonpath={.data.password}"]' --query Command.CommandId --output text)
aws ssm get-command-invocation --region ap-northeast-2 --command-id $CID --instance-id <instance_id> --query StandardOutputContent --output text \
  | tr -d '\n' | base64 -d | kubectl --context $C -n echo-data-onprem create secret generic onprem-repl --from-file=password=/dev/stdin
kubectl --context $C apply -k $O
kubectl --context $C -n echo-data-onprem rollout status sts/onprem-pg
```

스키마 복사와 구독 (비밀번호는 파드 env 로만 쓴다). AWS 는 구독 이름을 `echo_onprem_sub_aws` 로 바꾼다:

```bash
kubectl --context $C -n echo-data-onprem exec -i onprem-pg-0 -c postgres -- bash -s <<'EOF2'
SRC="host=$SRC_HOST port=5432 dbname=demo user=repl_onprem sslmode=require"
PGPASSWORD="$SRC_REPL_PASSWORD" pg_dump -s --no-owner --no-privileges --no-publications --no-subscriptions "$SRC" | psql -X -q -U demo -d demo
psql -X -U demo -d demo <<SQL
CREATE SUBSCRIPTION echo_onprem_sub
  CONNECTION 'host=$SRC_HOST port=5432 dbname=demo user=repl_onprem password=$SRC_REPL_PASSWORD sslmode=require'
  PUBLICATION echo_onprem_pub;
SQL
EOF2
```

## 확인 (11/7 실측)

- 초기 복사: `demo.seq_write` 5행, `srsubstate=r`
- 온프레 앱에 쓰기 3건 → B2 반영 확인 0.53초(kubectl 왕복 포함)
- 발행 쪽 `pg_stat_replication`: `echo_onprem_sub` streaming, replay_lag 약 5ms, 슬롯 밀림 0 bytes
- AWS 복제본 추가 뒤 쓰기 2건: 온프레·GCP·AWS 모두 10행, replay_lag GCP 약 5ms·AWS 약 36ms, 두 슬롯 밀림 0 bytes

## 주의

- 스키마(DDL)는 복제되지 않는다. 온프레에 칸·표를 더하면 B2 에 먼저 더한다(예: 멱등 쓰기 `request_id`).
- 시퀀스는 복제되지 않는다. 승격 때 `setval` 로 맞춘다.
- 구독이 오래 끊기면 온프레 WAL 이 2GB 까지 쌓이고, 넘으면 슬롯이 무효화된다. 그때는 구독을 지우고 초기 복사부터 다시 한다.
- 기본은 비동기 복제다. 갑작스러운 장애 때는 복제 지연만큼 마지막 쓰기를 잃을 수 있다.
