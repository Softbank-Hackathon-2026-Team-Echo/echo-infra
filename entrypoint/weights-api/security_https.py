"""Dedicated HTTPS observation surface: no weights token or mutation routes."""

import hmac
import http.client
import json
import os
import re
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

MAX_RESPONSE = 65536


def read_token():
    path = os.environ.get("SECURITY_READ_TOKEN_FILE")
    value = Path(path).read_text().strip() if path else os.environ.get("SECURITY_READ_TOKEN", "")
    if not value or len(value) > 4096 or any(c.isspace() for c in value):
        raise ValueError("invalid security read token")
    if path and os.environ.get("SECURITY_READ_TOKEN") not in (None, "", value):
        raise ValueError("conflicting security read token sources")
    return value


def handler(token, upstream_host="weights-api", upstream_port=8080):
    class ReadOnlyHandler(BaseHTTPRequestHandler):
        timeout = 5

        def log_message(self, *_):
            pass  # headers, URLs and upstream exceptions never reach access logs

        def reply(self, status, body):
            encoded = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(encoded)

        def do_GET(self):
            parsed = urlsplit(self.path)
            if self.path == "/health":
                return self.reply(200, {"status": "ok"})
            if parsed.path != "/security/transport" or parsed.fragment:
                return self.reply(404, {"error": "not_found"})
            if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), f"Bearer {token}".encode()):
                return self.reply(401, {"error": "unauthorized"})
            query = parse_qs(parsed.query, keep_blank_values=True)
            if (set(query) != {"route"} or len(query["route"]) != 1
                or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,190}", query["route"][0])):
                return self.reply(400, {"error": "invalid_route"})
            upstream = http.client.HTTPConnection(upstream_host, upstream_port, timeout=5)
            try:
                upstream.request("GET", "/security/transport?" + urlencode({"route": query["route"][0]}),
                                 headers={"Authorization": f"Bearer {token}"})
                response = upstream.getresponse()
                raw = response.read(MAX_RESPONSE + 1)
                if response.status not in (200, 400, 401, 404, 503) or len(raw) > MAX_RESPONSE:
                    return self.reply(502, {"error": "observation_unavailable"})
                # No redirects, arbitrary paths, upstream headers or exception text forwarded.
                body = json.loads(raw) if response.status == 200 else {"error": "observation_unavailable"}
                if not isinstance(body, dict):
                    raise ValueError("invalid observation")
                return self.reply(response.status, body)
            except (OSError, ValueError, http.client.HTTPException):
                return self.reply(502, {"error": "observation_unavailable"})
            finally:
                upstream.close()

        def do_PUT(self):
            self.reply(405, {"error": "read_only"})

        do_POST = do_PUT
        do_PATCH = do_PUT
        do_DELETE = do_PUT

    return ReadOnlyHandler


def tls_context(cert, key):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    return context


class TlsServer(ThreadingHTTPServer):
    def __init__(self, address, request_handler, context):
        self.context = context
        super().__init__(address, request_handler)

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        try:
            return self.context.wrap_socket(connection, server_side=True), address
        except Exception:
            connection.close()
            raise


def main():
    token = read_token()
    context = tls_context(os.environ["SECURITY_TLS_CERT_FILE"], os.environ["SECURITY_TLS_KEY_FILE"])
    server = TlsServer(("0.0.0.0", 8443), handler(token), context)
    server.serve_forever()


if __name__ == "__main__":
    main()
