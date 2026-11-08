"""Real TLS socket boundary, disposable CA and observation upstream."""
import contextlib
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

from security_https import TlsServer, handler, read_token, tls_context


@contextlib.contextmanager
def tls_fixture():
    with tempfile.TemporaryDirectory(prefix="echo-secu131-https-") as folder:
        root = Path(folder)
        def openssl(*args):
            subprocess.run(["openssl", *args], check=True, capture_output=True, timeout=15)
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                "-addext", "basicConstraints=critical,CA:TRUE",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                "-subj", "/CN=fixture-ca", "-keyout", str(root/"ca.key"), "-out", str(root/"ca.crt"))
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1",
                "-keyout", str(root/"server.key"), "-out", str(root/"server.csr"))
        (root/"ext").write_text("subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n"
                               "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                               "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n")
        openssl("x509", "-req", "-in", str(root/"server.csr"), "-CA", str(root/"ca.crt"),
                "-CAkey", str(root/"ca.key"), "-CAcreateserial", "-days", "1",
                "-extfile", str(root/"ext"), "-out", str(root/"server.crt"))
        calls = []
        class Upstream(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass
            def do_GET(self):
                calls.append((self.path, self.headers.get("Authorization")))
                now = datetime.now(timezone.utc).isoformat()
                body = {"schema_version": 1, "revision": "v1", "observed_at": now, "checks": [
                    {"id": "aws", "result": "FAIL", "reason": "PUBLIC_PLAINTEXT_TRANSPORT",
                     "observed_at": now, "source": "TLS_PROBE"}
                ]}
                encoded = json.dumps(body).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
        upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        proxy = TlsServer(("127.0.0.1", 0), handler("fixture-read-token", "127.0.0.1", upstream.server_port),
                          tls_context(root/"server.crt", root/"server.key"))
        servers = [upstream, proxy]
        threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
        for thread in threads:
            thread.start()
        try:
            yield f"https://127.0.0.1:{proxy.server_port}", str(root/"ca.crt"), calls
        finally:
            for server in servers:
                server.shutdown()
                server.server_close()
            for thread in threads:
                thread.join()


class HttpsTests(unittest.TestCase):
    def test_https_read_auth_write_and_route_boundaries(self):
        with tls_fixture() as (url, ca, calls):
            context = ssl.create_default_context(cafile=ca)
            def request(path, method="GET", token="fixture-read-token", ctx=context):
                req = urllib.request.Request(url+path, method=method, headers={"Authorization":"Bearer "+token})
                try:
                    with urllib.request.urlopen(req, context=ctx, timeout=3) as response:
                        return response.status, json.load(response)
                except urllib.error.HTTPError as error:
                    with error:
                        return error.code, json.load(error)
            code, body = request("/security/transport?route=aws")
            self.assertEqual(code, 200)
            self.assertEqual(body["checks"][0]["result"], "FAIL")
            self.assertEqual(len(calls), 1)
            for path, method, token, expected in [
                ("/weights", "GET", "fixture-read-token", 404),
                ("/security/transport?route=aws", "GET", "wrong", 401),
                ("/security/transport?route=aws", "GET", "é", 401),
                ("/security/transport?route=aws&route=gcp", "GET", "fixture-read-token", 400),
                ("/security/transport?route=aws&url=http://evil", "GET", "fixture-read-token", 400),
                ("/security/transport?route=aws", "PUT", "fixture-read-token", 405),
                ("/security/transport?route=aws", "POST", "fixture-read-token", 405),
            ]:
                self.assertEqual(request(path, method, token)[0], expected)
            self.assertEqual(len(calls), 1)
            with self.assertRaises(urllib.error.URLError):
                request("/security/transport?route=aws", ctx=ssl.create_default_context())
            with self.assertRaises(urllib.error.URLError):
                urllib.request.urlopen(url.replace("127.0.0.1","localhost")+"/health", context=context, timeout=3)
            self.assertEqual(len(calls), 1)

    def test_token_file_conflict_fails_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            token = Path(folder)/"token"
            token.write_text("fixture-read-token\n")
            with patch.dict("os.environ", {"SECURITY_READ_TOKEN_FILE":str(token), "SECURITY_READ_TOKEN":""}):
                self.assertEqual(read_token(), "fixture-read-token")
            with patch.dict("os.environ", {"SECURITY_READ_TOKEN_FILE":str(token), "SECURITY_READ_TOKEN":"other"}):
                with self.assertRaises(ValueError):
                    read_token()

if __name__ == "__main__":
    unittest.main()
