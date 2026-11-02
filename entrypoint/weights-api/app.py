#!/usr/bin/env python3
"""고정 진입점 가중치 API.

Envoy 가 읽는 파일 기반 xDS(/etc/envoy/dynamic/clusters.yaml·routes.yaml)를 만들고 바꾼다.
표준 라이브러리만 쓴다. echo-was 실행기가 PUT /weights 로 트래픽 비율을 옮긴다.

  GET  /health            살아 있나 (토큰 없이)
  GET  /metrics           Prometheus 형식: 현재 가중치 (토큰 없이, 내부망). healthy 호스트 수는 Envoy 가 직접 낸다
  GET  /weights           현재 가중치 {"aws": 90, "gcp": 10}
  PUT  /weights           가중치 변경. 모든 환경 키, 0~100 정수, 합 100
  GET  /status            가중치 + Envoy admin 에서 본 환경별 호스트·healthy 수
  GET  /summary           최근 30초 요약: 환경별 req/s·5xx 비율·p95·healthy 수 + 전체 + 가중치 (Prometheus 에서 읽음)

환경 변수
  WEIGHTS_TOKEN    Bearer 토큰 (비어 있으면 보호된 경로는 503)
  UPSTREAMS        "aws=host:port,gcp=host:port" (순서 = 우선순위 표기 순서)
  DEFAULT_WEIGHTS  "aws=100,gcp=0" (저장된 가중치가 없을 때)
  DYNAMIC_DIR      Envoy 와 공유하는 디렉터리 (기본 /etc/envoy/dynamic)
  ENVOY_ADMIN      Envoy admin 주소 (기본 http://envoy:9901)
  PROMETHEUS_URL   Prometheus 주소 (기본 http://prometheus:9090)
  HC_PATH          업스트림 헬스체크 경로 (기본 /healthz)
"""

import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DYNAMIC_DIR = os.environ.get("DYNAMIC_DIR", "/etc/envoy/dynamic")
STATE_DIR = os.path.join(DYNAMIC_DIR, "state")  # watched_directory 는 하위 디렉터리를 보지 않는다
STATE_PATH = os.path.join(STATE_DIR, "weights.json")
TOKEN = os.environ.get("WEIGHTS_TOKEN", "")
ENVOY_ADMIN = os.environ.get("ENVOY_ADMIN", "http://envoy:9901").rstrip("/")
PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090").rstrip("/")
HC_PATH = os.environ.get("HC_PATH", "/healthz")
LISTEN_PORT = int(os.environ.get("PORT", "8080"))

LOCK = threading.Lock()  # 쓰기(PUT)만 직렬화한다. 읽기는 CURRENT 를 통째로 바꾸므로 잠그지 않는다
CURRENT = {}  # 현재 가중치. seed()·apply_weights() 만 바꾼다. 파일은 재시작 복구용


def log(**kv):
    kv.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    print(json.dumps(kv, ensure_ascii=False), flush=True)


def parse_kv(raw, name):
    out = {}
    for item in filter(None, (s.strip() for s in raw.split(","))):
        if "=" not in item:
            raise SystemExit(f"{name}: '{item}' 은 key=value 꼴이어야 한다")
        k, v = item.split("=", 1)
        out[k.strip()] = v.strip()
    if not out:
        raise SystemExit(f"{name} 이 비어 있다")
    return out


UPSTREAMS = parse_kv(os.environ.get("UPSTREAMS", ""), "UPSTREAMS")
ENVS = list(UPSTREAMS)
for env, hp in UPSTREAMS.items():
    if ":" not in hp or not hp.rsplit(":", 1)[1].isdigit():
        raise SystemExit(f"UPSTREAMS: {env}={hp} 는 host:port 꼴이어야 한다")
    if not env.replace("-", "").replace("_", "").isalnum():
        raise SystemExit(f"UPSTREAMS: 환경 이름 {env} 에 쓸 수 없는 문자")

DEFAULT_WEIGHTS = {k: int(v) for k, v in parse_kv(os.environ.get("DEFAULT_WEIGHTS", f"{ENVS[0]}=100"), "DEFAULT_WEIGHTS").items()}
for env in ENVS:
    DEFAULT_WEIGHTS.setdefault(env, 0)


# ---------- 검증 ----------

