# 인프라·이전 엔진 12.4: 진입점 요청 기록 + 승격 때 재생

- 상태: 구현 (2026-11-06, 로컬 시험 통과 · 운영 적용 전, 모두 기본 꺼짐)
- 확인일: 2026-11-05
- 노션: [split brain 문제 해결](https://app.notion.com/p/40f8bee9ada4801292d7ddc09211cb46) (해결 방안 b)
- GitHub 이슈: (만들 예정) · 상위 #12 · 관련 #68(12.3 승격) · 짝 SPEC echo-demo-app `specs/infra-12.4-idempotent-writes.md`
- 저장소: `echo-infra` · 브랜치 `feat/request-journal` · 짝 echo-demo-app `feat/idempotent-writes`
- 작성: 이도현
- 진행 방식(11/5 회의): 담당자별 사전 허락 없이 진행하되 **기존 동작은 바꾸지 않고 추가만**, 끝나면 추가한 부분만 정리해서 공유

## 1. 목표

도쿄 A 가 응답 없이 죽어 서울 B 를 승격할 때(12.3 `promote.sh`), **A 에만 들어가고 B 로 복제되지 않은 쓰기를 잃지 않게** 한다. 진입점(서울 GCP VM, Envoy)이 쓰기 요청을 받아 둔 뒤, 승격 직후 새 쓰기를 받기 전에 그 요청을 B 에 다시 보낸다.

```text
A: 1 2 3 4 5        B: 1 2 3   (4·5 는 아직 복제 전)
지금:   A 죽음 → B 승격 → 6 7 8              → 1 2 3 6 7 8   (4·5 누락)
12.4:   A 죽음 → 쓰기 막기 → B 승격 → 기록 재생(3 이하 건너뜀, 4·5 들어감) → 쓰기 풀기 → 6 7 8
                                                         → 1 2 3 4 5 6 7 8
```

노션 b안의 순서("큐 조회 → 4·5 로 B 최신화 → 승격")와 결과가 같다. B 앱은 PgBouncer 백엔드가 B 로 바뀐 뒤에야 B 에 쓸 수 있으므로, **승격(백엔드 전환) → 재생 → 쓰기 풀기** 순서로 하고, 그동안 새 쓰기는 진입점에서 막아 "새 쓰기보다 재생이 먼저"를 지킨다.

## 2. 현재 맥락과 확인된 사실 (11/5)

- 모든 고객 쓰기는 대표 주소 → Cloudflare → **서울 GCP VM 진입점 Envoy** 를 지난다. 도쿄가 죽어도 진입점은 살아 있다.
- Envoy `http_filters` 는 지금 `envoy.filters.http.router` 하나뿐이다(`entrypoint/config/envoy/envoy.yaml`, 정적). 라우트·클러스터는 weights-api 가 만드는 파일 xDS(`/etc/envoy/dynamic/*.yaml`)다.
- 시연 앱 `POST /api/writes` 는 본문 `{}`, 번호는 `max(n)+1`(advisory lock 으로 직렬화). 다시 보내면 새 행이 생긴다 → 멱등 키가 필요(짝 SPEC).
- Envoy 는 HCM 에서 `x-request-id` 를 붙이므로(없으면 생성) 기록 서비스와 업스트림 앱이 **같은 값**을 본다.
- 진입점은 두 대다(인프라 5.1, PR #53: 보조 VM + Cloudflare 다중 A 레코드).
- 열린 PR #71(OTel)이 `entrypoint/docker-compose.yml`·`weights-api/app.py`·startup 스크립트를 바꾼다 → 이 작업은 #71 머지 뒤에 그 위에서 시작하거나, 겹치는 줄을 피한다.
- `resync-a.sh`(12.3)는 A 의 복제 대상 표를 비우고 B 에서 다시 복사한다. 재생으로 4·5 가 B 에 있으면 A 도 다시 1~8 이 된다.

## 3. 범위

### 포함
- `entrypoint/journal/`(새 디렉터리): 요청 기록 서비스(Python, weights-api 와 같은 모양). Envoy `ext_authz` HTTP 서비스
- `entrypoint/config/envoy/envoy.yaml`: `router` 앞에 `ext_authz` 필터 하나 추가(기본 꺼짐)
- `entrypoint/docker-compose.yml`: journal 서비스·볼륨 추가
- `replication/k8s/scripts/replay.sh`(새): 기록을 B 앱에 다시 보냄
- `replication/k8s/scripts/promote-with-replay.sh`(새): hold → `promote.sh` → `replay.sh` → release
- 시험: journal 단위 시험, `replication/k8s/scripts/tests/` 에 재생 시나리오 추가
- 문서: `entrypoint/README.md`·`replication/k8s/README.md` 에 절 추가, 절차서 5절에 "재생" 하위 절

### 제외
- 기존 `promote.sh`·`cutover.sh`·`rollback.sh`·`resync-a.sh` 본문 수정 (새 스크립트가 감싼다)
- echo-was 가 재생을 부르는 일, 결과 화면 칸 추가(#75 응답 모양 변경 → 계약 변경이라 지민·도영 확인 필요)
- 결제·메일 같은 외부 부수 효과가 있는 요청(다시 보내면 두 번 일어남) — 한계로 기록
- 진입점을 거치지 않는 쓰기(환경별 주소 직접 호출) — 기록되지 않음
- 운영 적용(진입점 재배포)은 이 SPEC 의 완료 기준 밖. 공지 스레드 → 적용 → 결과 답글 방식으로 따로

## 4. 결정

| ID | 결정 | 근거 |
|---|---|---|
| D-1 | 스위치는 모두 **기본 꺼짐**. 꺼져 있으면 지금과 동작이 같다 | 회의 결정(추가만) |
| D-2 | 기록 서비스가 죽거나 느리면 쓰기를 **통과**(Envoy `failure_mode_allow: true`) | 시연 앱이 기록 때문에 멈추면 안 됨 |
| D-3 | 기록은 서울 VM 로컬 디스크 SQLite, 기록 뒤 커밋(WAL + `synchronous=FULL`) 후 허용 응답 | 진입점과 같은 VM, 외부 의존 없음 |
| D-4 | 보관은 **최근 15분**(설정값). 지난 것은 지움 | 복제 지연 최대값(초 단위)보다 충분히 김 |
| D-5 | 기록 대상은 쓰기 메서드(POST·PUT·PATCH·DELETE)만. GET 등은 기록 없이 바로 허용 | 라우트 파일(weights-api 생성)을 건드리지 않기 위해 서비스 안에서 거름 |
| D-6 | `Authorization`·`Cookie`·`Proxy-Authorization` 헤더는 기록하지 않음. 본문은 최대 64 KiB | 비밀값 저장 0(NFR-17) |
| D-7 | 멱등 키 = `Idempotency-Key` 헤더, 없으면 `x-request-id` | 기록과 앱이 같은 값을 봄 |
| D-8 | 재생은 서울 B 앱에 **직접**(환경별 주소) 보냄. 진입점을 다시 거치지 않음 | 재생 동안 진입점은 쓰기를 막고 있음 |
| D-9 | 재생 동안 진입점이 쓰기에 `429` + `Retry-After: 2` | 새 쓰기(6·7·8)가 재생(4·5)보다 먼저 들어가면 번호·의미가 달라짐. 503 이 아닌 이유: Envoy 는 인가 서비스의 5xx 를 고장으로 보고 `failure_mode_allow` 로 통과시킨다(구현 중 확인) |
| D-10 | 재생은 **받은 순서대로** 하나씩 | 시연 앱 `n = max(n)+1` 이 A 와 같은 번호를 내려면 순서가 같아야 함 |
| D-11 | 기록은 **주 진입점 VM 에만** 켬. 보조 VM 은 꺼진 채 | 기록이 두 곳으로 나뉘면 합치는 규칙이 필요. 보조로 넘어간 동안의 쓰기는 기록되지 않음(한계) |
| D-13 | journal 포트를 둘로: 확인 8081(도커 네트워크 안, Envoy 만) · 관리 8082(토큰) | 확인 포트를 밖에 열면 누구나 가짜 쓰기를 기록에 넣고, 그게 재생 때 서울 DB 에 들어간다(구현 중 확인) |
| D-12 | `promote-with-replay.sh` 는 어느 단계에서 실패해도 release 를 부른다(trap). 단 `promote.sh` 가 종료 2(부분 상태)면 hold 를 유지하고 사람을 부른다 | 부분 상태에서 쓰기를 열면 갈라짐 위험 |

## 5. 인터페이스

### 5.1 journal 서비스 (진입점 VM, 컨테이너)

| 경로 | 누가 | 내용 |
|---|---|---|
| `ext_authz` 확인 (Envoy → `POST /check/*` 등 원래 경로 그대로) | Envoy | 쓰기면 기록 후 200, hold 중이면 503, 그 외 200 |
| `GET /status` | 운영자 | `{"enabled", "hold", "count", "oldest", "newest"}` |
| `POST /hold` · `POST /release` | 운영자·스크립트 | 쓰기 막기 켜기/끄기. 다시 불러도 같은 결과 |
| `GET /entries?since=<ISO8601>` | `replay.sh` | 받은 순서의 기록 목록(메서드·경로·Host·멱등 키·본문 base64·받은 시각) |

- 관리 경로는 토큰(Bearer) 필요, 포트는 weights-api 처럼 `entrypoint_admin_cidrs` 에서만 연다. 토큰은 VM 첫 부팅 때 만들어 Secret Manager 에 둔다(weights 토큰과 같은 방식).
- 설정: `JOURNAL_ENABLED=false`, `JOURNAL_RETENTION_SECONDS=900`, `JOURNAL_MAX_BODY_BYTES=65536`, `JOURNAL_DB=/data/journal.db`

### 5.2 Envoy 필터

```yaml
- name: envoy.filters.http.ext_authz
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz
    http_service:
      server_uri: { uri: journal:8081, cluster: journal, timeout: 0.2s }
      authorization_request:
        allowed_headers: { patterns: [{ exact: x-request-id }, { exact: idempotency-key }, { exact: host }] }
    with_request_body: { max_request_bytes: 65536, allow_partial_message: true }
    failure_mode_allow: true
    filter_enabled:
      default_value: { numerator: 0, denominator: HUNDRED }   # 기본 꺼짐
      runtime_key: journal.enabled
```

켜기: Envoy admin `POST /runtime_modify?journal.enabled=100` 또는 런타임 파일. 끄기: `=0`.
`journal` 클러스터는 정적 클러스터로 `envoy.yaml` 에 추가(동적 `clusters.yaml` 은 weights-api 소유라 건드리지 않음).

### 5.3 스크립트

```text
promote-with-replay.sh   (REPLAY_ON_PROMOTE=false 면 promote.sh 만 exec — 지금과 같음)
  journal POST /hold
  promote.sh                    종료 0 → 계속 · 종료 1 → release 후 1 · 종료 2 → hold 유지, 2
  replay.sh  since = B pg_stat_subscription.last_msg_receipt_time − 여유(30초)
             journal GET /entries → 순서대로 B 앱(환경별 주소)에 같은 메서드·경로·본문·멱등 키로 보냄
             결과: 보냄 N · 새로 들어감 M · 이미 있음 K · 실패 F
  journal POST /release
```

- 재생 응답 판정: 201 = 새로 들어감, 200(멱등 재응답) = 이미 있음, 그 외 = 실패. 실패가 있으면 종료 2(쓰기는 release 하되 결과에 남김 — D-12 와 구분: 승격은 끝났고 재생만 일부 실패)
- 결과는 표준 출력 + `echo_ops.cutover_runs` 에는 손대지 않음(표 모양 변경 없이). 결과 기록 칸이 필요하면 별도 논의

## 6. 실패 모드

| 상황 | 동작 |
|---|---|
| journal 컨테이너 죽음 | Envoy 가 통과시킴(D-2). `/status` 를 못 읽으므로 `replay.sh` 는 "기록 없음"으로 종료 2, 승격은 이미 끝난 상태 |
| 기록 디스크 가득 | 기록 실패 → 허용(fail-open), 로그 경고 |
| hold 중 스크립트가 죽음 | trap 으로 release. SIGKILL 이면 hold 가 남음 → 운영자가 `POST /release` (README 에 적음) |
| A 가 받았지만 응답 전에 죽은 요청 | 재생된다. 클라이언트가 같은 키로 다시 보내면 중복 없음, 키 없이 다시 보내면 중복 가능(한계) |
| 도쿄가 사실 살아 있음 | `promote.sh` 가 거부(종료 1) → release, 재생 안 함 |
| 보조 진입점으로 넘어간 동안의 쓰기 | 기록 안 됨(D-11). 지금과 같은 누락 |

## 7. 완료 기준

- [ ] 스위치 전부 꺼진 상태에서 기존 시험이 그대로 통과(`replication/k8s/scripts/tests/run.sh` 79개, 진입점 로컬 compose 동작 같음)
- [ ] journal 켬: 쓰기만 기록, GET 기록 없음, 민감 헤더 없음, 15분 지난 기록 지워짐
- [ ] journal 정지: 쓰기 통과
- [ ] hold: 쓰기 503 + `Retry-After`, GET 은 통과
- [ ] 로컬 종합: 1·2·3 → B 구독 멈춤 → 4·5(A 만) → A 정지 → `REPLAY_ON_PROMOTE=true promote-with-replay.sh` → B 1~5 누락 0·중복 0 → 6·7·8 → A 재기동 → `resync-a.sh` → A 1~8
- [ ] 같은 시나리오를 스위치 끄고 → 지금처럼 4·5 누락(기존 동작 확인)
- [ ] 지연: journal 켜기 전후 진입점 `/summary` 쓰기 p95 차이 기록

## 8. 위험

- 시연 하루 전 모든 요청이 지나는 진입점 변경 → 기본 꺼짐으로 배포, 리허설에서 켜고 통과했을 때만 시연에 씀
- PR #71 과 같은 파일(`docker-compose.yml`) → #71 머지 뒤 그 위에서 작업
- 재생 동안 쓰기 정지가 늘어남(기록 수 × B 쓰기 시간). 시연 부하(초당 수 건)·지연 수 초면 수십 건, 1~2초 예상 → 측정해서 공개

## 9. 구현 결과 (2026-11-06)

| 파일 | 무엇 |
|---|---|
| `entrypoint/journal/app.py`·`Dockerfile` | 요청 기록 서비스(표준 라이브러리). 쓰기만 SQLite(WAL, `synchronous=FULL`), 15분 보관, hold 429, `/entries?format=tsv` |
| `entrypoint/config/envoy/envoy.yaml` | `router` 앞 `ext_authz`(런타임 `journal.enabled` 기본 0, `failure_mode_allow`), 정적 클러스터 `journal`, `layered_runtime` |
| `entrypoint/docker-compose.yml` | `journal` 서비스(관리 포트만 공개)·볼륨 |
| `replication/k8s/scripts/replay.sh` | 기록을 서울 앱에 순서대로 다시 보냄(멱등 키 없거나 본문 잘린 기록은 보내지 않음) |
| `replication/k8s/scripts/promote-with-replay.sh` | hold → `promote.sh`(그대로) → `replay.sh` → release. `REPLAY_ON_PROMOTE=true` 가 아니면 `promote.sh` 를 그대로 실행 |

| 시험 | 결과 |
|---|---|
| `entrypoint/journal/test_app.py` (단위) | 14 통과 |
| `entrypoint/journal/tests/envoy-test.sh` (실제 compose + stub) | 18 통과 — 꺼짐 기록 0 · 켬 쓰기만 · hold 429 · 8081 비공개 · journal 정지 시 통과 |
| `replication/k8s/scripts/tests/replay-test.sh` (Envoy+journal+시연 앱 두 개+Postgres 두 대) | 21 통과 — 재생 켬: B 1~8(4·5 살아남, 재생 0.53초) / 끔: 4·5 잃음 |
| 지연(로컬 Docker Desktop, 쓰기 30번 p95) | 필터 꺼짐 9.2ms · 켬 27.2ms → 운영 VM 에서 다시 잼 |

남은 것: 운영 적용(진입점 재배포 · 서울 B → 도쿄 A 순 `request_id` 칸 · 앱 배포 · 스위치), 컷오버 Job 안에서 재생(VAP 가 지금은 `PLAN_ID`·`KIND`·`ALLOW_PROMOTE` 만 허용 → `JOURNAL_*`·`REPLAY_BASE` 를 넘기려면 VAP·Secret 추가가 필요).
