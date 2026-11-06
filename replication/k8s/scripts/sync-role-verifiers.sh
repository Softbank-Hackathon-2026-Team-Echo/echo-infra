#!/usr/bin/env bash
# 앱 계정 SCRAM 검증자를 A 값으로 B 에 맞춘다 (11/6 운영 Job 시험에서 발견, common.sh "앱 계정 SCRAM 검증자").
# 비밀번호는 그대로, 솔트·반복 수만 A 와 같아진다. 검증자 값은 화면·로그에 내보내지 않는다(지문만).
# 사용: replication/k8s/scripts/sync-role-verifiers.sh          A → B 로 맞추고 확인
#       replication/k8s/scripts/sync-role-verifiers.sh --check  같은지만 확인(다르면 종료 1, 바꾸지 않음)
# 언제: 클러스터를 새로 만든 뒤·비밀번호를 바꾼 뒤·컷오버 preflight 가 "검증자가 다르다"로 멈췄을 때. 여러 번 실행해도 안전.
source "$(dirname "$0")/common.sh"

d=$(verifiers_diff)
if [[ -z $d ]]; then echo "같음: $SCRAM_ROLES (A·B 검증자 일치)"; exit 0; fi
if [[ ${1:-} == --check ]]; then echo "다름: $d" >&2; exit 1; fi

for r in $d; do
  v=$(pg A -c "SELECT rolpassword FROM pg_authid WHERE rolname = '$r';")
  [[ $v == SCRAM-SHA-256\$* ]] || { echo "[중단] A 의 $r 가 SCRAM 검증자가 아니다 — 맞출 수 없다" >&2; exit 1; }
  # 변수는 -c 에서 치환되지 않으므로 stdin 으로 넣는다(common.sh 머리말). 이름은 $SCRAM_ROLES 에서만 온다.
  echo "ALTER ROLE \"$r\" PASSWORD :'v';" | pg B -q -v v="$v" >/dev/null
  unset v
  echo "맞춤: $r (A → B, 지문 $(verifier_fp B "$r"))"
done

d=$(verifiers_diff)
[[ -z $d ]] || { echo "[실패] 맞춘 뒤에도 다르다: $d" >&2; exit 1; }
echo "같음: $SCRAM_ROLES (A·B 검증자 일치)"