def validate_weights(obj):
    if not isinstance(obj, dict):
        raise ValueError("본문은 JSON 객체여야 한다")
    if set(obj) != set(ENVS):
        raise ValueError(f"키는 정확히 {ENVS} 여야 한다")
    out = {}
    for env in ENVS:
        v = obj[env]
        if isinstance(v, bool) or not isinstance(v, (int, float)) or (isinstance(v, float) and not v.is_integer()):
            raise ValueError(f"{env}: 정수여야 한다")
        v = int(v)
        if not 0 <= v <= 100:
            raise ValueError(f"{env}: 0~100 이어야 한다")
        out[env] = v
    if sum(out.values()) != 100:
        raise ValueError("합이 100 이어야 한다")
    return out


# ---------- Envoy 파일 렌더링 ----------

def fallback_chain(env):
    """env 가 건강하면 env, 아니면 나머지 환경 순서대로. 예: [aws, gcp]"""
    return [env] + [e for e in ENVS if e != env]


def fallback_name(env):
    """aggregate 클러스터 이름. 예: aws_then_gcp"""
    return "_then_".join(fallback_chain(env))


def xds_header(note):
    return [
        f"# weights-api 가 만든 파일. 손으로 고치지 않는다 ({note}).",
        f'version_info: "{int(time.time() * 1000)}"',
        "resources:",
    ]


def render_clusters():
    lines = xds_header("UPSTREAMS 환경 변수를 바꾼다")
    for env in ENVS:
        host, port = UPSTREAMS[env].rsplit(":", 1)
        lines += [
            '  - "@type": type.googleapis.com/envoy.config.cluster.v3.Cluster',
            f"    name: {env}",
            "    type: STRICT_DNS",
            "    dns_lookup_family: V4_ONLY",
            "    connect_timeout: 2s",
            "    lb_policy: ROUND_ROBIN",
            "    # 건강한 호스트가 없으면 panic 라우팅으로 죽은 호스트에 보내지 않는다 (대신 다음 환경으로)",
            "    common_lb_config:",
            "      healthy_panic_threshold: { value: 0 }",
            "    load_assignment:",
            f"      cluster_name: {env}",
            "      endpoints:",
            "        - lb_endpoints:",
            "            - endpoint:",
            "                address:",
            f'                  socket_address: {{ address: "{host}", port_value: {int(port)} }}',
            "    health_checks:",
            "      - timeout: 1s",
            "        interval: 2s",
            "        no_traffic_interval: 2s",
            "        unhealthy_threshold: 2",
            "        healthy_threshold: 1",
            "        http_health_check:",
            f'          path: "{HC_PATH}"',
            "    outlier_detection:",
            "      consecutive_5xx: 3",
            "      consecutive_gateway_failure: 3",
            "      interval: 2s",
            "      base_ejection_time: 10s",
            "      max_ejection_percent: 100",
        ]
    for env in ENVS:
        lines += [
            '  - "@type": type.googleapis.com/envoy.config.cluster.v3.Cluster',
            f"    name: {fallback_name(env)}",
            "    connect_timeout: 2s",
            "    lb_policy: CLUSTER_PROVIDED",
            "    common_lb_config:",
            "      healthy_panic_threshold: { value: 0 }",
            "    cluster_type:",
            "      name: envoy.clusters.aggregate",
            "      typed_config:",
            '        "@type": type.googleapis.com/envoy.extensions.clusters.aggregate.v3.ClusterConfig',
            f"        clusters: [{', '.join(fallback_chain(env))}]",
        ]
    return "\n".join(lines) + "\n"


def render_routes(weights):
    lines = xds_header("PUT /weights") + [
        '  - "@type": type.googleapis.com/envoy.config.route.v3.RouteConfiguration',
        "    name: echo_routes",
        "    virtual_hosts:",
        "      - name: customer_apps",
        '        domains: ["*"]',
        "        routes:",
        "          # 진입점 자체 상태 (Cloudflare·외부 감시용)",
        "          - match: { path: /__entry/healthz }",
        "            direct_response: { status: 200, body: { inline_string: \"ok\\n\" } }",
        "          - match: { prefix: / }",
        "            route:",
        "              timeout: 30s",
        "              retry_policy:",
        "                retry_on: connect-failure,refused-stream,reset",
        "                num_retries: 2",
        "                per_try_timeout: 5s",
        "                retry_host_predicate:",
        "                  - name: envoy.retry_host_predicates.previous_hosts",
        "                    typed_config:",
        '                      "@type": type.googleapis.com/envoy.extensions.retry.host.previous_hosts.v3.PreviousHostsPredicate',
        "                host_selection_retry_max_attempts: 3",
        "              weighted_clusters:",
        "                clusters:",
    ]
    for env in ENVS:
        lines += [
            f"                  - name: {fallback_name(env)}",
            f"                    weight: {weights[env]}",
        ]
    return "\n".join(lines) + "\n"


