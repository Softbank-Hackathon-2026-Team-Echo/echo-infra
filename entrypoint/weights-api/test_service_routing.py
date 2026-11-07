"""로컬 HTTP + 실제 xDS 파일: 외부 API/클라우드 호출 없음."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

os.environ.setdefault("UPSTREAMS", "aws=127.0.0.1:18001,gcp=127.0.0.1:18002")
A = "00000000-0000-0000-0000-000000000001"
B = "00000000-0000-0000-0000-000000000002"
AWS = "10000000-0000-0000-0000-000000000001"
GCP = "10000000-0000-0000-0000-000000000002"


def registration():
    return {
        "services": [
            {
                "serviceId": sid,
                "publicHost": host,
                "environments": {
                    AWS: {"host": "127.0.0.1", "port": 18001},
                    GCP: {"host": "127.0.0.1", "port": 18002},
                },
                "initialWeights": {AWS: aws, GCP: 100 - aws},
            }
            for sid, host, aws in [(A, "a.echo.test", 0), (B, "b.echo.test", 100)]
        ]
    }


def load_app():
    spec = importlib.util.spec_from_file_location("weights_app", Path(__file__).with_name("app.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ServiceRoutingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(
            prefix="echo-service-route-", dir=os.environ.get("TMPDIR")
        )
        self.root = Path(self.tmp.name)
        self.app = load_app()
        self.app.DYNAMIC_DIR = str(self.root)
        self.app.STATE_DIR = str(self.root / "state")
        self.app.STATE_PATH = str(self.root / "state/weights.json")
        self.app.TOKEN = "local-test-only"
        self.app.SERVICE_ROUTING_ENABLED = True
        self.app.SERVICE_ROUTES_FILE = str(self.root / "registration.json")
        Path(self.app.SERVICE_ROUTES_FILE).write_text(json.dumps(registration()))
        self.app.seed()
        self.server = self.app.ThreadingHTTPServer(("127.0.0.1", 0), self.app.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def request(self, sid=A, host="a.echo.test", body=None, token=True, path=None):
        url = f"http://127.0.0.1:{self.server.server_port}" + (
            path or f"/v1/services/{sid}/weights?publicHost={host}"
        )
        headers = {"Content-Type": "application/json", "Host": "b.echo.test"}
        if token:
            headers["Authorization"] = "Bearer local-test-only"
        req = urllib.request.Request(
            url, data=json.dumps(body).encode() if body is not None else None, headers=headers
        )
        if body is not None:
            req.method = "PUT"
        try:
            with urllib.request.urlopen(req, timeout=3) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def test_two_service_http_weights_generate_distinct_routes(self):
        code, a = self.request()
        self.assertEqual(code, 200, a)
        self.assertEqual(a["weights"], {AWS: 0, GCP: 100})
        _, b = self.request(B, "b.echo.test")
        for index, aws in enumerate((10, 50, 100)):
            code, changed = self.request(
                body={
                    "publicHost": "a.echo.test",
                    "expectedRevision": index,
                    "weights": {AWS: aws, GCP: 100 - aws},
                }
            )
            self.assertEqual(code, 200, changed)
            self.assertEqual(self.request(B, "b.echo.test")[1], b)
        routes = json.loads((self.root / "routes.yaml").read_text())
        hosts = routes["resources"][0]["virtual_hosts"]
        self.assertEqual([v["domains"] for v in hosts], [["a.echo.test"], ["b.echo.test"], ["*"]])
        self.assertEqual(hosts[-1]["routes"][-1]["direct_response"]["status"], 404)
        self.assertNotEqual(
            hosts[0]["routes"][-1]["route"]["weighted_clusters"],
            hosts[1]["routes"][-1]["route"]["weighted_clusters"],
        )

    def test_service_counters_only_use_that_services_clusters(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        app = self.app
        payload = {
            "cluster_statuses": [
                {
                    "name": app.cluster_id(sid, eid),
                    "host_statuses": [
                        {
                            "stats": [
                                {"name": "rq_total", "value": count},
                                {"name": "rq_error", "value": 1},
                            ]
                        }
                    ],
                }
                for sid, count in ((A, 7), (B, 900))
                for eid in (AWS, GCP)
            ]
        }

        class Admin(BaseHTTPRequestHandler):
            def do_GET(self):
                raw = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def log_message(self, *args):
                pass

        admin = ThreadingHTTPServer(("127.0.0.1", 0), Admin)
        thread = threading.Thread(target=admin.serve_forever, daemon=True)
        thread.start()
        app.ENVOY_ADMIN = f"http://127.0.0.1:{admin.server_port}"
        try:
            code, result = self.request(path=f"/v1/services/{A}/counters?publicHost=a.echo.test")
            self.assertEqual(code, 200)
            self.assertEqual(result["envs"][AWS], {"requests": 7, "errors_5xx": 1, "hosts": 1})
            self.assertEqual(
                self.request(path=f"/v1/services/{A}/summary?publicHost=a.echo.test")[0], 501
            )
        finally:
            admin.shutdown()
            admin.server_close()
            thread.join()

    def test_legacy_default_keeps_existing_api_and_health(self):
        self.app.SERVICE_ROUTING_ENABLED = False
        self.app.seed()
        self.assertEqual(self.request(path="/weights")[1], {"aws": 100, "gcp": 0})
        self.assertEqual(self.request(path="/weights", body={"aws": 0, "gcp": 100})[0], 200)
        self.assertEqual(self.request(path="/health")[0], 200)
        self.assertEqual(self.request()[0], 404)

    def test_service_mode_boots_without_legacy_upstreams(self):
        from unittest.mock import patch

        with patch.dict(os.environ, {"SERVICE_ROUTING_ENABLED": "1", "UPSTREAMS": ""}):
            app = load_app()
        with patch.dict(os.environ, {"SERVICE_ROUTING_ENABLED": "true"}):
            with self.assertRaises(ValueError):
                load_app()
        self.assertEqual(app.UPSTREAMS, {})

    def test_atomic_replace_fsyncs_parent_directory(self):
        from unittest.mock import patch

        original = self.app.os.fsync
        with patch.object(self.app.os, "fsync", wraps=original) as fsync:
            self.app.write_atomic(str(self.root / "durable.json"), "{}")
        self.assertEqual(fsync.call_count, 2)

    def test_empty_registry_and_lost_snapshots_fail_closed(self):
        path = self.root / "empty.json"
        path.write_text('{"services": []}')
        with self.assertRaises(ValueError):
            self.app.ServiceRouteStore(str(self.root / "empty"), str(path))
        for path in self.app.SCOPED_STORE.paths:
            path.unlink()
        with self.assertRaises(OSError):
            self.app.seed()

    def test_sync_once_uses_scoped_snapshot_over_local_http(self):
        self.request(
            body={"publicHost": "a.echo.test", "expectedRevision": 0, "weights": {AWS: 50, GCP: 50}}
        )
        primary = self.app.SCOPED_STORE
        secondary = self.app.ServiceRouteStore(
            str(self.root / "secondary"), self.app.SERVICE_ROUTES_FILE
        )
        secondary.seed()
        self.app.SCOPED_STORE = secondary
        self.app.SYNC_FROM = f"http://127.0.0.1:{self.server.server_port}"
        # 이 서버는 주 snapshot을 응답하고 보조 저장소만 갱신한다.
        original = secondary.snapshot
        secondary.snapshot = primary.snapshot
        try:
            self.app.sync_once()
        finally:
            secondary.snapshot = original
        self.assertEqual(secondary.snapshot(), primary.snapshot())
        self.assertEqual(
            self.request(
                body={
                    "publicHost": "a.echo.test",
                    "expectedRevision": 1,
                    "weights": {AWS: 100, GCP: 0},
                }
            )[0],
            409,
        )

    def test_scope_auth_unknown_environment_and_stale_write_rejected(self):
        before = self.app.SCOPED_STORE.snapshot()
        for host in ("b.echo.test", "unknown.echo.test", "a.echo.test:80", "A.echo.test"):
            self.assertEqual(self.request(host=host)[0], 409)
        self.assertEqual(self.request(sid=AWS)[0], 404)
        self.assertEqual(self.request(token=False)[0], 401)
        self.assertEqual(self.request(path="/weights", body={AWS: 100, GCP: 0})[0], 409)
        for weights in ({AWS: 100}, {AWS: True, GCP: 99}, {AWS: 20, GCP: 20}, {AWS: 0, B: 100}):
            self.assertEqual(
                self.request(
                    body={"publicHost": "a.echo.test", "expectedRevision": 0, "weights": weights}
                )[0],
                400,
            )
        self.assertEqual(
            self.request(
                body={
                    "publicHost": "b.echo.test",
                    "expectedRevision": 0,
                    "weights": {AWS: 100, GCP: 0},
                }
            )[0],
            409,
        )
        self.assertEqual(
            self.request(
                body={
                    "publicHost": "a.echo.test",
                    "expectedRevision": 8,
                    "weights": {AWS: 100, GCP: 0},
                }
            )[0],
            409,
        )
        self.assertEqual(self.app.SCOPED_STORE.snapshot(), before)
        self.assertEqual(self.request(path="/health")[0], 200)

    def test_registry_rejects_duplicates_invalid_uuid_and_origin(self):
        import copy

        invalid = []
        for field in ("serviceId", "publicHost"):
            data = registration()
            data["services"][1][field] = data["services"][0][field]
            invalid.append(data)
        data = registration()
        data["services"][0]["environments"][GCP] = dict(data["services"][0]["environments"][AWS])
        invalid.append(data)
        for field, value in (
            ("publicHost", "*.echo.test"),
            ("publicHost", "https://a.echo.test"),
            ("serviceId", "not-a-uuid"),
        ):
            data = registration()
            data["services"][0][field] = value
            invalid.append(data)
        data = registration()
        data["services"][0]["environments"][GCP]["host"] = "b.echo.test"
        invalid.append(data)
        for data in invalid:
            path = self.root / "bad-registry.json"
            path.write_text(json.dumps(copy.deepcopy(data)))
            with self.assertRaises(ValueError):
                self.app.ServiceRouteStore(str(self.root / "rejected"), str(path))

    def test_parallel_stores_no_lost_other_service_and_same_scope_cas(self):
        from concurrent.futures import ThreadPoolExecutor

        first = self.app.SCOPED_STORE
        second = self.app.ServiceRouteStore(str(self.root), self.app.SERVICE_ROUTES_FILE)
        barrier = threading.Barrier(2)

        def update(store, sid, host, weights):
            barrier.wait()
            return store.update(sid, host, weights, 0)

        with ThreadPoolExecutor(2) as pool:
            a = pool.submit(update, first, A, "a.echo.test", {AWS: 50, GCP: 50})
            b = pool.submit(update, second, B, "b.echo.test", {AWS: 10, GCP: 90})
            a.result()
            b.result()
        state = first.snapshot()
        self.assertEqual(state["generation"], 2)
        self.assertEqual(state["services"][A]["weights"], {AWS: 50, GCP: 50})
        self.assertEqual(state["services"][B]["weights"], {AWS: 10, GCP: 90})
        with self.assertRaises(self.app.RouteError):
            second.update(A, "a.echo.test", {AWS: 100, GCP: 0}, 0)

    def test_restart_corrupt_primary_restores_all_from_backup(self):
        store = self.app.SCOPED_STORE
        store.update(A, "a.echo.test", {AWS: 50, GCP: 50}, 0)
        before = store.snapshot()
        store.paths[0].write_text("broken")
        (self.root / "routes.yaml").write_text("broken")
        self.app.seed()
        self.assertEqual(self.app.SCOPED_STORE.snapshot(), before)
        self.assertEqual(json.loads((self.root / "routes.yaml").read_text()), store.routes(before))
        for path in store.paths:
            path.write_text("broken")
        with self.assertRaises(OSError):
            self.app.seed()

    def test_incomplete_or_foreign_registry_sync_preserves_both_services(self):
        store = self.app.SCOPED_STORE
        before = store.snapshot()
        for field in ("missing-service", "registryHash", "scope"):
            data = json.loads(json.dumps(before))
            if field == "missing-service":
                del data["services"][B]
            elif field == "scope":
                data["services"][A]["publicHost"] = "b.echo.test"
            else:
                data["registryHash"] = "wrong"
            with self.assertRaises(ValueError):
                store.sync(data)
            self.assertEqual(store.snapshot(), before)

    def test_file_failure_never_deletes_other_service_routes(self):
        from unittest.mock import patch

        before_b = self.app.SCOPED_STORE.get(B, "b.echo.test")
        original = self.app.write_atomic

        def fail_primary(path, text):
            if path == str(self.app.SCOPED_STORE.paths[0]):
                raise OSError("injected disk failure")
            original(path, text)

        with patch.object(self.app, "write_atomic", fail_primary):
            self.assertEqual(
                self.request(
                    body={
                        "publicHost": "a.echo.test",
                        "expectedRevision": 0,
                        "weights": {AWS: 50, GCP: 50},
                    }
                )[0],
                503,
            )
        self.app.seed()
        self.assertEqual(self.app.SCOPED_STORE.get(B, "b.echo.test"), before_b)

    def test_tls_origin_sets_sni_host_rewrite_and_health_host(self):
        data = registration()
        data["services"][0]["environments"][GCP] = {"host": "tunnel-x.echo.test", "port": 443, "tls": True}
        path = self.root / "tls-registry.json"
        path.write_text(json.dumps(data))
        store = self.app.ServiceRouteStore(str(self.root / "tls"), str(path))
        store.seed()
        clusters = {c["name"]: c for c in json.loads((self.root / "tls/clusters.yaml").read_text())["resources"]}
        tls = clusters[self.app.cluster_id(A, GCP)]
        ctx = tls["transport_socket"]["typed_config"]
        self.assertEqual(ctx["sni"], "tunnel-x.echo.test")
        self.assertEqual(tls["health_checks"][0]["http_health_check"]["host"], "tunnel-x.echo.test")
        plain = clusters[self.app.cluster_id(A, AWS)]
        self.assertNotIn("transport_socket", plain)
        self.assertEqual(plain["health_checks"][0]["http_health_check"]["host"], "a.echo.test")
        self.assertEqual(plain["health_checks"][0]["no_traffic_interval"], "2s")
        routes = json.loads((self.root / "tls/routes.yaml").read_text())["resources"][0]["virtual_hosts"]
        weighted = {c["name"]: c for c in routes[0]["routes"][-1]["route"]["weighted_clusters"]["clusters"]}
        self.assertEqual(weighted[self.app.cluster_id(A, GCP)]["host_rewrite_literal"], "tunnel-x.echo.test")
        self.assertNotIn("host_rewrite_literal", weighted[self.app.cluster_id(A, AWS)])
        self.assertIn("retry_policy", routes[0]["routes"][-1]["route"])
        for bad in ({"host": "tunnel-x.echo.test", "port": 443, "tls": "yes"},
                    {"host": "tunnel-x.echo.test", "port": 443, "tls": False},
                    {"host": "localhost", "port": 443, "tls": True},
                    {"host": "tunnel-x.echo.test", "port": 443, "sni": "x"}):
            data["services"][0]["environments"][GCP] = bad
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                self.app.ServiceRouteStore(str(self.root / "tls-bad"), str(path))


if __name__ == "__main__":
    unittest.main()
