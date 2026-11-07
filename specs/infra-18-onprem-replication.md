# 인프라 18: 온프레 → 클라우드 동기화 (GCP·AWS 전용 복제본)

- 상태: **복제까지 적용 완료(11/7).** 승격 시험·복제본 위 앱 기동은 남음(7절)
- 작성일: 2026-11-07
- GitHub 이슈: echo-infra `[인프라 18] 온프레 서비스를 클라우드로 복제하고 장애 시 클라우드에서 기동`
- PR: #108(보안 그룹 규칙), #109(복제본 매니페스트), 이 문서 PR(정리)
- 작성: 서동옥(SeoDongOk, 인프라 담당)

## 1. 왜

| 관점 | 전 | 후 |
|---|---|---|
| 온프레 데이터 | 온프레 PG 한 곳에만 있다. 이전 도구(논리 복제·컷오버·승격)는 도쿄↔서울에서만 검증됐다 | 온프레 PG 의 변경이 GCP 서울·AWS 도쿄 전용 복제본에 실시간으로 반영된다. 사본이 **세 장소·두 클라우드**에 있다 |
| 온프레 장애 | 기기가 죽으면 데이터와 서비스가 같이 멈춘다 | 복제본 하나를 승격해 클라우드에서 같은 서비스를 다시 켠다(failover, 과거로 되돌리기가 아니라 최신 상태로 다른 곳에서 켜기) |

