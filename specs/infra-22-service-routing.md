# 인프라 22 — 서비스별 트래픽 격리

작업 원장: https://github.com/Softbank-Hackathon-2026-Team-Echo/echo-infra/issues/112
작성자: Jimin Kim. 사용자 승인: 이슈·독립 클론·기능 브랜치 PR까지. 병합·운영 반영·Terraform APPLY 금지.

## 결함 / 수정

단일 CURRENT + wildcard customer_apps + WAS의 service 식별자 없는 PUT 때문에 서비스 A를 바꾸면 B까지 바뀐다. 서비스별 정체성은 이미 WAS의 MainRoute에 있으나 외부 호출에서 사라졌다.

새 서비스 모드는 검증된 등록표를 읽고, 서비스 UUID/publicHost별로 환경 UUID·origin·가중치·revision을 분리한다. 정확한 host별 RDS virtual host와 서비스/환경 전용 CDS cluster를 생성한다. unknown host는 health 외 직접 404다. 새 모드에서 자동 aggregate fallback은 만들지 않는다. 목적지 자격 미확인 서비스를 자동 우회 대상으로 추가하지 않는다.

등록표는 운영자가 조직별 DB 값과 실제 접속정보를 대조한 읽기 전용 파일이며 공개 API로 등록하지 않는다. Bearer는 WAS/운영자용이고 tenant에 배포하지 않는다. 기존 WAS 조직·서비스 소유권 게이트는 그대로다.

## 계약 / 구현 파일

- API·FE 필드·오류·legacy·원복 정본: `contracts/service-routing.md`
- 제품: `entrypoint/weights-api/app.py` (같은 파일에 둬 기존 Dockerfile·부팅 스크립트의 app.py 복사 계약을 유지)
- 로컬 시험: `entrypoint/weights-api/test_service_routing.py`
- 짝 WAS: `app/executors/entrypoint.py`, `tests/test_entrypoint_service_scope.py`, `tests/test_entrypoint_local_http_contract.py`

## 인수 시험

실제 ThreadingHTTPServer와 WAS의 AsyncClient를 loopback으로 연결한다. A=GCP100/B=AWS100 + 제3 서비스 유지, A의 AWS 10/50/100, 다른 서비스 불변, 본문·조회 scope 일치, unknown 환경·다른 서비스 target·host 조작 거절을 검증한다.

thread lock + 파일 flock + revision CAS로 최신 전체 snapshot을 읽고 대상 서비스만 바꾼다. 서로 다른 ServiceRouteStore 인스턴스의 동시 쓰기를 검증한다. primary 손상 시 최신 backup으로 전체 서비스/RDS 복원, 저장 중 실패 후 다른 서비스 유지, 둘 다 손상·누락이면 시작 거절한다. 보조 snapshot 동기화는 전체 서비스와 registry hash·generation·각 revision을 검증해 누락/후퇴를 거부한다.

RED→GREEN 로그와 생성 RDS/CDS·WAS HTTP 기록은 `night-1107/service-routing-build`에 보존한다. 구체 명령:

    python3 -m unittest discover -s entrypoint/weights-api -p 'test_service_routing.py'
    python3 -m unittest discover -s entrypoint/journal -p 'test_*.py'

WAS는 로컬 PostgreSQL 미사용 전체 회귀와 별도 loopback 통합을 실행한다. DB 통합은 CI의 기존 PostgreSQL 서비스에서 확인한다. Envoy 바이너리가 로컬에 없어 xDS ACK/실제 트래픽은 미검증이다. JSON은 YAML의 유효한 부분집합이며 실제 파일 생성만 검증했다.

## 기본 OFF / 적용·원복 (실행하지 않음)

1. 두 PR 독립 검증 후 별도 지휘로 병합한다. WAS main 병합은 자동 배포라 주의한다. 기능 URL·플래그는 이번 PR에서 켜지 않는다.
2. 모든 active 서비스와 환경 UUID·대표 host·검증된 HTTP origin의 완전한 등록표를 준비한다. 신규 파일은 root/운영 관리로 읽기 전용 mount한다. a/b/c가 같은 registry hash를 사용해야 한다. Cloudflare 입구 선호와 고객 앱 주력을 섞지 않는다.
3. 기존 상태와 생성 설정을 백업한다. SERVICE_ROUTING_ENABLED=1, SERVICE_ROUTES_FILE=<읽기 전용 파일>을 해당 컨테이너 환경에 명시한다. 기존 compose에는 새 flag/mount가 없어 운영용 override 준비도 필요하다. 자동 apply는 하지 않는다.
4. 보조 먼저 준비하되 신규 모드로 serving을 전환하는 순서는 별도 운영 창에서 정한다. legacy/v1 혼합은 sync가 거절하므로 마지막 정상 설정을 유지한다. WAS ENTRYPOINT_BASE_URL은 마지막에 /v1을 붙여 명시 전환한다.
5. 승인된 두 서비스만으로 운영 시나리오·Envoy ACK·실제 경로·counter를 검증한다. 실패하면 신규 요청 중단, 저장 snapshot 보존, 승인된 이전 코드/설정으로 되돌린다. OFF/옛 URL로 돌아가면 다시 단일 전역 비율이므로 자동 원복하지 않는다.

기본 OFF는 결함의 운영 해소를 뜻하지 않는다. 활성화 전까지 운영은 기존 동작이며, 등록표 추가/변경은 자동 초기화하지 않고 명시적 상태 이관이 필요하다.

## 범위 밖 / 비용

echo-infra#21(자동 우회 보안 자격), echo-infra#103(온프레 TLS·실제 갈래), echo-infra#105(DB Job 쌍), echo-was#116(지원 능력·DB 대상 결합)은 별도다. onprem은 검증된 HTTP origin 등록 계약만 열려 있고 터널 TLS/SNI·운영 onprem 이전은 지원 완료가 아니다. 서비스 summary는 501/Unavailable로 정직하게 표시한다.

Terraform/운영 ConfigMap/DB 스키마·복제·Job·capability 파일 변경 없음. 신규 cloud 비용 $0·자원 변경 0. 운영 요청·DB SELECT/exec·추가 위임·merge/deploy 없음. Slack은 초안만 남긴다.
