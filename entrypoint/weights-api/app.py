#!/usr/bin/env python3
"""고정 진입점 가중치 API.

Envoy 가 읽는 파일 기반 xDS(/etc/envoy/dynamic/clusters.yaml·routes.yaml)를 만들고 바꾼다.
표준 라이브러리만 쓴다. echo-was 실행기가 PUT /weights 로 트래픽 비율을 옮긴다.

  GET  /health            살아 있나 (토큰 없이)
  GET  /metrics           Prometheus 형식: 현재 가중치 (토큰 없이, 내부망). healthy 호스트 수는 Envoy 가 직접 낸다
  GET  /weights           현재 가중치 {"aws": 90, "gcp": 10}
  PUT  /weights           가중치 변경. 모든 환경 키, 0~100 정수, 합 100
  GET  /status            가중치 + Envoy admin 에서 본 환경별 호스트·healthy 수
  GET  /summary           최근 30초 요약: 환경별 req/s·5xx 비율·p95·healthy 수 + 전체 + 가중치 (Prometheus 에서 읽음, 참고용)
  GET  /counters          Envoy 시작 이후 환경별 누적 요청·오류 수 (Envoy admin 호스트 통계). 건수 기반 판정은 이걸 쓴다

환경 변수
  WEIGHTS_TOKEN    Bearer 토큰 (비어 있으면 보호된 경로는 503)
  UPSTREAMS        "aws=host:port,gcp=host:port" (순서 = 우선순위 표기 순서)
  DEFAULT_WEIGHTS  "aws=100,gcp=0" (저장된 가중치가 없을 때)
  DYNAMIC_DIR      Envoy 와 공유하는 디렉터리 (기본 /etc/envoy/dynamic)
  ENVOY_ADMIN      Envoy admin 주소 (기본 http://envoy:9901)
  PROMETHEUS_URL   Prometheus 주소 (기본 http://prometheus:9090)
  PROMETHEUS_BASIC_AUTH  "사용자:비밀번호" — Prometheus 가 basic auth(web.yml)를 켰을 때 쿼리에 붙인다 (인프라 9).
                   비어 있으면 붙이지 않는다. 인증이 꺼진 Prometheus 는 이 헤더를 무시한다
  HC_PATH          업스트림 헬스체크 경로 (기본 /healthz)
  SYNC_FROM        보조 진입점일 때 주 진입점의 가중치 API 주소 (예 http://10.60.0.6:8080). 2초마다 GET /weights 로 맞춘다.
                   주가 죽으면 마지막 값을 유지한다 (인프라 5.1 진입점 두 곳 PoC). 비어 있으면 동기화 없음
  SERVICE_ROUTING_ENABLED  0(기본 legacy) 또는 1(서비스별 격리). 잘못된 값은 시작 거절
  SERVICE_ROUTES_FILE      검증된 serviceId/publicHost/환경 UUID/origin 등록 JSON의 읽기 전용 경로

서비스 모드 계약: contracts/service-routing.md. ON에서 전역 weights API는 거절하며
v1 서비스 scope 요청만 처리한다. DB·자동 fallback 목적지 자격·온프레 TLS는 별도 범위다.
"""

import base64
import copy
import fcntl
import hashlib
import uuid
from pathlib import Path
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
_PROM_AUTH = os.environ.get("PROMETHEUS_BASIC_AUTH", "")
PROM_HEADERS = {"Authorization": "Basic " + base64.b64encode(_PROM_AUTH.encode()).decode()} if _PROM_AUTH else {}
HC_PATH = os.environ.get("HC_PATH", "/healthz")
SYNC_FROM = os.environ.get("SYNC_FROM", "").rstrip("/")
SYNC_INTERVAL = float(os.environ.get("SYNC_INTERVAL", "2"))
LISTEN_PORT = int(os.environ.get("PORT", "8080"))
if os.environ.get("SERVICE_ROUTING_ENABLED", "0") not in ("0", "1"):
    raise ValueError("SERVICE_ROUTING_ENABLED must be 0 or 1; refusing silent legacy fallback")
