"""격리 소켓 + 제품 RDS 제어면 시험. Envoy data plane 시험이 아니다."""

import copy
import http.client
import importlib.util
import json
import os
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SIDS = [f"00000000-0000-0000-0000-0000000000{i:02d}" for i in (11, 12, 13)]
EIDS = [f"10000000-0000-0000-0000-00000000000{i}" for i in (1, 2)]
HOSTS = ["a.echo.test", "b.echo.test", "tenant-c.echo.test"]


class Origin:
    def __init__(self, name, port=0):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        self.name, self.mode, self.calls = name, "ok", []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                owner.calls.append(
                    (
                        time.monotonic(),
                        self.command,
                        self.path,
                        self.headers.get("Idempotency-Key"),
                    )
                )
                if owner.mode == "reset":
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                if owner.mode in ("blackhole", "delay"):
                    time.sleep(0.7 if owner.mode == "delay" else 1.0)
                    return
                raw = owner.name.encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            do_HEAD = do_GET
            do_POST = do_GET

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def request(
    port, method="GET", path="/status", timeout=0.15, idempotency_key="fixture-key"
):
    start = time.monotonic()
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        headers = {"Host": HOSTS[0]}
        if method == "POST" and idempotency_key:
            headers["Idempotency-Key"] = idempotency_key
        conn.request(method, path, headers=headers)
        response = conn.getresponse()
        body = response.read().decode()
        return response.status, body, time.monotonic() - start
    except (OSError, http.client.HTTPException):
        return (
            503,
            "UNKNOWN" if method == "POST" else "transport-error",
            time.monotonic() - start,
        )
    finally:
        conn.close()


class NetworkResilienceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="echo-net-", dir=os.environ.get("TMPDIR")
        )
        self.root = Path(self.temp.name)
        self.origins = [Origin("origin-a"), Origin("origin-b")]
        self.service_origins = [self.origins] + [
            [Origin(f"service-{i}-a"), Origin(f"service-{i}-b")] for i in (1, 2)
        ]
        spec = importlib.util.spec_from_file_location(
            "network_weights", Path(__file__).with_name("app.py")
        )
        self.app = importlib.util.module_from_spec(spec)
        with patch.dict(
            os.environ,
            {
                "SERVICE_ROUTING_ENABLED": "1",
                "READ_FAILOVER_ENABLED": "1",
                "UPSTREAMS": "",
            },
        ):
            spec.loader.exec_module(self.app)
        self.app.READ_FAILOVER_POLICIES_FILE = str(self.root / "policy.json")
        self.app.SERVICE_ROUTES_FILE = str(self.root / "registry.json")
        self.app.DYNAMIC_DIR = str(self.root / "dynamic")
        self.app.STATE_DIR = str(self.root / "dynamic/state")
        self.app.STATE_PATH = str(self.root / "dynamic/state/weights.json")
        self.registry = {
            "services": [
                {
                    "serviceId": sid,
                    "publicHost": host,
                    "environments": {
                        eid: {"host": "127.0.0.1", "port": origin.port}
                        for eid, origin in zip(EIDS, self.service_origins[index])
                    },
                    "initialWeights": {EIDS[0]: 100, EIDS[1]: 0},
                }
                for index, (sid, host) in enumerate(zip(SIDS, HOSTS))
            ]
        }
        self.policy = {
            "services": [
                {
                    "serviceId": SIDS[0],
                    "publicHost": HOSTS[0],
                    "statelessOnly": True,
                    "safePaths": ["/status"],
                    "eligibleEnvironmentIds": EIDS,
                }
            ]
        }
        (self.root / "registry.json").write_text(json.dumps(self.registry))
        (self.root / "policy.json").write_text(json.dumps(self.policy))
        self.app.seed()
        self.store = self.app.SCOPED_STORE
        self.before = self.store.snapshot()
        self.now = 0.0

    def tearDown(self):
        for origins in self.service_origins:
            for origin in origins:
                origin.close()
        self.temp.cleanup()

    def sample(self, times=1):
        for _ in range(times):
            statuses = []
            for index, sid in enumerate(SIDS):
                for eid, origin in zip(EIDS, self.service_origins[index]):
                    ok = request(origin.port, path="/healthz")[0] == 200
                    statuses.append(
                        {
                            "name": self.app.cluster_id(sid, eid),
                            "host_statuses": [
                                {
                                    "health_status": {
                                        "eds_health_status": "HEALTHY",
                                        "failed_active_health_check": not ok,
                                    }
                                }
                            ],
                        }
                    )
            # Direct source-to-generator seam; a fixture health adapter, not native Envoy.
            observe = getattr(self.store, "observe_read_health", None)
            if observe:
                observe({"cluster_statuses": statuses}, self.now)
            self.now += 0.5

    def route(
        self,
        sid=0,
        method="GET",
        path="/status",
        idempotency_key="fixture-key",
        timeout=0.15,
    ):
        # A narrow RDS fixture interpreter, explicitly NOT Envoy validation/emulation.
        config = json.loads((Path(self.app.DYNAMIC_DIR) / "routes.yaml").read_text())
        host = config["resources"][0]["virtual_hosts"][sid]
        for route in host["routes"]:
            match = route["match"]
            if "path" in match and match["path"] != path:
                continue
            headers = match.get("headers", [])
            if headers and headers[0].get("string_match", {}).get("exact") != method:
                continue
            if "direct_response" in route:
                return route["direct_response"]["status"], "direct", 0.0
            action = route["route"]
            name = action.get("cluster")
            if name is None:
                name = next(
                    c["name"]
                    for c in action["weighted_clusters"]["clusters"]
                    if c["weight"] == 100
                )
            index = [self.app.cluster_id(SIDS[sid], e) for e in EIDS].index(name)
            return request(
                self.service_origins[sid][index].port,
                method,
                path,
                timeout=timeout,
                idempotency_key=idempotency_key,
            )
        raise AssertionError("no route")

    def test_post_response_loss_is_unknown_and_never_replayed_to_backup(self):
        self.sample(6)
        self.origins[0].mode = "reset"
        count = len(self.origins[0].calls)
        backup_count = len(self.origins[1].calls)
        result = self.route(method="POST")
        self.assertEqual(result[:2], (503, "UNKNOWN"))
        self.assertEqual(len(self.origins[0].calls) - count, 1)
        self.assertEqual(len(self.origins[1].calls), backup_count)
        self.sample(2)
        count = sum(len(o.calls) for o in self.origins)
        self.assertEqual(self.route(method="POST")[0], 503)
        self.assertEqual(
            sum(len(o.calls) for o in self.origins),
            count,
            "writer-unsafe means no dispatch",
        )
        self.assertEqual(
            self.route(path="/private-data")[0], 503, "private reads must not move to B"
        )

    def test_all_origins_dead_and_stable_reconnect_keeps_new_primary(self):
        self.sample(6)
        self.origins[0].mode = "blackhole"
        self.sample(2)
        self.assertEqual(self.route()[:2], (200, "origin-b"))
        self.origins[1].mode = "reset"
        self.sample(2)
        self.assertEqual(self.route()[0], 503)
        self.origins[0].mode = "ok"
        self.sample(6)
        self.assertEqual(
            self.route()[0], 503, "quarantined old primary cannot return automatically"
        )
        self.origins[1].mode = "ok"
        self.sample(2)
        self.assertEqual(self.route()[0], 503, "recovery must pass stability interval")
        self.sample(4)
        self.assertEqual(self.route()[:2], (200, "origin-b"))
        self.assertEqual(self.route(sid=1)[:2], (200, "service-1-a"))
        self.assertEqual(self.route(sid=2)[:2], (200, "service-2-a"))

    def test_restart_rechecks_health_but_never_resets_quarantine_or_write_gate(self):
        self.sample(6)
        self.origins[0].mode = "reset"
        self.sample(2)
        self.origins[0].mode = "ok"
        store = self.app.ServiceRouteStore(
            self.app.DYNAMIC_DIR, self.app.SERVICE_ROUTES_FILE
        )
        store.seed()
        self.store = store
        self.app.SCOPED_STORE = store
        self.assertEqual(self.route()[0], 503, "restart does not reuse stale health")
        self.sample(6)
        self.assertEqual(self.route()[:2], (200, "origin-b"))
        self.assertEqual(self.route(method="POST")[0], 503)
        before = (Path(self.app.DYNAMIC_DIR) / "routes.yaml").read_bytes()
        store.read_state_path.write_text("null")
        with self.assertRaises((OSError, ValueError)):
            self.app.ServiceRouteStore(
                self.app.DYNAMIC_DIR, self.app.SERVICE_ROUTES_FILE
            )
        self.assertEqual(
            (Path(self.app.DYNAMIC_DIR) / "routes.yaml").read_bytes(), before
        )

    def test_control_weights_change_cannot_unlock_writer_or_override_sticky_reads(self):
        self.sample(6)
        self.origins[0].mode = "reset"
        self.sample(2)
        self.store.update(SIDS[0], HOSTS[0], {EIDS[0]: 0, EIDS[1]: 100}, 0)
        self.assertEqual(self.route()[:2], (200, "origin-b"))
        self.assertEqual(self.route(method="POST")[0], 503)
        self.assertEqual(
            self.store.get(SIDS[1], HOSTS[1]), self.before["services"][SIDS[1]]
        )

    def test_invalid_policy_never_silently_enables_fallback(self):
        cases = [
            ("publicHost", HOSTS[1]),
            ("statelessOnly", False),
            ("safePaths", ["/"]),
            ("safePaths", ["/*"]),
            ("safePaths", ["/status?x=1"]),
            ("safePaths", ["/status", "/status"]),
            ("eligibleEnvironmentIds", [EIDS[0]]),
            ("eligibleEnvironmentIds", [EIDS[0], SIDS[1]]),
        ]
        for key, value in cases:
            bad = copy.deepcopy(self.policy)
            bad["services"][0][key] = value
            (self.root / "policy.json").write_text(json.dumps(bad))
            with self.assertRaises((ValueError, OSError)):
                self.app.ServiceRouteStore(
                    self.app.DYNAMIC_DIR, self.app.SERVICE_ROUTES_FILE
                )
        (self.root / "policy.json").write_text(json.dumps(self.policy))
        self.assertEqual(self.store.snapshot(), self.before)

    def test_flag_defaults_off_and_bad_flag_fails_start(self):
        path = Path(__file__).with_name("app.py")
        with patch.dict(os.environ, {"SERVICE_ROUTING_ENABLED": "1", "UPSTREAMS": ""}):
            os.environ.pop("READ_FAILOVER_ENABLED", None)
            spec = importlib.util.spec_from_file_location("off_weights", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            self.assertFalse(module.READ_FAILOVER_ENABLED)
        with patch.dict(
            os.environ,
            {
                "SERVICE_ROUTING_ENABLED": "1",
                "READ_FAILOVER_ENABLED": "true",
                "UPSTREAMS": "",
            },
        ):
            spec = importlib.util.spec_from_file_location("bad_weights", path)
            with self.assertRaises(ValueError):
                spec.loader.exec_module(importlib.util.module_from_spec(spec))

    def test_gapped_health_samples_do_not_qualify_stability(self):
        self.sample(2)
        self.now += 20.0
        self.sample(1)
        self.assertEqual(
            self.route()[0],
            503,
            "two seconds without observations is not proven stability",
        )
        self.sample(5)
        self.assertEqual(self.route()[:2], (200, "origin-a"))

    def test_boot_health_warmup_does_not_permanently_block_healthy_primary(self):
        self.origins[0].mode = "reset"
        self.sample(2)
        self.origins[0].mode = "ok"
        self.sample(6)
        self.assertEqual(self.route(method="POST")[:2], (200, "origin-a"))

    def test_monitor_runs_bounded_poll_and_stops(self):
        # Real loopback connection refusal, not an origin/DB failure inference.
        closed = socket.socket()
        closed.bind(("127.0.0.1", 0))
        port = closed.getsockname()[1]
        closed.close()
        self.app.ENVOY_ADMIN = f"http://127.0.0.1:{port}"
        stop = threading.Event()
        calls = []
        original = self.store.poll_read_health

        def poll():
            calls.append(time.monotonic())
            return original()

        self.store.poll_read_health = poll
        worker = threading.Thread(target=self.app.read_failover_loop, args=(stop,))
        worker.start()
        time.sleep(0.65)
        stop.set()
        worker.join(timeout=2)
        self.assertFalse(worker.is_alive())
        self.assertGreaterEqual(len(calls), 1)
        self.assertLessEqual(len(calls), 2, "poll failure must not cause retry storm")

    def test_opted_service_has_bounded_deadlines_but_other_services_unchanged(self):
        self.sample(6)
        clusters = {
            c["name"]: c
            for c in json.loads(
                (Path(self.app.DYNAMIC_DIR) / "clusters.yaml").read_text()
            )["resources"]
        }
        for eid in EIDS:
            a = clusters[self.app.cluster_id(SIDS[0], eid)]
            self.assertEqual(a["connect_timeout"], "0.25s")
            self.assertEqual(a["health_checks"][0]["timeout"], "0.25s")
            self.assertEqual(a["health_checks"][0]["interval"], "0.5s")
            self.assertEqual(a["health_checks"][0]["healthy_threshold"], 3)
            self.assertEqual(
                clusters[self.app.cluster_id(SIDS[1], eid)]["connect_timeout"], "2s"
            )
        vhost = json.loads((Path(self.app.DYNAMIC_DIR) / "routes.yaml").read_text())[
            "resources"
        ][0]["virtual_hosts"][0]
        self.assertEqual(vhost["routes"][1]["route"]["timeout"], "1.5s")
        self.assertEqual(
            vhost["routes"][1]["route"]["max_stream_duration"]["max_stream_duration"],
            "1.5s",
        )
        self.assertEqual(
            vhost["routes"][-1]["route"]["max_stream_duration"]["max_stream_duration"],
            "1.5s",
        )
        self.assertEqual(vhost["routes"][1]["route"]["retry_policy"]["num_retries"], 1)
        self.assertEqual(vhost["routes"][-1]["route"]["retry_policy"]["num_retries"], 0)
        self.assertIn(
            "x-envoy-retry-on", vhost["routes"][-1]["request_headers_to_remove"]
        )

    def test_admin_http_unreachable_preserves_last_good_files(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        self.sample(6)
        owner = self

        class Admin(BaseHTTPRequestHandler):
            def do_GET(self):
                self.assert_path = self.path
                raw = json.dumps(
                    {
                        "cluster_statuses": [
                            {
                                "name": owner.app.cluster_id(sid, eid),
                                "host_statuses": [
                                    {"health_status": {"eds_health_status": "HEALTHY"}}
                                ],
                            }
                            for sid in SIDS
                            for eid in EIDS
                        ]
                    }
                ).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def log_message(self, format, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Admin)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.app.ENVOY_ADMIN = f"http://127.0.0.1:{server.server_port}"
        try:
            with patch.object(self.app.time, "monotonic", return_value=self.now):
                self.assertTrue(self.store.poll_read_health())
            before = {
                p.name: p.read_bytes()
                for p in Path(self.app.DYNAMIC_DIR).glob("*.yaml")
            }
        finally:
            server.shutdown()
            server.server_close()
            thread.join()
        self.assertFalse(self.store.poll_read_health())
        self.assertEqual(
            {p.name: p.read_bytes() for p in Path(self.app.DYNAMIC_DIR).glob("*.yaml")},
            before,
        )
        self.assertEqual(self.route()[:2], (200, "origin-a"))

    def test_socket_reset_failover_is_service_scoped_and_sticky(self):
        self.sample(6)
        self.assertEqual(self.route()[:2], (200, "origin-a"))
        before_other = copy.deepcopy(
            json.loads((Path(self.app.DYNAMIC_DIR) / "routes.yaml").read_text())[
                "resources"
            ][0]["virtual_hosts"][1:]
        )
        self.origins[0].mode = "reset"
        self.sample(2)
        self.assertEqual(
            self.route()[:2],
            (200, "origin-b"),
            "actual reset must select qualified safe read origin B",
        )
        self.origins[0].mode = "ok"
        self.sample(8)
        self.assertEqual(
            self.route()[:2], (200, "origin-b"), "reconnect must not auto-failback"
        )
        self.assertEqual(
            self.store.snapshot(),
            self.before,
            "control weights/revisions must never be rewritten",
        )
        self.assertEqual(
            json.loads((Path(self.app.DYNAMIC_DIR) / "routes.yaml").read_text())[
                "resources"
            ][0]["virtual_hosts"][1:],
            before_other,
        )


if __name__ == "__main__":
    unittest.main()
