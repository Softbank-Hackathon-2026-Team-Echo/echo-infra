#!/usr/bin/env bash
# OTel 수집기 로컬 시험 (인프라 9). 운영 클러스터·진입점을 건드리지 않는다. Docker 만 있으면 된다.
#
#   bash cluster-addons/otel-collector/local-test/run.sh up <앱 이미지>   # 예 echo-demo-app:local (echo-demo-app 에서 docker build)
#   bash cluster-addons/otel-collector/local-test/run.sh check            # 진입점 흉내 Prometheus a·b 에 들어온 값 확인
#   bash cluster-addons/otel-collector/local-test/run.sh down             # 모두 지움
#
# 구성: Docker 네트워크 하나에 k3s(온프레와 같은 v1.36.5+k3s1) + Prometheus v3.15.1 두 대(진입점 a·b 흉내:
# remote write 수신 + entrypoint/scripts/render-prometheus-web.sh 로 만든 basic auth). 수집기는 overlays/onprem
# (128Mi 제한)을 바탕으로 속성만 cloud.provider=local 로 바꾼 overlay 를 .out/ 에 만들어 적용한다.
# 비밀번호는 .out/rw-password(0600)에만 둔다. 출력하지 않는다.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
OUT="$HERE/.out"
PFX=${OTEL_LOCAL_PREFIX:-otel-local}
NET=$PFX-net
K3S_IMAGE=rancher/k3s:v1.36.5-k3s1
PROM_IMAGE=prom/prometheus:v3.15.1
COL_IMAGE=$(sed -n 's/^ *image: \(otel\/opentelemetry-collector-contrib:.*\)$/\1/p' "$REPO/cluster-addons/otel-collector/base/resources.yaml")
PORT_A=${PORT_A:-19190}
PORT_B=${PORT_B:-19191}

k() { docker exec -i "$PFX-k3s" kubectl "$@"; }
log() { echo "[local-test] $*"; }

