#!/usr/bin/env bash
# 승격 + 요청 기록 재생 (인프라 12.4). promote.sh 는 고치지 않고 앞뒤로 감싼다.
#   진입점 쓰기 막기(hold) → promote.sh → replay.sh(A 에만 들어가고 B 로 못 온 쓰기를 다시 보냄) → 쓰기 풀기(release)
# 기본 꺼짐: REPLAY_ON_PROMOTE=true 가 아니면 promote.sh 를 그대로 실행한다(지금과 같다).
# 사용: REPLAY_ON_PROMOTE=true JOURNAL_URL=… JOURNAL_TOKEN=… REPLAY_BASE=… [PLAN_ID=…] promote-with-replay.sh
#   REPLAY_MARGIN_SECONDS  B 가 A 에서 마지막으로 받은 시각보다 이만큼 앞부터 재생(기본 30). 그 사이 겹치는 쓰기는 멱등이라 건너뛴다
# 종료 코드: promote.sh 가 1 이면 1(바뀐 것 없음, 쓰기 풀기) · 2 면 2(부분 상태 — 쓰기 막기를 유지하고 사람을 부른다)
#   승격이 끝났으면 replay.sh 의 종료 코드(0 모두 처리 · 2 일부 실패 · 1 기록을 못 읽음). 쓰기 풀기는 이 경우 항상 한다
set -uo pipefail
here=$(dirname "$0")
[[ ${REPLAY_ON_PROMOTE:-false} == true ]] || exec "$here/promote.sh"
: "${JOURNAL_URL:?JOURNAL_URL 이 필요하다}" "${JOURNAL_TOKEN:?JOURNAL_TOKEN 이 필요하다}" "${REPLAY_BASE:?REPLAY_BASE 가 필요하다}"

jcall() { curl -sf --max-time 5 -X POST -H "Authorization: Bearer $JOURNAL_TOKEN" "${JOURNAL_URL%/}/$1" >/dev/null; }

# 재생 시작점: 승격 전에 B 가 A 에서 마지막으로 받은 시각(승격하면 구독이 꺼져 이 값이 사라진다). 못 읽으면 0 = 기록 전부(멱등이라 안전).
since=$( (source "$here/common.sh"; pg B -c "SELECT COALESCE(floor(EXTRACT(EPOCH FROM (SELECT max(last_msg_receipt_time) FROM pg_stat_subscription WHERE subname = 'echo_sub')))::bigint - ${REPLAY_MARGIN_SECONDS:-30}, 0);") 2>/dev/null)
[[ $since =~ ^[0-9]+$ ]] || since=0

if ! jcall hold; then
  echo "[경고] 진입점 쓰기 막기(hold)를 못 했다 — 재생 없이 promote.sh 만 실행한다(지금과 같음)" >&2
  exec "$here/promote.sh"
fi
echo "[재생] 진입점 쓰기 막음(hold). 재생 시작점 since=$since"
keep_hold=0
release() { [[ $keep_hold == 1 ]] && return; jcall release && echo "[재생] 진입점 쓰기 풂(release)" || echo "[경고] release 실패 — 손으로: curl -X POST -H 'Authorization: Bearer …' ${JOURNAL_URL%/}/release" >&2; }
trap release EXIT
trap 'exit 130' INT TERM HUP   # 신호로 끝나도 EXIT trap 으로 release

"$here/promote.sh"; rc=$?
case $rc in
  0) ;;
  1) echo "[재생] 승격하지 않았다(바뀐 것 없음) — 재생하지 않는다"; exit 1 ;;
  *) keep_hold=1
     echo "[중단] 승격이 부분 상태로 끝났다(종료 $rc) — 쓰기 막기를 유지한다. replication/k8s/README.md '부분 상태 복구' 뒤 release" >&2
     exit "$rc" ;;
esac

REPLAY_SINCE=$since "$here/replay.sh"; exit $?