SERVICE_ROUTING_ENABLED = os.environ.get("SERVICE_ROUTING_ENABLED", "0") == "1"
SERVICE_ROUTES_FILE = os.environ.get("SERVICE_ROUTES_FILE", "")
SCOPED_STORE = None

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


UPSTREAMS = {} if SERVICE_ROUTING_ENABLED else parse_kv(os.environ.get("UPSTREAMS", ""), "UPSTREAMS")
ENVS = list(UPSTREAMS)
for env, hp in UPSTREAMS.items():
    if ":" not in hp or not hp.rsplit(":", 1)[1].isdigit():
        raise SystemExit(f"UPSTREAMS: {env}={hp} 는 host:port 꼴이어야 한다")
    if not env.replace("-", "").replace("_", "").isalnum():
        raise SystemExit(f"UPSTREAMS: 환경 이름 {env} 에 쓸 수 없는 문자")

DEFAULT_WEIGHTS = {} if SERVICE_ROUTING_ENABLED else {k: int(v) for k, v in parse_kv(os.environ.get("DEFAULT_WEIGHTS", f"{ENVS[0]}=100"), "DEFAULT_WEIGHTS").items()}
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
    directory_fd = os.open(os.path.dirname(path) or ".", os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


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
    global SCOPED_STORE
    os.makedirs(STATE_DIR, exist_ok=True)
    if SERVICE_ROUTING_ENABLED:
        SCOPED_STORE = ServiceRouteStore(DYNAMIC_DIR, SERVICE_ROUTES_FILE)
        SCOPED_STORE.seed()
        return
    write_atomic(os.path.join(DYNAMIC_DIR, "clusters.yaml"), render_clusters())
    apply_weights(load_saved_weights())
    log(msg="seeded", upstreams=UPSTREAMS, weights=CURRENT)


# ---------- Envoy admin ----------

def envoy_hosts():
    """환경별 호스트 상태 목록 {env: [host_status, …]} 또는 None(Envoy 접속 실패)."""
    try:
        with urllib.request.urlopen(f"{ENVOY_ADMIN}/clusters?format=json", timeout=3) as r:
            data = json.load(r)
    except (urllib.error.URLError, json.JSONDecodeError, OSError):
        return None
    out = {env: [] for env in ENVS}
    for cs in data.get("cluster_statuses", []):
        if cs.get("name") in out:
            out[cs["name"]].extend(cs.get("host_statuses", []))
    return out


def envoy_cluster_health():
    """{env: {"hosts": n, "healthy": m}} 또는 None(Envoy 접속 실패)"""
    hosts = envoy_hosts()
    if hosts is None:
        return None
    out = {}
    for env, statuses in hosts.items():
        healthy = 0
        for hs in statuses:
            h = hs.get("health_status", {})
            healthy += (
                not h.get("failed_active_health_check", False)
                and not h.get("failed_outlier_check", False)
                and h.get("eds_health_status", "HEALTHY") != "UNHEALTHY"
            )
        out[env] = {"hosts": len(statuses), "healthy": healthy}
    return out


def envoy_counters():
    """{env: {"requests": n, "errors_5xx": m, "hosts": k}} 또는 None(Envoy 접속 실패). Envoy 시작 이후 누적값.

    Envoy 는 응답 코드(5xx)를 경로(aggregate) 클러스터에만 기록하므로 환경별 값은 실제 환경 클러스터의
    호스트 통계(rq_total·rq_error)를 합한다. rq_error = 5xx 응답 + 연결 실패·시간 초과(클라이언트에는 503).
    호스트 집합이 바뀌면(ALB IP 교체, Envoy 재시작) 값이 줄 수 있다 → 부르는 쪽은 줄어든 시점에 기준값을 다시 잡는다.
    """
    hosts = envoy_hosts()
    if hosts is None:
        return None
    out = {}
    for env, statuses in hosts.items():
        c = {"requests": 0, "errors_5xx": 0, "hosts": len(statuses)}
        for hs in statuses:
            stats = {st.get("name"): int(st.get("value", 0)) for st in hs.get("stats", [])}
            c["requests"] += stats.get("rq_total", 0)
            c["errors_5xx"] += stats.get("rq_error", 0)
        out[env] = c
    return out


# ---------- Prometheus 요약 ----------

def prom_query(expr):
    """즉시 쿼리 결과를 {라벨값: float} 로. 실패하면 None."""
    url = f"{PROMETHEUS_URL}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=PROM_HEADERS), timeout=3) as r:
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
    """환경별 요청 수·5xx 비율·p95·healthy 호스트와 전체 요청 수. 근거 화면·참고용(판정은 /counters).

    요청 수(rps)는 실제 환경 클러스터에 기록되지만 응답 코드(5xx·완료 수)와 지연은 경로 클러스터(aws_then_gcp)에만
    기록된다. 그래서 error_ratio·p95 는 "그 환경을 첫 순위로 하는 경로" 기준이다 — 환경이 건강하면 그 환경 값이다.
    """
    envs = "|".join(ENVS)
    rps = prom_query(f'sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_total{{envoy_cluster_name=~"{envs}"}}[{window}]))')
    err = prom_query(f'sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_xx{{envoy_response_code_class="5",envoy_cluster_name=~".+_then_.+"}}[{window}]))')
    done = prom_query(f'sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_completed{{envoy_cluster_name=~".+_then_.+"}}[{window}]))')
    p95 = prom_query(f'histogram_quantile(0.95, sum by (le, envoy_cluster_name) (rate(envoy_cluster_upstream_rq_time_bucket{{envoy_cluster_name=~".+_then_.+"}}[{window}])))')
    healthy = prom_query(f'envoy_cluster_membership_healthy{{envoy_cluster_name=~"{envs}"}}')
    hosts = prom_query(f'envoy_cluster_membership_total{{envoy_cluster_name=~"{envs}"}}')
    total = prom_query(f'sum(rate(envoy_http_downstream_rq_total{{envoy_http_conn_manager_prefix="ingress_http"}}[{window}]))')
    total_err = prom_query(f'sum(rate(envoy_http_downstream_rq_xx{{envoy_http_conn_manager_prefix="ingress_http",envoy_response_code_class="5"}}[{window}]))')
    ok = all(x is not None for x in (rps, err, done, p95, healthy, hosts, total, total_err))

    def ratio(num, den):
        if num is None or den is None or not den:
            return None
        return round(num / den, 4)

    def first(d):
        return next(iter(d.values()), None) if d else None

    per_env = {}
    for env in ENVS:
        r = (rps or {}).get(env)
        # 5xx 가 한 번도 없던 경로는 Prometheus 에 시계열 자체가 없다(usedonly) → 조회가 됐다면 0 으로 본다
        e = None if err is None else err.get(fallback_name(env), 0.0)
        d = (done or {}).get(fallback_name(env))
        lat = (p95 or {}).get(fallback_name(env))
        per_env[env] = {
            "rps": None if r is None else round(r, 3),
            "error_ratio": ratio(e, d) if d else (0.0 if d == 0 else None),
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
        if SERVICE_ROUTING_ENABLED and self.path != "/metrics":
            return self._service_request()
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
        if self.path == "/counters":
            if not self._authorized():
                return
            counters = envoy_counters()
            if counters is None:
                return self._send(503, {"error": "Envoy admin 에 접속할 수 없다"})
            return self._send(200, {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "envs": counters})
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
        if SERVICE_ROUTING_ENABLED:
            return self._service_request()
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

    def _service_request(self):
        if not self._authorized():
            return
        try:
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.path in ("/weights", "/summary", "/counters", "/status"):
                raise RouteError(409, "LEGACY_DISABLED")
            if parsed.path == "/v1/snapshot" and self.command == "GET":
                return self._send(200, SCOPED_STORE.snapshot())
            match = re.fullmatch(r"/v1/services/([^/]+)/(weights|counters|summary)", parsed.path)
            if not match:
                raise RouteError(404, "SERVICE_NOT_REGISTERED")
            sid, action = match.groups()
            query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
            if set(query) != {"publicHost"} or len(query["publicHost"]) != 1:
                raise RouteError(400, "INVALID_REQUEST")
            host = query["publicHost"][0]
            state = SCOPED_STORE.get(sid, host)
            if self.command == "GET":
                if action == "weights":
                    return self._send(200, state)
                if action == "summary":
                    raise RouteError(501, "SERVICE_SUMMARY_UNSUPPORTED")
                counters = SCOPED_STORE.counters(sid)
                if counters is None:
                    raise RouteError(503, "ENVOY_UNREACHABLE")
                return self._send(200, {"serviceId": sid, "publicHost": host, "envs": counters})
            if SYNC_FROM:
                raise RouteError(409, "READ_ONLY_SECONDARY")
            if action != "weights":
                raise RouteError(404, "SERVICE_NOT_REGISTERED")
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 65536:
                raise RouteError(400, "INVALID_REQUEST")
            body = json.loads(self.rfile.read(size))
            if not isinstance(body, dict) or set(body) != {
                "publicHost",
                "weights",
                "expectedRevision",
            }:
                raise RouteError(400, "INVALID_REQUEST")
            if body["publicHost"] != host:
                raise RouteError(409, "SERVICE_SCOPE_MISMATCH")
            result = SCOPED_STORE.update(sid, host, body["weights"], body["expectedRevision"])
            return self._send(200, result)
        except RouteError as error:
            return self._send(error.status, {"error": error.code})
        except (ValueError, json.JSONDecodeError):
            return self._send(400, {"error": "INVALID_REQUEST"})
        except OSError:
            return self._send(503, {"error": "STATE_UNAVAILABLE"})

    def _metrics(self):
        if SERVICE_ROUTING_ENABLED:
            out = ["# TYPE entrypoint_service_weight gauge"]
            for sid, service in SCOPED_STORE.snapshot()["services"].items():
                for env, weight in service["weights"].items():
                    out.append(
                        f'entrypoint_service_weight{{service_id="{sid}",environment_id="{env}"}} {weight}'
                    )
            return "\n".join(out) + "\n"
        out = [
            "# HELP entrypoint_weight 환경별 트래픽 가중치 (0~100)",
            "# TYPE entrypoint_weight gauge",
        ]
        out += [f'entrypoint_weight{{env="{env}"}} {w}' for env, w in CURRENT.items()]
        return "\n".join(out) + "\n"


def sync_once():
    """보조 한 번 동기화. 서비스 모드는 전역 weights를 읽지 않는다."""
    path = "/v1/snapshot" if SERVICE_ROUTING_ENABLED else "/weights"
    req = urllib.request.Request(f"{SYNC_FROM}{path}", headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=2) as response:
        data = json.load(response)
    if SERVICE_ROUTING_ENABLED:
        SCOPED_STORE.sync(data)
    else:
        weights = validate_weights(data)
        with LOCK:
            if weights != CURRENT:
                apply_weights(weights)


def sync_loop():
    """보조 진입점: 주 진입점의 /weights 를 주기적으로 당겨 같은 가중치를 유지한다. 주가 죽으면 마지막 값을 유지한다."""
    reachable = None
    while True:
        try:
            sync_once()
            if reachable is not True:
                log(msg="sync source reachable", source=SYNC_FROM)
                reachable = True
        except (urllib.error.URLError, json.JSONDecodeError, ValueError, OSError) as e:
            if reachable is not False:
                log(
                    msg="sync source unreachable, keeping last weights",
                    source=SYNC_FROM,
                    error=str(e),
                )
                reachable = False
        time.sleep(SYNC_INTERVAL)


class RouteError(ValueError):
    def __init__(self, status, code):
        super().__init__(code)
        self.status, self.code = status, code


def canonical_uuid(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value:
        raise ValueError("canonical UUID required")
    return value


def valid_dns(value):
    return (
        isinstance(value, str)
        and len(value) <= 253
        and all(
            re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
            for label in value.split(".")
        )
    )


def service_weights(weights, environments):
    if not isinstance(weights, dict) or set(weights) != set(environments):
        raise RouteError(400, "INVALID_WEIGHTS")
    if (
        any(type(v) is not int or not 0 <= v <= 100 for v in weights.values())
        or sum(weights.values()) != 100
    ):
        raise RouteError(400, "INVALID_WEIGHTS")
    return dict(weights)


def cluster_id(sid, eid):
    return "svc_" + uuid.UUID(sid).hex + "_" + uuid.UUID(eid).hex


class ServiceRouteStore:
    """검증된 등록표 + 서비스 단위 CAS. 외부 등록 API는 의도적으로 없다."""

    def __init__(self, directory, registry_path):
        self.root = Path(directory)
        self.state_dir = self.root / "state"
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.paths = [self.state_dir / "services.json", self.state_dir / "services.backup.json"]
        self.lock = threading.RLock()
        self.registry = {}
        hosts = set()
        with open(registry_path, encoding="utf-8") as stream:
            entries = json.load(stream)
        if (
            not isinstance(entries, dict)
            or set(entries) != {"services"}
            or not isinstance(entries["services"], list)
            or not entries["services"]
        ):
            raise ValueError("invalid registry")
        for entry in entries["services"]:
            if not isinstance(entry, dict) or set(entry) != {
                "serviceId",
                "publicHost",
                "environments",
                "initialWeights",
            }:
                raise ValueError("invalid service registration")
            sid = canonical_uuid(entry["serviceId"])
            host, environments = entry["publicHost"], entry["environments"]
            if not valid_dns(host) or "." not in host or host in hosts or sid in self.registry:
                raise ValueError("invalid or duplicate service/host")
            if not isinstance(environments, dict) or not environments:
                raise ValueError("environments required")
            origins = set()
            for eid, origin in environments.items():
                canonical_uuid(eid)
                if not isinstance(origin, dict) or set(origin) != {"host", "port"}:
                    raise ValueError("HTTP origin host/port required")
                if (
                    not valid_dns(origin["host"])
                    or origin["host"] == host
                    or type(origin["port"]) is not int
                    or not 1 <= origin["port"] <= 65535
                ):
                    raise ValueError("invalid origin")
                key = (origin["host"], origin["port"])
                if key in origins:
                    raise ValueError("duplicate origin in service")
                origins.add(key)
            service_weights(entry["initialWeights"], environments)
            hosts.add(host)
            self.registry[sid] = entry
        if any(
            o["host"] in hosts
            for entry in self.registry.values()
            for o in entry["environments"].values()
        ):
            raise ValueError("origin must not point at a public route")
        self.registry_hash = hashlib.sha256(
            json.dumps(self.registry, sort_keys=True).encode()
        ).hexdigest()

    def initial(self):
        return {
            "schemaVersion": 1,
            "registryHash": self.registry_hash,
            "generation": 0,
            "services": {
                sid: {
                    "serviceId": sid,
                    "publicHost": entry["publicHost"],
                    "revision": 0,
                    "weights": entry["initialWeights"],
                }
                for sid, entry in self.registry.items()
            },
        }

    def validate_snapshot(self, data):
        if not isinstance(data, dict) or set(data) != {
            "schemaVersion",
            "registryHash",
            "generation",
            "services",
        }:
            raise ValueError("invalid snapshot")
        if data["schemaVersion"] != 1 or data["registryHash"] != self.registry_hash:
            raise ValueError("registry mismatch: explicit migration required")
        if (
            type(data["generation"]) is not int
            or data["generation"] < 0
            or not isinstance(data["services"], dict)
            or set(data["services"]) != set(self.registry)
        ):
            raise ValueError("incomplete snapshot")
        for sid, state in data["services"].items():
            if not isinstance(state, dict) or set(state) != {
                "serviceId",
                "publicHost",
                "revision",
                "weights",
            }:
                raise ValueError("invalid service state")
            if (
                state["serviceId"] != sid
                or state["publicHost"] != self.registry[sid]["publicHost"]
                or type(state["revision"]) is not int
                or state["revision"] < 0
            ):
                raise ValueError("invalid scope/revision")
            service_weights(state["weights"], self.registry[sid]["environments"])
        return copy.deepcopy(data)

    def _load(self):
        found, valid = False, []
        for path in self.paths:
            try:
                found = found or path.exists()
                with path.open(encoding="utf-8") as stream:
                    valid.append(self.validate_snapshot(json.load(stream)))
            except FileNotFoundError:
                continue
            except (ValueError, KeyError, TypeError):
                continue
        if not valid:
            if found or (self.state_dir / "services.initialized").exists():
                raise OSError("no valid service snapshot; refusing reset")
            return self.initial()
        valid.sort(key=lambda item: item["generation"], reverse=True)
        if (
            len(valid) == 2
            and valid[0]["generation"] == valid[1]["generation"]
            and valid[0] != valid[1]
        ):
            raise OSError("conflicting snapshots")
        return valid[0]

    def snapshot(self):
        with self.lock, (self.state_dir / "services.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return self._load()

    def get(self, sid, host):
        if sid not in self.registry:
            raise RouteError(404, "SERVICE_NOT_REGISTERED")
        if host != self.registry[sid]["publicHost"]:
            raise RouteError(409, "SERVICE_SCOPE_MISMATCH")
        return self.snapshot()["services"][sid]

    def routes(self, snapshot):
        hosts = []
        health = {
            "match": {"path": "/__entry/healthz"},
            "direct_response": {"status": 200, "body": {"inline_string": "ok\n"}},
        }
        for sid, state in snapshot["services"].items():
            hosts.append(
                {
                    "name": "service_" + uuid.UUID(sid).hex,
                    "domains": [state["publicHost"]],
                    "routes": [
                        health,
                        {
                            "match": {"prefix": "/"},
                            "route": {
                                "timeout": "30s",
                                "weighted_clusters": {
                                    "clusters": [
                                        {"name": cluster_id(sid, eid), "weight": weight}
                                        for eid, weight in state["weights"].items()
                                    ]
                                },
                            },
                        },
                    ],
                }
            )
        hosts.append(
            {
                "name": "unknown_host",
                "domains": ["*"],
                "routes": [health, {"match": {"prefix": "/"}, "direct_response": {"status": 404}}],
            }
        )
        return {
            "version_info": str(snapshot["generation"]),
            "resources": [
                {
                    "@type": "type.googleapis.com/envoy.config.route.v3.RouteConfiguration",
                    "name": "echo_routes",
                    "virtual_hosts": hosts,
                }
            ],
        }

    def clusters(self):
        clusters = []
        for sid, entry in self.registry.items():
            for eid, origin in entry["environments"].items():
                name = cluster_id(sid, eid)
                clusters.append(
                    {
                        "@type": "type.googleapis.com/envoy.config.cluster.v3.Cluster",
                        "name": name,
                        "type": "STRICT_DNS",
                        "dns_lookup_family": "V4_ONLY",
                        "connect_timeout": "2s",
                        "lb_policy": "ROUND_ROBIN",
                        "common_lb_config": {"healthy_panic_threshold": {"value": 0}},
                        "load_assignment": {
                            "cluster_name": name,
                            "endpoints": [
                                {
                                    "lb_endpoints": [
                                        {
                                            "endpoint": {
                                                "address": {
                                                    "socket_address": {
                                                        "address": origin["host"],
                                                        "port_value": origin["port"],
                                                    }
                                                }
                                            }
                                        }
                                    ]
                                }
                            ],
                        },
                        "health_checks": [
                            {
                                "timeout": "1s",
                                "interval": "2s",
                                "unhealthy_threshold": 2,
                                "healthy_threshold": 1,
                                "http_health_check": {"path": HC_PATH, "host": entry["publicHost"]},
                            }
                        ],
                        "outlier_detection": {
                            "consecutive_5xx": 3,
                            "interval": "2s",
                            "base_ejection_time": "10s",
                            "max_ejection_percent": 100,
                        },
                    }
                )
        return {"version_info": self.registry_hash, "resources": clusters}

    def _save(self, data):
        text = json.dumps(data, sort_keys=True)
        # 두 사본은 최신 전체 서비스 snapshot이다. 어느 사본이 끊겨도 나머지로 복구한다.
        write_atomic(str(self.paths[1]), text)
        write_atomic(str(self.paths[0]), text)
        write_atomic(str(self.state_dir / "services.initialized"), self.registry_hash)
        write_atomic(str(self.root / "routes.yaml"), json.dumps(self.routes(data)))

    def seed(self):
        with self.lock, (self.state_dir / "services.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            data = self._load()
            write_atomic(str(self.root / "clusters.yaml"), json.dumps(self.clusters()))
            self._save(data)

    def update(self, sid, host, weights, revision):
        self.get(sid, host)
        weights = service_weights(weights, self.registry[sid]["environments"])
        with self.lock, (self.state_dir / "services.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            data = self._load()
            state = data["services"][sid]
            if type(revision) is not int or revision != state["revision"]:
                raise RouteError(409, "REVISION_CONFLICT")
            state["weights"] = weights
            state["revision"] += 1
            data["generation"] += 1
            self._save(data)
            return copy.deepcopy(state)

    def sync(self, snapshot):
        snapshot = self.validate_snapshot(snapshot)
        with self.lock, (self.state_dir / "services.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            current = self._load()
            if snapshot["generation"] < current["generation"] or (
                snapshot["generation"] == current["generation"] and snapshot != current
            ):
                raise ValueError("stale/conflicting snapshot")
            for sid, state in current["services"].items():
                other = snapshot["services"][sid]
                if other["revision"] < state["revision"] or (
                    other["revision"] == state["revision"] and other != state
                ):
                    raise ValueError("stale/conflicting service")
            self._save(snapshot)

    def counters(self, sid):
        try:
            with urllib.request.urlopen(
                f"{ENVOY_ADMIN}/clusters?format=json", timeout=3
            ) as response:
                data = json.load(response)
        except (urllib.error.URLError, OSError, ValueError):
            return None
        clusters = {
            entry["name"]: entry.get("host_statuses", [])
            for entry in data.get("cluster_statuses", [])
        }
        result = {}
        for eid in self.registry[sid]["environments"]:
            hosts = clusters.get(cluster_id(sid, eid), [])
            counters = {"requests": 0, "errors_5xx": 0, "hosts": len(hosts)}
            for host in hosts:
                stats = {stat["name"]: int(stat.get("value", 0)) for stat in host.get("stats", [])}
                counters["requests"] += stats.get("rq_total", 0)
                counters["errors_5xx"] += stats.get("rq_error", 0)
            result[eid] = counters
        return result


def main():
    seed()
    if SYNC_FROM:
        threading.Thread(target=sync_loop, daemon=True, name="weights-sync").start()
        log(msg="secondary entry: syncing weights", source=SYNC_FROM, interval_s=SYNC_INTERVAL)
    srv = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    log(msg="listening", port=LISTEN_PORT, envs=ENVS, token_set=bool(TOKEN))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
