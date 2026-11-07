#!/usr/bin/env bash
# 온프레 장애 흉내 (인프라 18). 쓰기를 넣는 도중에 온프레 기기 nft 로 GKE NAT 의 5432 를 끊고 앱을 0 으로 내린다.
# AWS B2 연결(도쿄 NAT)은 끊지 않는다 → AWS B2 가 "온프레의 마지막 상태" 증인이 되어 failover.sh 가 잃은 행을 센다.
#   down: 쓰기 LOAD_SEC 초(기본 10) 뒤 끊기     up: 되돌리기(nft 표 삭제, 앱 1)
# 기기를 멈추지 않으므로 되돌리기가 확실하다. CVE 완화 표(cve_2026_98432)는 건드리지 않는다.
source "$(dirname "$0")/common.sh"
GKE_NAT="${GKE_NAT:-34.64.211.218}"
LOAD_SEC="${LOAD_SEC:-10}"

case "${1:-}" in
  down)
    onprem_sh <<EOF
set -e
K="k3s kubectl -n echo-demo"
APP=\$(\$K get svc demo-app -o jsonpath='{.spec.clusterIP}')
rm -f /tmp/echo-stop-load /tmp/echo-load-ok
# 쓰기 부하: 하나씩 연달아 POST. 201 받은 수를 센다.
( ok=0; while [ ! -f /tmp/echo-stop-load ]; do
    c=\$(curl -s -o /dev/null -w '%{http_code}' -m 2 -X POST -H 'Content-Type: application/json' http://\$APP/api/writes -d '{}' || true)
    [ "\$c" = 201 ] && ok=\$((ok+1))
  done; echo \$ok > /tmp/echo-load-ok ) &
sleep $LOAD_SEC
# 장애 순간: 쓰기 멈춤과 복제 끊기를 붙여서 한다. 이때 진행 중이던 쓰기는 진짜 장애처럼 결과가 갈린다.
touch /tmp/echo-stop-load
nft -f - <<'NFT'
table inet echo_failover_test {
  chain prerouting {
    type filter hook prerouting priority raw; policy accept;
    ip saddr $GKE_NAT tcp dport { 5432, 32047 } counter drop comment "infra-18 failover test"
  }
}
NFT
cut=\$(date -u +%FT%T.%3NZ)
wait
\$K scale deploy demo-app --replicas=0 >/dev/null
echo "down \$cut, 부하 ${LOAD_SEC}s 동안 201 받은 쓰기 \$(cat /tmp/echo-load-ok)건"
EOF
    ;;
  up)
    onprem_sh <<'EOF'
set -e
nft delete table inet echo_failover_test 2>/dev/null || true
k3s kubectl -n echo-demo scale deploy demo-app --replicas=1 >/dev/null
k3s kubectl -n echo-demo rollout status deploy demo-app --timeout=120s >/dev/null
echo "up $(date -u +%FT%T.%3NZ)"
EOF
    ;;
  *) echo "사용법: $0 down|up" >&2; exit 2 ;;
esac
