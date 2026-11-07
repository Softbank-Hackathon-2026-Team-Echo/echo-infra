#!/usr/bin/env bash
# 클라우드 → 온프레 요청 재생 시험 (인프라 12.4 × 18).
# GCP 가 안 보이는 온프레 사본(gcpcopy)에 빠진 쓰기를, 진입점 a 요청 기록으로 온프레 앱에 다시 보내 메운다.
#   1) 진입점 a 기록 켜기(journal.enabled=100)          2) 온프레 사본 구독 끄기(= GCP 안 보임)
#   3) 메인 주소로 멱등 키 쓰기 N건 → 클라우드에만 들어감   4) 서울 B 반영 대기
#   5) 온프레 앱을 사본으로 전환(gcp-to-onprem.sh failover) 6) 재생 2회(진입점 a 안에서, 토큰은 VM 밖으로 안 나옴)
#   7) 사본에 N건 request_id 확인                        8) 기록 끄기 → back → resync
# CONFIRM=yes 필요. N(기본 5).
source "$(dirname "$0")/common.sh"
[[ ${CONFIRM:-} == yes ]] || { echo "진입점 a 기록을 켜고 메인 주소에 쓰기 ${N:-5}건을 넣는다. 진행하려면 CONFIRM=yes $0" >&2; exit 2; }
N=${N:-5}
MAIN=${MAIN:-https://demo-y6cz3jrc.echoport.uk}
ONPREM=${ONPREM:-https://demo-onprem-y6cz3jrc.echoport.uk}
DIR=$(cd "$(dirname "$0")" && pwd)
REPLAY_SH="$DIR/../../scripts/replay.sh"
entry() { gcloud --configuration=echo compute ssh echo-dev-entry --zone asia-northeast3-a --tunnel-through-iap --quiet --command "$1"; }
bcount() { kubectl --context "$GCP_CTX" -n echo-data exec -i echo-pg-0 -c postgres -- psql -X -U postgres -d app -tA -c "select count(*) from demo.seq_write"; }
gq() { onprem_sh <<EOF
k3s kubectl -n echo-demo exec demo-db-0 -- psql -XAt -U demo -d gcpcopy -c "$1"
EOF
}
journal_off() { entry "curl -s -o /dev/null -X POST '127.0.0.1:9901/runtime_modify?journal.enabled=0'" && echo "[정리] 진입점 a 기록 끔"; }

echo "== 1 진입점 a 기록 켜기"
entry "curl -s -o /dev/null -X POST '127.0.0.1:9901/runtime_modify?journal.enabled=100'; curl -s 127.0.0.1:9901/runtime | grep -o '\"journal.enabled\"[^}]*}'"
trap journal_off EXIT
T0=$(date +%s); sleep 1

echo "== 2 온프레 사본 구독 끄기 (GCP 안 보임)"
gq "ALTER SUBSCRIPTION echo_gcp_onprem_sub DISABLE" >/dev/null
b0=$(bcount); echo "서울 B 시작 $b0 행"

echo "== 3 메인 주소로 쓰기 ${N}건 (멱등 키)"
KEYS=()
for i in $(seq 1 "$N"); do
  k="replay-onprem-$(date +%s)-$i-$RANDOM"; KEYS+=("$k")
  c=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST -H 'Content-Type: application/json' -H "Idempotency-Key: $k" "$MAIN/api/writes" -d '{}')
  echo "  $k → $c"
done

echo "== 4 서울 B 반영 대기"
for _ in $(seq 1 30); do b1=$(bcount); [[ $b1 -ge $((b0 + N)) ]] && break; sleep 1; done
in=$(printf "'%s'," "${KEYS[@]}"); in=${in%,}
bk=$(kubectl --context "$GCP_CTX" -n echo-data exec -i echo-pg-0 -c postgres -- psql -X -U postgres -d app -tA -c "select count(*) from demo.seq_write where request_id in ($in)")
echo "서울 B $b0 → $b1 행, 시험 키 $bk/$N 건"

echo "== 5 온프레 앱을 사본으로 전환"
CONFIRM=yes "$DIR/gcp-to-onprem.sh" failover
g1=$(gq "select count(*) from demo.seq_write"); k1=$(gq "select count(*) from demo.seq_write where request_id in ($in)")
echo "온프레 사본 $g1 행, 시험 키 $k1/$N 건 (빠진 쓰기 = $((N - k1))건)"

echo "== 6 재생 (진입점 a 안에서, 보낼 곳 = 온프레 주소, since=$T0)"
for run in 1 2; do
  echo "  [$run 회차]"
  entry "J=\$(sudo docker ps -qf name=journal | head -1); export JOURNAL_TOKEN=\$(sudo docker exec \$J printenv JOURNAL_TOKEN); JOURNAL_URL=http://127.0.0.1:8082 REPLAY_BASE=$ONPREM REPLAY_SINCE=$T0 bash -s" < "$REPLAY_SH" || true
done

echo "== 7 확인"
got=$(gq "select count(*) from demo.seq_write where request_id in ($in)")
g2=$(gq "select count(*) from demo.seq_write")
echo "온프레 사본: 시험 키 $got/$N 건, 전체 $g1 → $g2 행 (서울 B $b1)"
dup=$(gq "select count(*) - count(distinct request_id) from demo.seq_write where request_id is not null")
echo "온프레 사본 request_id 중복: $dup"

echo "== 8 정리"
journal_off; trap - EXIT
CONFIRM=yes "$DIR/gcp-to-onprem.sh" back
CONFIRM=yes "$DIR/gcp-to-onprem.sh" resync
