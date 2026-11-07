# 증거 읽기 경계

이 디렉터리는 NET-ENVOY1a의 최소 검증 영수증이다. 실제 Envoy 실행 근거가 아니다.

- `audit.json`: 제품 세 파일 source SHA256, 이번 infra39 집중 회귀, 원본/legacy AST 보존, 신규 파일 포맷·lint와 app 기준선4/후보4/새 항목0, 기본 OFF, 기존 HTTP fixture raw 전체 재집계 및 hash, 과거 paired WAS/독립11/RED JUnit 집계.
- `focused-regression.xml`, `focused-regression.log`: 이번 재실행 39 PASS, 실패·오류·SKIP0, pytest wall41.99초.
- `environment-preflight.json`: 현재 선택 colima/default Stopped, 별도 colima-echo Running. 엔진 대체·기동·pull/run0, native PARTIAL_BLOCKED.
- `repository-check.log`: 저장소 `bash scripts/check.sh` exit0, fmt·backend 없는 init/validate·tflint. 기존 GKE deprecated argument 경고는 남아 있다. apply0.

기존 HTTP fixture는 548요청/96오류(워밍업59)/다른서비스오류0, 최대819.273292ms, 측정구간합62.222626초다. 원점 POST4·동일키 추가송신0은 실DB commit 중복0과 다르다. native 요청0·오류/복구시간 측정없음·imageID null을 별도 기록한다.

전체 raw·origin POST key·이전 실패 기록(v1~v3 포함)·RED/GREEN·원본 파일은 `/Users/jimin/archive/softbank-hackathon-2026/night-1107/network-resilience/`에 보존되어 있다. 과거 독립11 PASS 및 paired WAS 1,569 PASS/1,260 SKIP은 이번 재실행이 아니라 기존 파일 직접 재집계다. 확인되지 않은 DB/운영 결과를 채워 넣지 않았다.

이 후보는 기본 OFF다. 실제 엔진 동일성 확인→공식 고정 digest/platform/imageID 검증→native validate→file xDS 수용·실요청/POST/timeout·정리가 남아 있다. 운영 main merge/deploy·기존 자원 조작·물리 네트워크 단절·추가 위임0. 부모 독립검수용 후보이지 운영 완료 증거가 아니다.
