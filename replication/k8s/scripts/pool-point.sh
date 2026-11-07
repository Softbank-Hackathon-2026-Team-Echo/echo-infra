#!/usr/bin/env bash
# 풀 방식 표지판(echo-data/db-writer)을 손으로 맞춘다 — 처음 설치·부분 상태 복구용. 컷오버 중에는 cutover.sh·rollback.sh 가 같은 함수(repoint)를 쓴다.
# 사용: pool-point.sh <A|B> <local|주소>
#   pool-point.sh A local                 도쿄 표지판 → 도쿄 A (selector)
#   pool-point.sh B "$A_HOST"             서울 표지판 → 도쿄 A NLB(IP 로 풀어 EndpointSlice)
# 쓰기를 멈추지 않는다(PAUSE 없음): 쓰기 담당이 바뀌지 않는 설치 때만 쓰고, 쓰기 담당을 바꾸려면 cutover.sh·rollback.sh 를 쓴다.
source "$(dirname "$0")/common.sh"
side=${1:?A 또는 B}; to=${2:?local 또는 주소}
[[ $side == A || $side == B ]] || { echo "첫 인자는 A 또는 B" >&2; exit 1; }
pool_mode "$side" || { echo "[중단] $side 에 표지판 $NS/$WRITER_SVC 가 없다 — 풀 방식이 아니다(replication/k8s/pool/README.md 3단계)" >&2; exit 1; }
[[ $to == local ]] && to=$(local_of "$side")
before=$(pgb_backend "$side")
repoint "$side" "$to"
echo "[표지판] $side: ${before:-(비어 있음)} → $(pgb_backend "$side")"
