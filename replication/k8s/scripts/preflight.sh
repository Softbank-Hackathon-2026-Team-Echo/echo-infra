#!/usr/bin/env bash
# 시작 전 점검 (docs/final-test-runbook.md 1절). 읽기만 한다. 끝에 통과/실패 개수를 찍고, 실패가 있으면 종료 1.
# 사용: replication/k8s/scripts/preflight.sh      (데스크톱, 두 클러스터 kubeconfig·gcloud echo 설정)
source "$(dirname "$0")/common.sh"
set +e
export AWS_PROFILE="${AWS_PROFILE:-echo}"
A_NLB="${A_HOST:-echo-dev-pg-a-cb5bc23aab2d0c23.elb.ap-northeast-1.amazonaws.com}"
APP="${APP_HOST:-demo-y6cz3jrc.echoport.uk}"
ENTRY_A="${ENTRY_A:-34.158.202.103}"; ENTRY_B="${ENTRY_B:-8.230.16.205}"
GCFG="${GCLOUD_CFG:-echo}"
ok=0; ng=0
check() { if [ "$2" = "0" ]; then echo "  ✅ $1 — $3"; ok=$((ok+1)); else echo "  ❌ $1 — $3"; ng=$((ng+1)); fi; }

echo "== 복제"
st=$(pg A -c "SELECT state FROM pg_stat_replication WHERE application_name='echo_sub';" 2>/dev/null)
[ "$st" = "streaming" ]; check "A→B echo_sub" $? "${st:-없음}"
rev=$(pg A -c "SELECT count(*) FROM pg_subscription;" 2>/dev/null)
[ "$rev" = "0" ]; check "역방향 구독 없음(원본 상태)" $? "A 구독 ${rev:-?}개"
va=$(pg A -c "SELECT count(*)||'/'||(COALESCE(max(n),0)-COALESCE(min(n),0)+1-count(DISTINCT n))||'/'||(count(*)-count(DISTINCT n)) FROM demo.seq_write;" 2>/dev/null)
vb=$(pg B -c "SELECT count(*)||'/'||(COALESCE(max(n),0)-COALESCE(min(n),0)+1-count(DISTINCT n))||'/'||(count(*)-count(DISTINCT n)) FROM demo.seq_write;" 2>/dev/null)
[ -n "$va" ] && [ "$va" = "$vb" ] && [ "${va#*/}" = "0/0" ]; check "장부 대조 (건수/누락/중복)" $? "A $va · B $vb"

echo "== PgBouncer"
# 옛 방식(ini)·풀 방식(표지판 db-writer) 모두 common.sh 가 읽는다
ba=$(pgb_backend A 2>/dev/null)
bb=$(pgb_backend B 2>/dev/null)
[ "$ba" = "echo-pg" ]; check "A 백엔드" $? "$ba"
[ "$bb" = "$A_NLB" ]; check "B 백엔드 = A NLB" $? "$bb"
for s in A B; do p=$(pgb $s "SHOW DATABASES;" 2>/dev/null | awk -F'|' '$1=="app"{print $(NF-1)}'); [ "$p" = "0" ]; check "$s PgBouncer paused" $? "paused=${p:-?}"; done

echo "== 진입점"
for e in "$ENTRY_A" "$ENTRY_B"; do c=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$e/__entry/healthz"); [ "$c" = "200" ]; check "진입점 $e" $? "$c"; done
for vm in "echo-dev-entry asia-northeast3-a" "echo-dev-entry-b asia-northeast3-b"; do
  set -- $vm
  out=$(gcloud compute ssh "$1" --zone "$2" --tunnel-through-iap --configuration="$GCFG" --quiet --command \
    "curl -s 127.0.0.1:9901/clusters | grep -E '^(aws|gcp)::.*::health_flags::' | grep -vc healthy; curl -s 127.0.0.1:8080/metrics | grep '^entrypoint_weight' | tr '\n' ' '" 2>/dev/null)
  bad=$(echo "$out" | head -1); w=$(echo "$out" | tail -1)
  [ "$bad" = "0" ]; check "$1 업스트림 healthy" $? "비정상 ${bad:-?}개"
  echo "$w" | grep -q 'env="aws"} 100' ; check "$1 가중치 aws=100" $? "$w"
done

echo "== 앱"
c=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$APP/readyz"); [ "$c" = "200" ]; check "$APP /readyz (Cloudflare 경유)" $? "$c"
# 환경별 주소는 ALB(진입점·GKE NAT 만 허용)·내부 LB(VPC 안) 라 진입점 VM 안에서 본다
codes=$(gcloud compute ssh echo-dev-entry --zone asia-northeast3-a --tunnel-through-iap --configuration="$GCFG" --quiet --command \
  "for h in ${APP%%.*}.aws-tokyo.echoport.uk ${APP%%.*}.gcp-seoul.echoport.uk; do curl -s -o /dev/null -w '%{http_code} ' -m 10 https://\$h/readyz; done" 2>/dev/null)
set -- $codes
[ "$1" = "200" ]; check "${APP%%.*}.aws-tokyo /readyz (진입점 VM 에서)" $? "${1:-?}"
[ "$2" = "200" ]; check "${APP%%.*}.gcp-seoul /readyz (진입점 VM 에서)" $? "${2:-?}"

echo "== 관측·부하"
for c in "$A_CTX" "$B_CTX"; do r=$(kubectl --context "$c" -n echo-otel get deploy otel-collector -o jsonpath='{.status.readyReplicas}' 2>/dev/null); [ "${r:-0}" -ge 1 ]; check "OTel 수집기 ${c%%_*}" $? "ready=${r:-0}"; done
lg=$(kubectl --context "$B_CTX" -n echo-loadgen get deploy loadgen -o jsonpath='{.spec.replicas}' 2>/dev/null)
echo "  ℹ️  loadgen replicas=${lg:-없음} (시연 직전에만 make loadgen-on)"
cr=$(pg A -c "SELECT count(*) FROM echo_ops.cutover_runs;" 2>/dev/null)
[ -n "$cr" ]; check "결과 표 echo_ops.cutover_runs" $? "${cr:-읽기 실패}행"

echo; echo "통과 $ok · 실패 $ng"
[ "$ng" = "0" ]
