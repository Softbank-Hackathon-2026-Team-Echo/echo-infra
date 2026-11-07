#!/bin/bash
# 인프라 17 되돌리기 1-a(확인)·1-b(원복): Cloudflare `*.echoport.uk` A 레코드가 GCP NLB 34.158.197.107 proxied=true 인지.
# gcloud 가 있는 M5 에서 돈다. M1 저장소 루트에서:
#   ssh <M5> 'bash -s -- check'   < entrypoint/scripts/cf-wildcard-a.sh    # 읽기만
#   ssh <M5> 'bash -s -- restore' < entrypoint/scripts/cf-wildcard-a.sh    # 다를 때만 PATCH → 재조회
# 토큰(GCP Secret echo-dev-echo-was-cloudflare-dns-token, DNS 편집 권한 — LB 권한은 없다)은 M5 임시 0600 헤더 파일로만 쓰고 끝나면 지운다. 값 출력 없음.
# 레코드가 2개 이상이면 자동 원복하지 않는다(사람 확인).
export PATH=/opt/homebrew/bin:$PATH
MODE=${1:-check}; WANT=34.158.197.107
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
( umask 077; printf 'Authorization: Bearer %s\n' "$(gcloud --account=rlawlals031211@gmail.com --project team-echo-final secrets versions access latest --secret=echo-dev-echo-was-cloudflare-dns-token)" > "$D/h" )
C() { curl -sS -H @"$D/h" "$@"; }
API=https://api.cloudflare.com/client/v4
ZONE=$(C "$API/zones?name=echoport.uk" | jq -r '.result[0].id')
LINES=$(C "$API/zones/$ZONE/dns_records?type=A&name=%2A.echoport.uk" | jq -r '.result[] | "\(.id) \(.content) proxied=\(.proxied)"')
echo "1-a 현재 * A: $LINES"
N=$(printf '%s\n' "$LINES" | grep -c . )
if [ "$N" = 1 ] && printf '%s' "$LINES" | grep -q " $WANT proxied=true$"; then echo "1-a OK (원복 불필요)"; exit 0; fi
[ "$MODE" = restore ] || { echo "1-a 다름 — restore 로 다시 실행"; exit 3; }
[ "$N" = 1 ] || { echo "레코드가 $N 개 — 자동 원복 안 함(사람 확인)"; exit 4; }
ID=${LINES%% *}
echo "1-b PATCH: $(C -X PATCH -H 'Content-Type: application/json' "$API/zones/$ZONE/dns_records/$ID" --data "{\"content\":\"$WANT\",\"proxied\":true}" | jq -c .success)"
echo "1-a 재조회: $(C "$API/zones/$ZONE/dns_records?type=A&name=%2A.echoport.uk" | jq -r '.result[] | "\(.id) \(.content) proxied=\(.proxied)"')"