온프레 랜선 분리 데모(#13)는 하지 않기로 했고, 이 작업이 그 자리를 대신한다.

## 2. 구조

```
온프레 echo-demo/demo-db (PostgreSQL 17.11, 발행 echo_onprem_pub FOR ALL TABLES)
  └─ TLS 5432 (k3s ServiceLB demo-db-external), 보안 그룹은 두 NAT /32 만
       ├─ GCP 서울 고객 GKE  echo-data-onprem/onprem-pg  구독 echo_onprem_sub      (출발 IP GKE Cloud NAT `echo-dev-nat`)
       └─ AWS 도쿄 EKS       echo-data-onprem/onprem-pg  구독 echo_onprem_sub_aws  (출발 IP 도쿄 NAT `echo-dev`)
```

- 복제 대상: 기존 `echo-demo/demo-db`(DB `demo`). 앱 두 개(`echo-demo/demo-app`, echo-was 가 배포한 `demo-y6cz3jrc/app`)가 이 DB 를 쓴다. 표는 `demo.seq_write` 하나.
- 서울 B(`echo-data`, 도쿄 A 구독)와 이름·네임스페이스·Secret 을 모두 나눴다. 도쿄↔서울 시연 경로는 바뀌지 않는다.
- 매니페스트: `replication/k8s/onprem-b2/`(base + gcp/aws 오버레이, AWS 는 디스크 종류만 다름). 온프레 쪽: `onprem/replication-source.sh`.

## 3. 결정

| # | 결정 | 이유 |
|---|---|---|
| D-1 | PostgreSQL 논리 복제(ADR-0004) | 온프레 PG 가 이미 `wal_level=logical`, 도쿄↔서울과 같은 도구 |
| D-2 | 외부 큐(Redis Stream·Debezium) 없음 | 원본 WAL 과 복제 슬롯이 이미 순서 보장 큐다. 외부 큐를 더해도 갑작스러운 장애 때 온프레 밖으로 못 나간 변경의 양은 같다 |
| D-3 | 기본 비동기, 동기는 선택 | 동기(`synchronous_standby_names` + `remote_apply`)는 확인된 쓰기 손실 0 대신 쓰기 지연과 "복제본 장애 시 원본 쓰기 정지"를 산다 |
| D-4 | 구독 이름 = 위치마다 다름 | 구독 이름이 온프레 쪽 슬롯 이름이 된다 |
| D-5 | `max_slot_wal_keep_size=2GB` | 복제본이 오래 끊겨도 온프레 디스크(19G, 여유 11G)를 채우지 않는다. 넘으면 슬롯 무효 → 구독을 다시 만들어 초기 복사 |
| D-6 | DB·계정 이름을 온프레와 같게(`demo`/`demo`) | 승격 뒤 앱 `DATABASE_URL` 모양이 같다. 비밀번호는 복제본마다 고유 |

## 4. 보안: 인바운드 0 원칙의 예외

온프레는 "들어오는 포트 0(터널만)"이 원칙이었다. 이 작업으로 **5432 하나가 예외**가 된다.

| 층 | 조치 |
|---|---|
| 네트워크 | 보안 그룹 5432 를 두 NAT `/32` 만(`terraform/environments/aws/onprem-demo` `replication_source_cidrs`, 기본 빈 목록 = 규칙 없음, `/32` 만 허용하는 검증) |
| 암호화 | `ssl=on`(자체 서명, 키는 기기 밖으로 나가지 않음) |
| 인증 | 복제 계정 `repl_onprem`(REPLICATION + `pg_read_all_data`)만. pg_hba 맨 앞 `hostnossl all repl_onprem all reject`, `hostssl demo repl_onprem all scram-sha-256`. 평문 접속 거부 확인 |
| IP 제한 위치 | k3s ServiceLB 를 지나며 출발지가 `10.42.0.1` 로 바뀌어 pg_hba 로는 IP 를 거를 수 없다. **IP 제한은 보안 그룹이 맡는다** |
| 커널 | 온프레 커널은 11/5 수정판 `7.0.0-1017-aws`(D-093). 그래도 5432 를 열기 전에 nft 완화(IPv4 옵션 패킷 drop, `onprem/hosts/cve-2026-98432-nft.sh`)를 추가 방어로 넣었다 |
| 비밀값 | 구독 비밀번호는 SSM 출력 → k8s Secret 으로 바로 옮기고 파드 env 로만 쓴다(화면·파일·명령 인자 0) |

## 5. 손실 기준

- 계획된 전환(쓰기 정지 → 지연 0 확인 → 승격): 손실 0.
- 갑작스러운 장애: 비동기 복제 지연만큼 마지막 쓰기를 잃을 수 있다. 잃은 행 수를 기록한다.
- 온프레는 진입점 뒤에 없어 요청 기록·재생(12.4)으로 보충할 수 없다.
- 시연 앱 멱등 쓰기(12.4, `Idempotency-Key` → `request_id`)는 클라우드 배포 3곳은 켜져 있고 온프레 두 앱은 꺼져 있다(`request_id` 칸 없음). 켜려면 온프레와 두 복제본에 칸을 먼저 더한다.

## 6. 실측 (11/7)

| 위치 | 행 수 | replay_lag | 슬롯 밀림 |
|---|---|---|---|
| 온프레(원본) | 10 | - | - |
| GCP 고객 GKE | 10 | 약 5ms | 0 bytes |
| AWS 도쿄 EKS | 10 | 약 36ms | 0 bytes |

- 초기 복사 5행 `srsubstate=r`, 온프레 앱 쓰기 → GCP 반영 확인 0.53초(kubectl 왕복 포함).
- 온프레 앱 `readyz` 200 유지(PG 재시작 1회, 수십 초).

## 7. 남은 것

- [ ] 승격 시험(온프레 접속 불가 가정): 구독 끊기 → 시퀀스 맞춤(`setval`) → 승격 전후 행 수. `promote.sh` 는 A/B 컨텍스트·`echo-data/echo-pg-0`·DB `app` 에 묶여 있어 일반화가 필요하다(인프라 12.3)
- [ ] 복제본에 앱을 붙여 GKE 또는 EKS 에서 쓰기 받기
- [ ] (선택) 동기 복제 시험 1회와 쓰기 지연 측정
- [ ] 온프레 `install.sh` 에 복제 출발점 준비를 선택 단계로 넣기(지금은 `replication-source.sh` 를 따로 돌린다)

## 8. 범위 밖

- 진입점 업스트림에 온프레 편입, echo-was 재난 버튼 연동, 클라우드 → 온프레 복귀, WAL 아카이브·CDC 같은 나가는 방향 전용 구성(인바운드 0 환경용 확장안)