def write_atomic(path, text):
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)  # 같은 디렉터리 안 rename → Envoy watched_directory 가 감지


def load_saved_weights():
    """재시작 복구용. 저장된 값이 없거나 깨졌으면 기본값."""
    try:
        with open(STATE_PATH, encoding="utf-8") as f:
            return validate_weights(json.load(f))
    except FileNotFoundError:
        return dict(DEFAULT_WEIGHTS)
    except (ValueError, json.JSONDecodeError) as e:
        log(level="warn", msg="저장된 가중치가 깨져 기본값을 쓴다", error=str(e))
        return dict(DEFAULT_WEIGHTS)


def apply_weights(weights):
    global CURRENT
    write_atomic(STATE_PATH, json.dumps(weights))
    write_atomic(os.path.join(DYNAMIC_DIR, "routes.yaml"), render_routes(weights))
    CURRENT = dict(weights)


def seed():
    os.makedirs(STATE_DIR, exist_ok=True)
    write_atomic(os.path.join(DYNAMIC_DIR, "clusters.yaml"), render_clusters())
    apply_weights(load_saved_weights())
    log(msg="seeded", upstreams=UPSTREAMS, weights=CURRENT)


# ---------- Envoy admin ----------

def envoy_cluster_health():
    """{env: {"hosts": n, "healthy": m}} 또는 None(Envoy 접속 실패)"""
    try:
        with urllib.request.urlopen(f"{ENVOY_ADMIN}/clusters?format=json", timeout=3) as r:
            data = json.load(r)
    except (urllib.error.URLError, json.JSONDecodeError, OSError):
        return None
    out = {env: {"hosts": 0, "healthy": 0} for env in ENVS}
    for cs in data.get("cluster_statuses", []):
        name = cs.get("name")
        if name not in out:
            continue
        for hs in cs.get("host_statuses", []):
            h = hs.get("health_status", {})
            healthy = (
                not h.get("failed_active_health_check", False)
                and not h.get("failed_outlier_check", False)
                and h.get("eds_health_status", "HEALTHY") != "UNHEALTHY"
            )
            out[name]["hosts"] += 1
            out[name]["healthy"] += 1 if healthy else 0
    return out


# ---------- Prometheus 요약 ----------

def prom_query(expr):
    """즉시 쿼리 결과를 {라벨값: float} 로. 실패하면 None."""
    url = f"{PROMETHEUS_URL}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    try:
        with urllib.request.urlopen(url, timeout=3) as r:
            data = json.load(r)
    except (urllib.error.URLError, json.JSONDecodeError, OSError):
        return None
    if data.get("status") != "success":
        return None
    out = {}
    for item in data["data"]["result"]:
        label = item["metric"].get("envoy_cluster_name", "")
        value = float(item["value"][1])
        out[label] = None if value != value else value  # NaN → None
    return out


