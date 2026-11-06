#!/usr/bin/env bash
# 진입점 요청 기록을 승격된 서울 B 앱에 다시 보낸다 (인프라 12.4, specs/infra-12.4-request-journal.md).
# 받은 순서대로 같은 메서드·경로·본문·멱등 키로 보낸다. 앱이 멱등(IDEMPOTENT_WRITES=true)이라 B 에 이미 있는 쓰기는 200(건너뜀),
# 빠진 쓰기만 201(새로 들어감)이다. 보통은 promote-with-replay.sh 가 승격 직후 부른다(그동안 진입점은 쓰기를 막는다).
# 사용: JOURNAL_URL=http://<진입점>:8082 JOURNAL_TOKEN=… REPLAY_BASE=https://<B 앱 환경별 주소> [REPLAY_SINCE=<UNIX 초>] replay.sh
#   REPLAY_HOST  B 앱에 보낼 Host 헤더(비우면 REPLAY_BASE 의 호스트)
# 종료 코드 0 모두 처리 · 2 일부 실패(보낸 수·실패 수를 출력, 다시 돌려도 안전 — 이미 들어간 것은 200 으로 건너뜀) · 1 기록을 못 읽음
# 건너뛰는 기록: 멱등 키가 없는 것(다시 보내면 중복될 수 있다)·본문이 잘린 것 → "보내지 않음" 으로 센다.
set -uo pipefail
: "${JOURNAL_URL:?JOURNAL_URL 이 필요하다}" "${JOURNAL_TOKEN:?JOURNAL_TOKEN 이 필요하다}" "${REPLAY_BASE:?REPLAY_BASE 가 필요하다}"
SINCE="${REPLAY_SINCE:-0}"
host_args=(); [[ -n ${REPLAY_HOST:-} ]] && host_args=(-H "Host: $REPLAY_HOST")

tsv=$(curl -sf --max-time 10 -H "Authorization: Bearer $JOURNAL_TOKEN" "${JOURNAL_URL%/}/entries?since=$SINCE&format=tsv") \
  || { echo "[중단] 요청 기록을 읽지 못했다: ${JOURNAL_URL%/}/entries" >&2; exit 1; }

sent=0 created=0 existed=0 failed=0 skipped=0
t0=$(date +%s.%N)
while IFS=$'\t' read -r id method path key ctype body truncated; do
  [[ -z ${id:-} ]] && continue
  if [[ $key == - || $truncated == 1 ]]; then
    skipped=$((skipped + 1)); echo "  보내지 않음 #$id $method $path ($([[ $key == - ]] && echo '멱등 키 없음' || echo '본문 잘림'))"; continue
  fi
  args=(-s -o /dev/null -w '%{http_code}' --max-time 10 -X "$method" -H "Idempotency-Key: $key" "${host_args[@]}")
  [[ $ctype != - ]] && args+=(-H "Content-Type: $ctype")
  if [[ $body != - ]]; then
    code=$(base64 -d <<<"$body" | curl "${args[@]}" --data-binary @- "${REPLAY_BASE%/}$path")
  else
    code=$(curl "${args[@]}" "${REPLAY_BASE%/}$path")
  fi
  sent=$((sent + 1))
  case $code in
    201) created=$((created + 1)) ;;
    200) existed=$((existed + 1)) ;;
    *)   failed=$((failed + 1)); echo "  실패 #$id $method $path → $code" >&2 ;;
  esac
done <<<"$tsv"
ms=$(echo "($(date +%s.%N) - $t0) * 1000 / 1" | bc)

echo "재생: 보냄 $sent · 새로 들어감 $created · 이미 있음 $existed · 실패 $failed · 보내지 않음 $skipped (${ms}ms, since=$SINCE)"
[[ $failed == 0 ]] || exit 2
