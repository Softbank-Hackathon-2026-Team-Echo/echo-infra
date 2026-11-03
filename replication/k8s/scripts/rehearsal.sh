#!/usr/bin/env bash
# 리허설 한 번: 쓰기 부하를 뒤에서 돌리며 대조 → 컷오버(A→B) → 대조 → 롤백(B→A) → 대조. 측정값을 replication/k8s/rehearsals/<시각>.md 에 남긴다(#10 자동 기록의 원본).
# 사용: A_HOST=<A NLB DNS> B_HOST=<B LB IP> replication/k8s/scripts/rehearsal.sh
source "$(dirname "$0")/common.sh"
: "${A_HOST:?}"; : "${B_HOST:?}"
out="$(dirname "$0")/../rehearsals/$(date +%Y-%m-%d-%H%M).md"; mkdir -p "$(dirname "$out")"
{ echo "# 리허설 $(date '+%Y-%m-%d %H:%M %Z')"; echo; echo '```'; } > "$out"
log() { echo "$*" | tee -a "$out"; }
RATE="${RATE:-10}" DURATION="${DURATION:-90}" "$(dirname "$0")/writer.sh" > "$out.writer" 2>&1 & wpid=$!
sleep 10
log "== 컷오버 전 =="; "$(dirname "$0")/verify.sh" | tee -a "$out"
log "== 컷오버 A→B =="; B_HOST="$B_HOST" "$(dirname "$0")/cutover.sh" | tee -a "$out"
sleep 10
log "== 컷오버 후 =="; "$(dirname "$0")/verify.sh" | tee -a "$out"; "$(dirname "$0")/lag.sh" | tee -a "$out"
log "== 롤백 B→A =="; A_HOST="$A_HOST" "$(dirname "$0")/rollback.sh" | tee -a "$out"
sleep 10
log "== 롤백 후 =="; "$(dirname "$0")/verify.sh" | tee -a "$out"
wait $wpid; log "== 쓰기 부하 =="; cat "$out.writer" | tee -a "$out"; rm -f "$out.writer"
echo '```' >> "$out"; echo "기록: $out"