def summary(window="30s"):
    """환경별 요청 수·5xx 비율·p95·healthy 호스트와 전체 요청 수. echo-was 측정 기록·프론트 근거 화면용."""
    envs = "|".join(ENVS)
    rps = prom_query(f'sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_total{{envoy_cluster_name=~"{envs}"}}[{window}]))')
    err = prom_query(f'sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_xx{{envoy_response_code_class="5",envoy_cluster_name=~"{envs}"}}[{window}]))')
    # 지연 히스토그램은 라우트의 aggregate 클러스터(aws_then_gcp)에 기록된다. 첫 환경 기준으로 돌려준다.
    p95 = prom_query(f'histogram_quantile(0.95, sum by (le, envoy_cluster_name) (rate(envoy_cluster_upstream_rq_time_bucket{{envoy_cluster_name=~".+_then_.+"}}[{window}])))')
    healthy = prom_query(f'envoy_cluster_membership_healthy{{envoy_cluster_name=~"{envs}"}}')
    hosts = prom_query(f'envoy_cluster_membership_total{{envoy_cluster_name=~"{envs}"}}')
    total = prom_query(f'sum(rate(envoy_http_downstream_rq_total{{envoy_http_conn_manager_prefix="ingress_http"}}[{window}]))')
    total_err = prom_query(f'sum(rate(envoy_http_downstream_rq_xx{{envoy_http_conn_manager_prefix="ingress_http",envoy_response_code_class="5"}}[{window}]))')
    ok = all(x is not None for x in (rps, err, p95, healthy, hosts, total, total_err))

    def ratio(num, den):
        if num is None or den is None or not den:
            return None
        return round(num / den, 4)

    def first(d):
        return next(iter(d.values()), None) if d else None

    per_env = {}
    for env in ENVS:
        r = (rps or {}).get(env)
        e = (err or {}).get(env)
        lat = (p95 or {}).get(fallback_name(env))
        per_env[env] = {
            "rps": None if r is None else round(r, 3),
            "error_ratio": ratio(e, r) if r else (0.0 if r == 0 else None),
            "p95_ms": None if lat is None else round(lat, 1),
            "healthy_hosts": None if healthy is None else int(healthy.get(env, 0)),
            "hosts": None if hosts is None else int(hosts.get(env, 0)),
            "weight": CURRENT.get(env),
        }
    t = first(total)
    te = first(total_err)
    return {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "window": window,
        "weights": dict(CURRENT),
        "total": {"rps": None if t is None else round(t, 3), "error_ratio": ratio(te, t) if t else (0.0 if t == 0 else None)},
        "envs": per_env,
        "prometheus": "ok" if ok else "unreachable",
    }


# ---------- HTTP ----------

class Handler(BaseHTTPRequestHandler):
    server_version = "weights-api/1"

    def log_message(self, fmt, *args):  # 기본 stderr 로그 대신 JSON
        log(method=self.command, path=self.path, status=args[1] if len(args) > 1 else None, client=self.client_address[0])

    def _send(self, status, body, content_type=None):
        raw = body.encode("utf-8") if isinstance(body, str) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type or "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _authorized(self):
        if not TOKEN:
            self._send(503, {"error": "WEIGHTS_TOKEN 이 설정되지 않았다"})
            return False
        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {TOKEN}":
            self._send(401, {"error": "Bearer 토큰이 필요하다"})
            return False
        return True

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ready": True})  # seed() 가 끝나야 서버가 뜬다
        if self.path == "/metrics":
            return self._send(200, self._metrics(), "text/plain; version=0.0.4; charset=utf-8")
        if self.path == "/weights":
            if not self._authorized():
                return
            return self._send(200, dict(CURRENT))
        if self.path.split("?", 1)[0] == "/summary":
            if not self._authorized():
                return
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            window = q.get("window", ["30s"])[0]
            if not re.fullmatch(r"[1-9][0-9]{0,3}[smh]", window):
                return self._send(400, {"error": "window 는 30s·5m 같은 꼴이어야 한다"})
            return self._send(200, summary(window))
        if self.path == "/status":
            if not self._authorized():
                return
            health = envoy_cluster_health()
            return self._send(200, {
                "weights": dict(CURRENT),
                "upstreams": {env: {"address": UPSTREAMS[env], **((health or {}).get(env, {"hosts": None, "healthy": None}))} for env in ENVS},
                "envoy": "ok" if health is not None else "unreachable",
            })
        self._send(404, {"error": "없는 경로"})

    def do_PUT(self):
        if self.path != "/weights":
            return self._send(404, {"error": "없는 경로"})
        if not self._authorized():
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(n) or b"{}")
            weights = validate_weights(body)
        except (ValueError, json.JSONDecodeError) as e:
            return self._send(400, {"error": str(e)})
        with LOCK:
            before = dict(CURRENT)
            apply_weights(weights)
        log(msg="weights changed", before=before, after=weights, client=self.client_address[0])
        self._send(200, weights)

    def _metrics(self):
        out = ["# HELP entrypoint_weight 환경별 트래픽 가중치 (0~100)", "# TYPE entrypoint_weight gauge"]
        out += [f'entrypoint_weight{{env="{env}"}} {w}' for env, w in CURRENT.items()]
        return "\n".join(out) + "\n"


def main():
    seed()
    srv = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    log(msg="listening", port=LISTEN_PORT, envs=ENVS, token_set=bool(TOKEN))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
