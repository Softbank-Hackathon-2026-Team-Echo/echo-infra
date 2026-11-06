#!/usr/bin/env python3
"""진입점 요청 기록 (인프라 12.4).

Envoy ext_authz(HTTP)가 요청마다 부른다. 쓰기(POST·PUT·PATCH·DELETE)는 VM 디스크 SQLite 에 기록한 뒤 허용하고,
도쿄 원본이 죽어 서울을 승격할 때 replay.sh 가 기록을 서울 앱에 다시 보낸다(specs/infra-12.4-request-journal.md).
표준 라이브러리만 쓴다. 기본 꺼짐: JOURNAL_ENABLED=false 이거나 Envoy 필터가 0% 면 아무것도 기록하지 않는다.

포트를 둘로 나눈다. 확인 포트를 밖에 열면 누구나 가짜 쓰기를 기록에 넣고, 그게 재생 때 서울 DB 에 들어간다.
  확인 포트(PORT, 8081 — 도커 네트워크 안에서 Envoy 만)
  * /check/<원래 경로>   Envoy ext_authz 가 부른다. 쓰기면 기록 후 200, hold 중이면 429 + Retry-After
  관리 포트(ADMIN_PORT, 8082 — 토큰, entrypoint_admin_cidrs 에서만)
  GET  /health           살아 있나 (토큰 없이, 두 포트 모두)
  GET  /status           기록 수·가장 오래된·새 시각·hold 여부
  POST /hold             쓰기 막기 켜기 (재생 중 새 쓰기가 먼저 들어가지 않게). 다시 불러도 같다
  POST /release          쓰기 막기 끄기
  GET  /entries?since=   since(UNIX 초) 이후 기록을 받은 순서대로 (본문 base64)

환경 변수
  JOURNAL_TOKEN              관리 경로 Bearer 토큰 (비어 있으면 관리 경로는 503)
  JOURNAL_ENABLED            true 면 기록한다 (기본 false — 꺼져 있으면 /check 는 늘 200)
  JOURNAL_RETENTION_SECONDS  보관 시간 (기본 900 = 15분)
  JOURNAL_MAX_BODY_BYTES     기록할 본문 최대 크기 (기본 65536). 넘으면 잘라서 기록하고 truncated 표시
  JOURNAL_DB                 SQLite 경로 (기본 /data/journal.db)
  PORT                       확인 포트 (기본 8081)
  ADMIN_PORT                 관리 포트 (기본 8082)

기록하지 않는 것: Authorization·Cookie 등 헤더 전부(메서드·경로·Host·멱등 키·Content-Type 만 남긴다).
"""

import base64
import json
import os
import sqlite3
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("JOURNAL_TOKEN", "")
ENABLED = os.environ.get("JOURNAL_ENABLED", "false").strip().lower() == "true"
RETENTION = float(os.environ.get("JOURNAL_RETENTION_SECONDS", "900"))
MAX_BODY = int(os.environ.get("JOURNAL_MAX_BODY_BYTES", "65536"))
DB_PATH = os.environ.get("JOURNAL_DB", "/data/journal.db")
LISTEN_PORT = int(os.environ.get("PORT", "8081"))
ADMIN_PORT = int(os.environ.get("ADMIN_PORT", "8082"))

WRITE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}
CHECK_PREFIX = "/check"
RETRY_AFTER_SECONDS = "2"

LOCK = threading.Lock()  # SQLite 연결 하나를 스레드끼리 나눠 쓴다(쓰기 직렬화)


def log(**kv):
    kv.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    print(json.dumps(kv, ensure_ascii=False), flush=True)


