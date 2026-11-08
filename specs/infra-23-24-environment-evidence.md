# 환경 권한·내부 전송 관측 (WAS #131)

## 목적
C-IAM-1/C-TLS-2에 주기적인 실제 자동 관측 결과를 공급합니다. infra #134의 수동6건 등록 완료를 확인했으며 자동화 후속과 구분합니다.
기존 weights 변경·DB 컷오버·고객 배포를 변경하지 않습니다.

## 구현
- weights-api 별도 read-token GET /security/transport, active Envoy cluster 요약과 TLS probe.
- DB 관측 CronJob: 고정 SQL/SHOW, 전용 통계 로그인, 보호 ConfigMap 한 개 PATCH.
- WAS의 설정 지문·환경/조직 범위·30분 TTL 저장과 연동.
- 권한 템플릿: RBAC get/list, AWS IAM/EKS read, GCP policy/role read만 포함.
- 활성화·정확한 대상·권한·CA·이미지 digest는 README의 운영 인수 항목입니다.

## 완료 기준
자동 관측기의 인증/부정/회귀 테스트와 로컬 실제 DB·Envoy 검증이 통과해야 브랜치 구현 완료입니다.
운영 완료는 담당이 확정한 3환경 프로필·권한·관측기를 적용하고 findings/matrix/compare를 직접 확인한 뒤입니다.
관측 불완전은 UNKNOWN입니다. 화면을 채우기 위한 PASS/사람 점검 대체 기록을 만들지 않습니다.

서비스 라우팅 계약의 service+environment cluster ID를 지정해 관측합니다. 공용 평문은 FAIL·사설 평문은 WARN입니다. 운영 설정의 변경/권한 축소는 이 브랜치에서 하지 않았습니다. WAS 정책 전환 시 기존 수동 증거 재등록이 필요하며 시연 중 단독 배포하지 않습니다.

## 2026-11-08 11:14 KST 검증 근거

main87a64cff 기반 weights32·observer9·journal14 PASS.
실제 Envoy1.39.6: 사설 평문 WARN/검증된 TLS PASS/잘못된 hostname WARN, 관측 전후 weights 불변·HTTP/TLS 트래픽 전환 PASS.
실제 PG17: 집계 함수 읽기 허용, 대상표 읽기/쓰기·권한 상승 거부 PASS.
실제 PgBouncer1.26.1: observer 이미지 psql로 CLIENTS/SERVERS 평문 관측, stats 계정 PAUSE 거부 PASS.
두 이미지 build·YAML8리소스/JSON/AST 검사 PASS. Terraform fmt/validate PASS, 기존 GKE provider 경고 있음. tflint 미설치로 해당 검사는 실행하지 못했다.
짝 WAS mainca918380+자동화 전체3109 PASS/skip0(마이그레이션59·실제 HTTP 계약 포함), ruff/format/mypy PASS.
모든 동적 시험은 전용 로컬 자원이며 운영과 구분한다. DB CNI·실제 cloud IAM·3환경 수집 인수는 남았다.

## 전용 runtime 후속

feat/sec-observer-runtime은 검사 전용 GSA/STS/KSA/RBAC·제한 WAS DB 역할·suspend 상태 collector CronJob·TLS 관측 overlay를 추가한다. 기본 인프라 생성은 OFF다. 실제 값·권한/네트워크 적용과 정책 전환 인수는 [운영 연결 절차](../security/environment-observer/README.md)에 남긴다. 로컬 실제 권한 경계와 Terraform mock plan을 검증하되 cloud 인증·운영 수집 완료로 확대하지 않는다.
