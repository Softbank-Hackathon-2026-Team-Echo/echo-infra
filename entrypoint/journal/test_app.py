"""요청 기록 서비스 단위 시험 (인프라 12.4). 실행: python -m unittest entrypoint/journal/test_app.py"""

import base64
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(__file__))
import app  # noqa: E402

TOKEN = "test-token"


class JournalTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        app.TOKEN = TOKEN
        app.ENABLED = True
        app.RETENTION = 900
        app.MAX_BODY = 16
        app.DB = app.open_db(os.path.join(self.tmp.name, "j.db"))
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        self.admin = ThreadingHTTPServer(("127.0.0.1", 0), app.AdminHandler)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.admin_base = f"http://127.0.0.1:{self.admin.server_port}"
        for s in (self.server, self.admin):
            threading.Thread(target=s.serve_forever, daemon=True).start()

    def tearDown(self):
        for s in (self.server, self.admin):
            s.shutdown()
            s.server_close()
        app.DB.close()
        self.tmp.cleanup()

    def call(self, method, path, body=b"", headers=None, token=False, base=None):
        h = dict(headers or {})
        if token:
            h["Authorization"] = f"Bearer {TOKEN}"
        if base is None:
            base = self.base if path.startswith("/check") else self.admin_base
        req = urllib.request.Request(base + path, data=body or None, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                raw = r.read()
                return r.status, dict(r.headers), json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            raw = e.read()
            return e.code, dict(e.headers), json.loads(raw) if raw else None

    def entries(self):
        return self.call("GET", "/entries?since=0", token=True)[2]["entries"]

    def test_write_is_recorded_with_key_and_body(self):
        code, _, _ = self.call(
            "POST", "/check/api/writes", b"{}",
            {"Host": "demo.echoport.uk", "Idempotency-Key": "k-1", "Content-Type": "application/json"},
        )
        self.assertEqual(code, 200)
        [e] = self.entries()
        self.assertEqual((e["method"], e["path"], e["host"], e["requestId"]), ("POST", "/api/writes", "demo.echoport.uk", "k-1"))
        self.assertEqual(base64.b64decode(e["body"]), b"{}")
        self.assertEqual(e["contentType"], "application/json")

    def test_x_request_id_is_fallback_key(self):
        self.call("POST", "/check/api/writes", b"{}", {"X-Request-Id": "envoy-1"})
        self.assertEqual(self.entries()[0]["requestId"], "envoy-1")

    def test_read_is_not_recorded(self):
        code, _, _ = self.call("GET", "/check/api/writes/summary")
        self.assertEqual(code, 200)
        self.assertEqual(self.entries(), [])

    def test_sensitive_headers_are_not_stored(self):
        self.call("POST", "/check/api/writes", b"{}", {"Authorization": "Bearer secret", "Cookie": "s=1"})
        raw = json.dumps(self.entries())
        self.assertNotIn("secret", raw)
        self.assertNotIn("s=1", raw)

    def test_large_body_is_truncated(self):
        self.call("POST", "/check/api/writes", b"x" * 40)
        [e] = self.entries()
        self.assertTrue(e["truncated"])
        self.assertEqual(len(base64.b64decode(e["body"])), 16)

    def test_old_entries_are_pruned(self):
        app.record(app.DB, "POST", "/old", "h", "old", None, b"", now=1000.0)
        app.record(app.DB, "POST", "/new", "h", "new", None, b"", now=1000.0 + 901)
        self.assertEqual([e["path"] for e in self.entries()], ["/new"])

    def test_entries_since_and_order(self):
        for i, t in enumerate([100.0, 200.0, 300.0]):
            app.record(app.DB, "POST", f"/w{i}", "h", f"k{i}", None, b"", now=1e9 + t)
        got = self.call("GET", f"/entries?since={1e9 + 150}", token=True)[2]["entries"]
        self.assertEqual([e["path"] for e in got], ["/w1", "/w2"])

    def test_hold_returns_429_for_writes_only(self):
        self.assertEqual(self.call("POST", "/hold", token=True)[0], 200)
        code, headers, body = self.call("POST", "/check/api/writes", b"{}")
        self.assertEqual((code, body["error"], headers.get("Retry-After")), (429, "WRITES_ON_HOLD", "2"))
        self.assertEqual(self.call("GET", "/check/api/writes/summary")[0], 200)
        self.assertEqual(self.entries(), [])
        self.assertEqual(self.call("POST", "/release", token=True)[0], 200)
        self.assertEqual(self.call("POST", "/check/api/writes", b"{}")[0], 200)

    def test_hold_survives_restart(self):
        self.call("POST", "/hold", token=True)
        app.DB.close()
        app.DB = app.open_db(os.path.join(self.tmp.name, "j.db"))
        self.assertTrue(self.call("GET", "/status", token=True)[2]["hold"])

    def test_disabled_allows_without_recording(self):
        app.ENABLED = False
        self.assertEqual(self.call("POST", "/check/api/writes", b"{}")[0], 200)
        self.assertEqual(self.entries(), [])

    def test_admin_paths_need_token(self):
        self.assertEqual(self.call("GET", "/status")[0], 401)
        self.assertEqual(self.call("POST", "/hold")[0], 401)
        self.assertEqual(self.call("GET", "/entries?since=0")[0], 401)
        self.assertEqual(self.call("GET", "/health")[0], 200)

    def test_check_port_has_no_admin_paths_and_admin_port_no_check(self):
        self.assertEqual(self.call("GET", "/entries?since=0", token=True, base=self.base)[0], 404)
        self.assertEqual(self.call("POST", "/hold", token=True, base=self.base)[0], 404)
        self.assertEqual(self.call("POST", "/check/api/writes", b"{}", base=self.admin_base, token=True)[0], 404)
        self.assertEqual(self.entries(), [])

    def test_entries_tsv_for_replay(self):
        self.call("POST", "/check/api/writes", b"{}", {"Idempotency-Key": "k-1", "Content-Type": "application/json"})
        self.call("DELETE", "/check/api/x")
        req = urllib.request.Request(
            self.admin_base + "/entries?since=0&format=tsv", headers={"Authorization": f"Bearer {TOKEN}"}
        )
        with urllib.request.urlopen(req, timeout=5) as r:
            lines = r.read().decode().splitlines()
        a, b = (line.split("\t") for line in lines)
        self.assertEqual(a[1:], ["POST", "/api/writes", "k-1", "application/json", base64.b64encode(b"{}").decode(), "0"])
        self.assertEqual(b[1:], ["DELETE", "/api/x", "-", "-", "-", "0"])

    def test_status_counts(self):
        self.call("POST", "/check/api/writes", b"{}")
        s = self.call("GET", "/status", token=True)[2]
        self.assertEqual((s["enabled"], s["hold"], s["count"]), (True, False, 1))


if __name__ == "__main__":
    unittest.main()