up() {
  local app_image=${1:?앱 이미지 (예 echo-demo-app:local)}
  mkdir -p "$OUT"; chmod 700 "$OUT"
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

  # 1. 진입점 흉내 Prometheus 두 대 (진입점 compose 와 같은 플래그)
  # 끝 줄바꿈 없이 쓴다. Secret 을 --from-file 로 만들면 줄바꿈까지 비밀번호가 되어 401 이 난다(로컬에서 겪음)
  [ -f "$OUT/rw-password" ] || (umask 077; openssl rand -hex 24 | tr -d '\n' > "$OUT/rw-password")
  bash "$REPO/entrypoint/scripts/render-prometheus-web.sh" "$OUT/prometheus-web.yml" echo-otel < "$OUT/rw-password"
  printf 'global:\n  scrape_interval: 15s\nscrape_configs: []\n' > "$OUT/prometheus.yml"
  for x in a:$PORT_A b:$PORT_B; do
    n=${x%%:*}; p=${x##*:}
    docker rm -f "$PFX-prom-$n" >/dev/null 2>&1 || true
    docker run -d --name "$PFX-prom-$n" --network "$NET" -p "127.0.0.1:$p:9090" \
      -v "$OUT/prometheus.yml:/etc/prometheus/prometheus.yml:ro" -v "$OUT/prometheus-web.yml:/etc/prometheus/web.yml:ro" \
      "$PROM_IMAGE" --config.file=/etc/prometheus/prometheus.yml --web.config.file=/etc/prometheus/web.yml \
      --web.enable-remote-write-receiver >/dev/null
  done

  # 2. k3s (traefik·metrics-server 는 끈다)
  if ! docker ps --format '{{.Names}}' | grep -qx "$PFX-k3s"; then
    docker rm -f "$PFX-k3s" >/dev/null 2>&1 || true
    docker run -d --privileged --name "$PFX-k3s" --network "$NET" "$K3S_IMAGE" server \
      --disable traefik --disable metrics-server >/dev/null
  fi
  log "k3s 노드 준비 기다림"
  for _ in $(seq 1 90); do k get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 2; done
  k get nodes

  # 3. 이미지 넣기 (k3s 안에서 받지 않게)
  for img in "$app_image" "$COL_IMAGE"; do
    docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null
    docker save "$img" | docker exec -i "$PFX-k3s" ctr -n k8s.io images import - >/dev/null
  done

  # 4. 앱 + 트래픽
  sed "s#APP_IMAGE#$app_image#g" "$HERE/apps.yaml" | k apply -f - >/dev/null

  # 5. 수집기: onprem overlay(128Mi) 위에 local 속성·진입점 흉내 주소. Prometheus 는 컨테이너 IP 로 부른다
  #    (k3s 파드의 DNS 는 Docker 내장 DNS 를 못 쓴다)
  ip_a=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$PFX-prom-a")
  ip_b=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$PFX-prom-b")
  mkdir -p "$OUT/overlay"
  printf '%s\n' \
    "apiVersion: kustomize.config.k8s.io/v1beta1" "kind: Kustomization" \
    "resources:" "  - ../../../overlays/onprem" \
    "configMapGenerator:" "  - name: otel-collector-env" "    namespace: echo-otel" "    behavior: merge" "    literals:" \
    "      - CLOUD_PROVIDER=local" "      - CLOUD_REGION=local" "      - K8S_CLUSTER_NAME=$PFX-k3s" \
    "      - ENTRY_A_ENDPOINT=http://$ip_a:9090/api/v1/write" "      - ENTRY_B_ENDPOINT=http://$ip_b:9090/api/v1/write" \
    > "$OUT/overlay/kustomization.yaml"
  kubectl kustomize "$OUT/overlay" > "$OUT/collector.yaml" # 호스트 kubectl(kustomize 내장) 필요
  k apply -f - < "$OUT/collector.yaml" >/dev/null
  # Secret 은 저장소 밖에서 만든다(운영과 같은 모양: username·password)
  k -n echo-otel delete secret otel-remote-write --ignore-not-found >/dev/null
  k -n echo-otel create secret generic otel-remote-write --from-literal=username=echo-otel \
    --from-file=password=/dev/stdin < "$OUT/rw-password" >/dev/null
  k -n echo-otel rollout restart deploy/otel-collector >/dev/null
  k -n echo-otel rollout status deploy/otel-collector --timeout=180s
  k -n demo-local rollout status deploy/app --timeout=180s
  log "준비됨. 1~2분 뒤 'run.sh check'"
}

q() { # $1=포트 $2=PromQL → 결과 JSON
  curl -s -u "echo-otel:$(cat "$OUT/rw-password")" --data-urlencode "query=$2" "http://127.0.0.1:$1/api/v1/query"
}

check() {
  # 대시보드 「세 환경 한 그래프」 행과 같은 식 (entrypoint/config/grafana/provisioning/dashboards/entrypoint.json)
  local f='path!~"/healthz|/readyz|/metrics"'
  local q_rps="sum by (cloud_provider) (rate(http_requests_total{$f}[1m]))"
  local q_err="sum by (cloud_provider) (rate(http_requests_total{$f,status=~'5..'}[1m])) / sum by (cloud_provider) (rate(http_requests_total{$f}[1m]))"
  local q_p95="histogram_quantile(0.95, sum by (le, cloud_provider) (rate(http_request_duration_seconds_bucket{$f}[1m])))"
  local q_p95_path="histogram_quantile(0.95, sum by (le, cloud_provider, path) (rate(http_request_duration_seconds_bucket{$f}[1m])))"
  for x in a:$PORT_A b:$PORT_B; do
    n=${x%%:*}; p=${x##*:}
    echo "== 진입점 흉내 Prometheus $n"
    q "$p" 'http_requests_total{cloud_provider="local"}' | python3 -c '
import json,sys
r=json.load(sys.stdin)["data"]["result"]
print("  http_requests_total{cloud_provider=\"local\"} 시계열:",len(r))
for s in sorted(r,key=lambda s:(s["metric"].get("path",""),s["metric"].get("status",""))):
    m=s["metric"]; print("   ",{k:m.get(k) for k in ("namespace","app","path","method","status","cloud_provider","cloud_region","k8s_cluster_name")},"=",s["value"][1])'
    echo "  라벨 없는 파드(other-local) 시계열 수: $(q "$p" 'count(http_requests_total{namespace="other-local"})' | python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else 0)') (0 이어야 함)"
    echo "  [패널] 요청 수 req/s: $(q "$p" "$q_rps" | python3 -c 'import json,sys;print([(s["metric"],round(float(s["value"][1]),3)) for s in json.load(sys.stdin)["data"]["result"]])')"
    echo "  [패널] 오류율: $(q "$p" "$q_err" | python3 -c 'import json,sys;print([(s["metric"],round(float(s["value"][1]),3)) for s in json.load(sys.stdin)["data"]["result"]])')"
    echo "  [패널] p95 초: $(q "$p" "$q_p95" | python3 -c 'import json,sys;print([(s["metric"],round(float(s["value"][1]),3)) for s in json.load(sys.stdin)["data"]["result"]])')"
    echo "  (참고) 경로별 p95 초: $(q "$p" "$q_p95_path" | python3 -c 'import json,sys;print([(s["metric"],round(float(s["value"][1]),3)) for s in json.load(sys.stdin)["data"]["result"]])')"
    echo "  target_info 시계열: $(q "$p" 'count(target_info)' | python3 -c 'import json,sys;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else 0)')"
    echo "  지표 이름 목록: $(curl -s -u "echo-otel:$(cat "$OUT/rw-password")" "http://127.0.0.1:$p/api/v1/label/__name__/values" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"])')"
  done
  echo "== 수집기"
  k -n echo-otel get pods -o wide
  echo "  재시작 수: $(k -n echo-otel get pods -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')"
  echo "  메모리 제한: $(k -n echo-otel get deploy otel-collector -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')"
  echo "  컨테이너 메모리 사용(crictl stats):"
  cid=$(docker exec "$PFX-k3s" crictl ps --name otelcol -q | head -1)
  docker exec "$PFX-k3s" crictl stats "$cid" | sed 's/^/    /'
  echo "  수집기 로그 오류 줄 수: $(k -n echo-otel logs deploy/otel-collector | grep -ciE '"level":"error"|\berror\b' || true)"
}

down() {
  docker rm -f "$PFX-k3s" "$PFX-prom-a" "$PFX-prom-b" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$OUT"
  log "지움: $(docker ps -a --format '{{.Names}}' | grep -c "^$PFX-" || true) 개 남음"
}

case "${1:-}" in
  up) shift; up "$@" ;;
  check) check ;;
  down) down ;;
  *) echo "사용: $0 up <앱 이미지> | check | down" >&2; exit 2 ;;
esac
