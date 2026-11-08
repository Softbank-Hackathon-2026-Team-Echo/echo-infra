# Infra 20 — 명시 DB쌍 정적 계약 (1단계)

관련: echo-infra#105(명시 DB쌍 Job), echo-was#116(지원쌍 사전판정·DB 바인딩).
상태: Draft. 엔진/이미지/VAP 운영 지원 미완.

## 구현 범위

replication/cutover-job/contracts/db-pair-v1.json은 WAS snapshot 스키마다. validate_db_pair.py는 같은 WAS manifest에서 생성한 sanitized fixture의 env allowlist·UUID·조직/서비스/환경/배포 binding·정확한 등록표 해시·등록 DB쌍·KIND 방향·writer 입력을 검사한다. source/target을 provider 종류로 추정하거나 온프레를 고객 B로 대체하지 않는다.

## 인수

- [x] 정상 명시 A→B fixture 수용, 다른 쌍/tenant/deployment/KIND/writer/해시/command/secret 주입 거절.
- [x] 등록표 내용만 바꾸어 예전 digest를 유지해도 거절.
- [x] 거절 뒤 PAUSE hook 미호출을 순수 unittest로 검증.
- [x] 실제 엔진/공통 셸/VAP/이미지/Terraform은 수정하지 않음.
- [ ] 실제 Job env 소비·실 DB writer 확인·PAUSE 경계 연결.
- [ ] 이미지 digest 고정+VAP 서버 dry-run, cutover_runs 쌍 receipt.
- [ ] A↔B 정상/재난 회귀 및 온프레 4방향·승격·재동기화 운영 증거.

## 실행

`python3 -I -m unittest discover -s replication/cutover-job/tests -p 'test_db_pair_contract.py' -v`

이 시험은 Kubernetes admission이나 실제 DB 정합성 검증이 아니다. 자세한 후속 입력·소유권은 contracts/db-pair-v1.md. 기존 이슈를 닫지 않는다.
