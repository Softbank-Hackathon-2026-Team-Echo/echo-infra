# 인프라 23 — HTTP 원점 단절 stateless 읽기 대피 후보

GitHub 이슈: echo-infra#122(HTTP 원점 단절 stateless 읽기 대피·재연결 고정).
상태: Draft 후보 / In Progress / native PARTIAL_BLOCKED / 기본 OFF.
계약 정본: `contracts/network-resilience.md`.

## 목적·선행

예고 없는 원점 연결 종료·거절·blackhole·지연과 재연결에서 서비스별 안전 경로만 분리한다. echo-infra#113(서비스별 라우팅)의 head `883e03881020fecf1b28c16f08faffa392f053b6`가 선행이다. DB 승격·복제·journal·터널·물리 랜선 시연은 별도 담당이며 이 후보가 대신 완료하지 않는다.

통합 기준은 `b984f5e4e63ba575a1a3cd1f8c50c69282ed1f20`이다. 시작 head `52c4ca10690c665b21d80d5c4413b0d6846311ca`에 main `752948b3316213212fda85b1fc39c880f83d9f5d`를 기존 finisher가 일반 merge한 상태다. 해당 기준의 entrypoint는 선행 라우팅 head와 동일하다. 부모가 선행을 병합하기 전까지 검토용 base `chore/network-resilience-integration-base`를 이 기준에 고정하여 이 PR diff에 선행 라우팅·이미 main에 있는 온프레/풀 변경이 중복되지 않게 한다. base 자체를 운영 main으로 병합하지 않는다. 선행 병합 뒤 부모가 main과 task-only diff를 다시 대조하고 PR base를 변경해야 한다.

## 인수 표

| AC | 기대 | 확인·판정 |
|---|---|---|
| OFF | 새 설정이 없으면 기존 동작 | fresh import OFF, legacy 생성 함수 AST 동일, 배포 파일 변경 없음 PASS |
| scoped | 서비스·tenant·weights/revision 격리 | 집중 39 PASS, 기존 fixture snapshot 불변·다른 서비스 오류0 PASS |
| 단절·복구 | 자격 있는 읽기 대체·복귀 고정 | HTTP fixture reset/refused/blackhole/delay/reconnect/flap PASS; native BLOCKED |
| 모든 원점 정지 | 가짜 200 없음 | fixture 503·안정 재연결 후 B 응답 PASS; native BLOCKED |
| 쓰기 | unsafe 자동 재전송 금지·고장 뒤 보류 | 생성 retry0·fixture 동일키 추가송신0·503 no-dispatch PASS; native·DB UNVERIFIED |
| budget | bounded retry·전체 deadline | 생성 필드·fixture 제한 PASS; Envoy 실제 강제 BLOCKED |
| 제어면 정지 | 마지막 파일 유지 | fixture control-outage PASS; native BLOCKED |
| native | 공식 pinned image·validate·file xDS·트래픽 | 기존 colima/default Stopped, 다른 엔진 선택0 PARTIAL_BLOCKED |
| 정리 | 본인 자원만 종료·기존 자원 보존 | 이번 Docker 자원0, 과거 fixture 48개 port closed 기록 + 현재 재조회 모두 닫힘 |
| 발행 | task-only Draft·exact head 확인 | 기능 branch만 발행, main merge/deploy0; 최종 원격 영수증 별도 |

## 시험·증거

기존 RED XML/로그는 삭제·약화하지 않았다. 원본 app 변경은 AST 동일, 신규 두 파일은 original과 byte 동일이다. 이번 변경은 그 후보 보존·문서화이며 새 native 결함을 확인하거나 수정하지 않았다.

2026-11-07 최종 집중 재실행: 서비스13+journal14+네트워크12=39 PASS, 실패/오류/SKIP0, pytest wall 41.99초. app lint는 기준선4/후보4/새 항목0, 신규 두 파일 lint·format PASS, Python 세 파일 구문 PASS. 전체 저장소 `bash scripts/check.sh` exit0. Terraform·클라우드 설정 변경0, apply0.

기존 paired WAS 직렬 JUnit 재집계: 1,569 PASS/1,260 SKIP/실패·오류0. 초기 1,568 PASS/1,261 SKIP 기록도 보존한다. DB 없는 SKIP을 PASS로 세지 않는다. 이번 WAS 전체 재실행은 하지 않았다. 기존 독립 탐침11 PASS는 원문 증거 회수이며 이번 재실행 결과가 아니다.

HTTP fixture 548요청/96오류(워밍업59)/다른 서비스 오류0/최대819.273292ms/측정합62.222626초. 원점 POST4·동일키 추가송신0. native 요청0, imageID null. 이 수치를 합치지 않는다.

저장소 영수증: `docs/evidence/infra-23-network-resilience/`.
전체 원본·raw·RED/GREEN·JUnit·원본 보존: `/Users/jimin/archive/softbank-hackathon-2026/night-1107/network-resilience/`.

## 범위 밖·남은 일

부모 독립 검수, 정확한 기존 해커톤 엔진 지정 확인 후 native 시험, NET1의 고객 주소 경유·단절 대상 확인이 남았다. 실 writer/fencing/replay·DB 커밋 중복/누락·물리 장애는 미검증이다. 신규 비용 월 $0·1회 $0. Slack/Notion·운영 merge/deploy·추가 위임0. 공유 SCENARIO/OWNER-MAP와 다른 담당 파일은 수정하지 않는다.