def open_db(path):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
    # 기록이 끝났다고 답하기 전에 디스크에 남긴다(VM 이 갑자기 꺼져도 허용한 요청은 남는다).
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=FULL")
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS entries (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          received_at REAL NOT NULL,
          method      TEXT NOT NULL,
          path        TEXT NOT NULL,
          host        TEXT NOT NULL,
          request_id  TEXT,
          content_type TEXT,
          body        BLOB NOT NULL,
          truncated   INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS entries_received_at ON entries (received_at);
        CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """
    )
    return conn


DB = None  # main() 에서 연다(시험은 open_db 로 따로 연다)


def is_held(db):
    row = db.execute("SELECT value FROM state WHERE key = 'hold'").fetchone()
    return row is not None and row[0] == "1"


def set_hold(db, on):
    with LOCK:
        db.execute(
            "INSERT INTO state (key, value) VALUES ('hold', ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            ("1" if on else "0",),
        )


def record(db, method, path, host, request_id, content_type, body, now=None):
    now = time.time() if now is None else now
    truncated = len(body) > MAX_BODY
    with LOCK:
        db.execute("BEGIN IMMEDIATE")
        try:
            db.execute(
                "INSERT INTO entries (received_at, method, path, host, request_id, content_type, body, truncated)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (now, method, path, host, request_id, content_type, body[:MAX_BODY], int(truncated)),
            )
            db.execute("DELETE FROM entries WHERE received_at < ?", (now - RETENTION,))
            db.execute("COMMIT")
        except Exception:
            db.execute("ROLLBACK")
            raise


def status(db):
    count, oldest, newest = db.execute(
        "SELECT count(*), min(received_at), max(received_at) FROM entries"
    ).fetchone()
    return {
        "enabled": ENABLED,
        "hold": is_held(db),
        "count": count,
        "oldest": oldest,
        "newest": newest,
        "retentionSeconds": RETENTION,
    }


def entries(db, since):
    rows = db.execute(
        "SELECT id, received_at, method, path, host, request_id, content_type, body, truncated"
        " FROM entries WHERE received_at >= ? ORDER BY id",
        (since,),
    ).fetchall()
    return [
        {
            "id": r[0],
            "receivedAt": r[1],
            "method": r[2],
            "path": r[3],
            "host": r[4],
            "requestId": r[5],
            "contentType": r[6],
            "body": base64.b64encode(r[7]).decode(),
            "truncated": bool(r[8]),
        }
        for r in rows
    ]


def request_key(headers):
    for name in ("Idempotency-Key", "X-Request-Id"):
        value = (headers.get(name) or "").strip()
        if value:
            return value
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "echo-journal"
    protocol_version = "HTTP/1.1"
    admin = False  # AdminHandler 만 관리 경로를 받는다

    def log_message(self, fmt, *args):  # 기본 접근 로그는 끈다(요청마다 한 줄은 Envoy 가 남긴다)
        pass

    def _send(self, code, body=None, headers=None):
        data = b"" if body is None else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        if body is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def _authorized(self):
        if not TOKEN:
            self._send(503, {"error": "JOURNAL_TOKEN 이 없다"})
            return False
        if self.headers.get("Authorization", "") != f"Bearer {TOKEN}":
            self._send(401, {"error": "unauthorized"})
            return False
        return True

    def _check(self):
        body = self._body()
        method = self.command
        if method not in WRITE_METHODS:
            return self._send(200)
        if is_held(DB):
            # 429 다: Envoy 는 인가 서비스의 5xx 를 "서비스 고장"으로 보고 failure_mode_allow 로 통과시킨다(로컬 확인).
            return self._send(429, {"error": "WRITES_ON_HOLD"}, {"Retry-After": RETRY_AFTER_SECONDS})
        if not ENABLED:
            return self._send(200)
        path = self.path[len(CHECK_PREFIX):] or "/"
        try:
            record(
                DB, method, path, self.headers.get("Host", ""), request_key(self.headers),
                self.headers.get("Content-Type"), body,
            )
        except sqlite3.Error as exc:
            # 기록이 안 돼도 쓰기는 통과시킨다(fail-open). Envoy 도 이 서비스가 죽으면 통과시킨다.
            log(level="error", msg="기록 실패, 통과시킴", error=type(exc).__name__)
        return self._send(200)

    def _route(self):
        parsed = urllib.parse.urlsplit(self.path)
        if self.command == "GET" and parsed.path == "/health":
            return self._send(200, {"status": "ok"})
        if not self.admin:
            if parsed.path == CHECK_PREFIX or parsed.path.startswith(CHECK_PREFIX + "/"):
                return self._check()
            return self._send(404, {"error": "not found"})
        if not self._authorized():
            return None
        if self.command == "GET" and parsed.path == "/status":
            return self._send(200, status(DB))
        if self.command == "POST" and parsed.path in ("/hold", "/release"):
            self._body()
            set_hold(DB, parsed.path == "/hold")
            log(msg="hold" if parsed.path == "/hold" else "release")
            return self._send(200, status(DB))
        if self.command == "GET" and parsed.path == "/entries":
            q = urllib.parse.parse_qs(parsed.query)
            try:
                since = float(q.get("since", ["0"])[0])
            except ValueError:
                return self._send(400, {"error": "since 는 UNIX 초"})
            return self._send(200, {"entries": entries(DB, since)})
        return self._send(404, {"error": "not found"})

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _route


class AdminHandler(Handler):
    admin = True


def main():
    global DB
    DB = open_db(DB_PATH)
    log(msg="journal 시작", enabled=ENABLED, retention=RETENTION, port=LISTEN_PORT, admin_port=ADMIN_PORT, hold=is_held(DB))
    admin = ThreadingHTTPServer(("0.0.0.0", ADMIN_PORT), AdminHandler)
    threading.Thread(target=admin.serve_forever, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
