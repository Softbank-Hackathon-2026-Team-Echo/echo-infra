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
- 복제 시험(11/7 16:39 KST): 온프레 앱에 쓰기 20건(전부 201, 0.34초) → 온프레·GCP·AWS 모두 31행, 마지막 id 31, 전체 행 md5 `a8c04f366caaf6347969c24b528a7a9a` 세 곳 일치. replay_lag GCP 약 6ms·AWS 약 35ms, 두 슬롯 밀림 0 bytes

## 장애 전환: 온프레 → GKE (GCP B2 승격 + 대기 앱)

온프레가 죽으면 GCP B2 를 원본으로 올리고, GKE 에 미리 둔 같은 앱을 켠다. AWS B2 는 그대로 두어 "온프레의 마지막 상태" 증인으로 쓴다(잃은 행 수 계산).

| 파일 | 하는 일 |
|---|---|
| `standby-app/` | GCP 고객 클러스터 `echo-data-onprem` 에 PgBouncer(→ B2) + 앱(replicas 0, 온프레와 같은 이미지 digest) |
| `scripts/simulate-down.sh down` | 온프레에 쓰기를 넣다가(`LOAD_SEC`, 기본 10초) 그 순간 nft 로 GKE NAT 의 5432 를 끊고 온프레 앱을 0 으로 내린다. 201 받은 쓰기 수를 출력 |
| `scripts/failover.sh` | B2 구독 끄기 → 시퀀스 +1000 → 대기 앱 1 → 앱으로 쓰기 1건 → AWS B2 와 비교해 잃은 행 수. `CONFIRM=yes` 필요 |
| `scripts/simulate-down.sh up` | nft 표 삭제, 온프레 앱 1 |
| `scripts/rejoin.sh` | 대기 앱 0 → 옛 구독·온프레 슬롯 정리 → B2 비우고 구독 다시 만들기(초기 복사) → 세 곳 비교. `CONFIRM=yes` 필요 |

처음 한 번 (GCP 고객 클러스터):

```bash
C=gke_team-echo-final_asia-northeast3-a_echo-dev-customer-gke
# 앱 DATABASE_URL: B2 비밀번호로 만든다(화면에 찍지 않음)
PW=$(kubectl --context $C -n echo-data-onprem get secret onprem-b2-db -o jsonpath='{.data.password}' | base64 -d)
kubectl --context $C -n echo-data-onprem create secret generic onprem-standby-app \
  --from-literal=database-url="postgresql://demo:${PW}@demo-pgbouncer:6432/demo"; unset PW
kubectl --context $C apply -k standby-app
```

시험 순서:

```bash
scripts/simulate-down.sh down          # 온프레 장애
CONFIRM=yes scripts/failover.sh        # GKE 로 전환, 잃은 행 수
scripts/simulate-down.sh up            # 온프레 복구
CONFIRM=yes scripts/rejoin.sh          # 온프레 = 원본, B2 = 복제본으로 되돌리기
```

- 승격 뒤 B2 에 쓴 행은 `rejoin.sh` 가 버린다(시험용). 온프레로 데이터를 되돌리는 복귀는 범위 밖이다.
- 손님 주소 전환(온프레 터널 주소를 GKE 로)은 다음 단계다. GKE 에 같은 Cloudflare 터널 연결기를 두면 온프레 연결기가 끊길 때 같은 주소가 GKE 로 간다.
- 서울 B(`echo-data`)와 같은 클러스터라 모든 명령은 `-n echo-data-onprem` 이다.

## 역방향: GCP 장애 시 온프레로 이전

온프레 PG 의 별도 DB `gcpcopy` 가 서울 B 의 발행 `echo_pub`(FOR ALL TABLES)를 구독한다. 도쿄 A → 서울 B → 온프레로 이어진다.
온프레가 서울 B 로 **나가는** 연결이라 온프레 인바운드는 늘지 않는다. 장애 시 온프레 메인 앱(`demo-y6cz3jrc/app`)이 `gcpcopy` 를 보게 바꾼다.

| 위치 | 설정 (11/7) |
|---|---|
| 서울 B (`echo-data/echo-pg`) | 복제 계정 `repl_gcp_onprem`(REPLICATION + pg_read_all_data), `max_slot_wal_keep_size=2GB`(ALTER SYSTEM, 재시작 없음), 외부 LB `echo-pg-external` 허용 IP 에 온프레 EIP `13.124.120.121/32` 추가 |
| 온프레 | DB `gcpcopy`(스키마는 서울 B 에서 pg_dump -s), 구독 `echo_gcp_onprem_sub`(TLS), 비밀번호 Secret `echo-demo/gcp-repl`, 앱용 Secret `demo-y6cz3jrc/gcpcopy-env` |

```bash
scripts/gcp-to-onprem.sh status                      # 구독·행 수·서울 B 와 비교
scripts/gcp-to-onprem.sh prepare                     # 앱용 Secret (기기 안에서 DB 이름만 gcpcopy 로)
CONFIRM=yes scripts/gcp-to-onprem.sh failover        # 구독 끄기 → 시퀀스 +1000 → 앱이 gcpcopy 를 봄
CONFIRM=yes scripts/gcp-to-onprem.sh back            # 앱 원래 DB 로, 구독 다시 켬
CONFIRM=yes scripts/gcp-to-onprem.sh resync          # 시험 중 쓴 행 버리고 재구독(서울 B 와 똑같이)
```

시험 (11/7 17:25~17:28 KST): failover 11.1초, 온프레 앱이 GCP 데이터 223행(빠짐·중복 0)을 보여 주고 새 쓰기 201. back·resync 뒤 서울 B 와 온프레 사본 223행·md5 일치, preflight 20/20.

- 서울 B 를 실제로 끄지 않고 온프레 쪽 구독만 끊어 시험했다. 시연 경로 영향 없음.
- 비동기라 GCP 가 갑자기 죽으면 지연만큼 마지막 쓰기를 잃을 수 있다.
- 온프레 → 서울 B 로 데이터를 되돌리는 복귀는 범위 밖이다(시험은 resync 로 버린다).

## 주의

- 스키마(DDL)는 복제되지 않는다. 온프레에 칸·표를 더하면 B2 에 먼저 더한다(예: 멱등 쓰기 `request_id`).
- 시퀀스는 복제되지 않는다. 승격 때 `setval` 로 맞춘다.
- 구독이 오래 끊기면 온프레 WAL 이 2GB 까지 쌓이고, 넘으면 슬롯이 무효화된다. 그때는 구독을 지우고 초기 복사부터 다시 한다.
- 기본은 비동기 복제다. 갑작스러운 장애 때는 복제 지연만큼 마지막 쓰기를 잃을 수 있다.
