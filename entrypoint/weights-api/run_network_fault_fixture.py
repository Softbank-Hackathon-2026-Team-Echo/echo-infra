"""실소켓 local network fault fixture. Envoy replacement/validation이 아니다.

제품 generator/latch → 제한된 RDS interpreter HTTP fixture proxy → 독립 HTTP origins.
retry/deadline의 native enforcement, Cloud DB, durable writes는 검증하지 않는다.
실패 조건도 끝까지 기록하며 JUnit failure를 숨기지 않는다.
"""

import concurrent.futures
import http.client
import json
import shutil
import socket
import sys
import threading
import time
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from test_network_resilience import (
    EIDS,
    HOSTS,
    SIDS,
    NetworkResilienceTest,
    Origin,
    request,
)

OUT = Path(sys.argv[1]).resolve()
OUT.mkdir(parents=True, exist_ok=False)
ALL, RESOURCES, EVENTS = [], [], []


def stamp():
    return datetime.now(UTC).isoformat()


def event(case, stage, **kwargs):
    row = {
        "case": case,
        "stage": stage,
        "at": stamp(),
        "mono": time.monotonic(),
        **kwargs,
    }
    EVENTS.append(row)
    with (OUT / "events.jsonl").open("a") as stream:
        stream.write(json.dumps(row) + "\n")
    return row


def exercise(case):
    f = NetworkResilienceTest("test_socket_reset_failover_is_service_scoped_and_sticky")
    f.setUp()
    root = OUT / case
    root.mkdir()
    stop = threading.Event()
    proxy = api = monitor = None
    records, resources, issues = [], [], []
    probe_state = {}
    recovery_seconds = None

    def check(condition, message):
        if not condition:
            issues.append(message)
            event(case, "ASSERTION_FAILED", message=message)

    def health_loop():
        try:
            while not stop.is_set():
                clusters = []
                for sid, origins in zip(SIDS, f.service_origins):
                    for eid, origin in zip(EIDS, origins):
                        start = time.monotonic()
                        status, _, latency = request(
                            origin.port, path="/healthz", timeout=0.25
                        )
                        health = probe_state.setdefault(
                            (sid, eid), {"good": 0, "bad": 0, "healthy": False}
                        )
                        if status == 200:
                            health["good"] += 1
                            health["bad"] = 0
                            if health["good"] >= 3:
                                health["healthy"] = True
                        else:
                            health["bad"] += 1
                            health["good"] = 0
                            if health["bad"] >= 2:
                                health["healthy"] = False
                        row = {
                            "case": case,
                            "mono": start,
                            "port": origin.port,
                            "serviceId": sid,
                            "environmentId": eid,
                            "status": status,
                            "latencyMs": latency * 1000,
                            "qualified": health["healthy"],
                            "observer": "fixture HTTP probe, NOT native Envoy",
                        }
                        with (OUT / "health.jsonl").open("a") as stream:
                            stream.write(json.dumps(row) + "\n")
                        clusters.append(
                            {
                                "name": f.app.cluster_id(sid, eid),
                                "host_statuses": [
                                    {
                                        "health_status": {
                                            "eds_health_status": "HEALTHY",
                                            "failed_active_health_check": not health[
                                                "healthy"
                                            ],
                                        }
                                    }
                                ],
                            }
                        )
                f.store.observe_read_health(
                    {"cluster_statuses": clusters}, time.monotonic()
                )
                stop.wait(0.2)
        except Exception as error:  # noqa: BLE001 - record failure and still clean all owned fixtures
            issues.append("health fixture error: " + repr(error))
            event(case, "HEALTH_FIXTURE_ERROR", error=repr(error))

    class Proxy(BaseHTTPRequestHandler):
        def do_GET(self):
            try:
                sid = HOSTS.index(self.headers.get("Host", ""))
            except ValueError:
                status, body = 404, "unknown-host"
            else:
                status, body, _ = f.route(
                    sid=sid,
                    method=self.command,
                    path=self.path,
                    idempotency_key=self.headers.get("Idempotency-Key") or "",
                    timeout=0.5,
                )
            raw = body.encode()
            self.send_response(status)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            try:
                self.wfile.write(raw)
            except (BrokenPipeError, ConnectionResetError):
                event(case, "fixture-client-disconnected")

        do_POST = do_GET

        def log_message(self, format, *args):
            pass

    def start_server(handler):
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        resources.append(
            {
                "name": "echo-net-" + case + "-" + str(server.server_port),
                "port": server.server_port,
                "host": "127.0.0.1",
                "type": "http-fixture",
            }
        )
        return server, worker

    def close_server(pair):
        if pair:
            pair[0].shutdown()
            pair[0].server_close()
            pair[1].join()

    def call(stage, sid=0, method="GET", path="/status"):
        at, start = stamp(), time.monotonic()
        connection = http.client.HTTPConnection(
            "127.0.0.1", proxy[0].server_port, timeout=0.7
        )
        key = (
            "echo-net-fixture-" + case + "-" + str(len(records))
            if method == "POST"
            else None
        )
        try:
            headers = {"Host": HOSTS[sid]}
            if key:
                headers["Idempotency-Key"] = key
            connection.request(method, path, headers=headers)
            response = connection.getresponse()
            status, body = response.status, response.read().decode()
        except (OSError, http.client.HTTPException) as error:
            status, body = 0, type(error).__name__
        finally:
            connection.close()
        row = {
            "case": case,
            "stage": stage,
            "at": at,
            "mono": start,
            "latencyMs": (time.monotonic() - start) * 1000,
            "serviceId": SIDS[sid],
            "host": HOSTS[sid],
            "method": method,
            "path": path,
            "status": status,
            "originOrError": body,
            "idempotencyKey": key,
            "commitStatus": "UNKNOWN"
            if method == "POST" and body == "UNKNOWN"
            else "NOT_A_DURABLE_DB_TEST",
            "layer": "HTTP fixture proxy / RDS interpreter, NOT Envoy",
        }
        records.append(row)
        with (root / "requests.jsonl").open("a") as stream:
            stream.write(json.dumps(row) + "\n")
        return row

    def traffic(stage, seconds):
        end = time.monotonic() + seconds
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            while time.monotonic() < end:
                list(pool.map(lambda sid: call(stage, sid), range(3)))
                time.sleep(0.15)

    def matching(stage):
        return [r for r in records if r["stage"] == stage and r["serviceId"] == SIDS[0]]

    try:
        for origins in f.service_origins:
            for origin in origins:
                resources.append(
                    {
                        "name": "echo-net-" + case + "-" + origin.name,
                        "port": origin.port,
                        "host": "127.0.0.1",
                        "type": "origin",
                    }
                )
        proxy, api = start_server(Proxy), start_server(f.app.Handler)
        monitor = threading.Thread(
            target=health_loop, daemon=True, name="echo-net-" + case + "-health"
        )
        monitor.start()
        event(case, "warmup")
        traffic("warmup", 3.5)
        initial = call("initial")
        check(
            initial["originOrError"] == "origin-a",
            "initial origin A not qualified after warmup",
        )
        if case == "control-outage":
            stop.set()
            monitor.join()
            api_port = api[0].server_port
            close_server(api)
            api = None
            files = {
                p.name: p.read_bytes() for p in Path(f.app.DYNAMIC_DIR).glob("*.yaml")
            }
            event(case, "weights-api-and-controller-unavailable", port=api_port)
            check(
                request(api_port, path="/weights")[0] == 503,
                "weights API was not disconnected",
            )
            traffic("control-outage", 2.0)
            check(
                {p.name: p.read_bytes() for p in Path(f.app.DYNAMIC_DIR).glob("*.yaml")}
                == files,
                "last good xDS files changed during control outage",
            )
            check(
                all(
                    r["status"] == 200
                    for r in records
                    if r["stage"] == "control-outage"
                ),
                "fixture data path failed during control outage",
            )
        else:
            fault = event(case, "fault", mode=case)
            if case == "refused":
                f.origins[0].close()
            else:
                f.origins[0].mode = "reset" if case == "all-dead" else case
            call("response-loss-probe", method="POST")
            traffic("fault", 1.8)
            alternatives = [
                r for r in matching("fault") if r["originOrError"] == "origin-b"
            ]
            check(
                bool(alternatives),
                "no qualified alternative response within fault measurement window",
            )
            if alternatives:
                recovery_seconds = min(r["mono"] for r in alternatives) - fault["mono"]
            if case == "refused":
                f.origins[0] = Origin("origin-a", port=f.origins[0].port)
            else:
                f.origins[0].mode = "ok"
            event(case, "reconnect")
            traffic("reconnect", 2.5)
            check(
                any(r["originOrError"] == "origin-b" for r in matching("reconnect")),
                "alternative did not serve during reconnect window",
            )
            check(
                not any(
                    r["originOrError"] == "origin-a" for r in matching("reconnect")
                ),
                "unexpected automatic failback to old origin A",
            )
            for index in range(4):
                f.origins[0].mode = "reset" if index % 2 == 0 else "ok"
                event(case, "flap", index=index, mode=f.origins[0].mode)
                traffic("flap", 0.25)
            check(
                not any(r["originOrError"] == "origin-a" for r in matching("flap")),
                "flap caused automatic return to old origin",
            )
            if case == "all-dead":
                f.origins[1].mode = "blackhole"
                event(case, "no-safe-target")
                traffic("all-dead", 1.0)
                check(
                    all(not 200 <= r["status"] < 300 for r in matching("all-dead")),
                    "all origins dead produced fake 2xx",
                )
                f.origins[1].mode = "ok"
                event(case, "current-target-reconnect")
                traffic("current-target-reconnect", 3.3)
                check(
                    call("recovered")["originOrError"] == "origin-b",
                    "stable current target did not recover",
                )
            writes_before = sum(
                c[1] == "POST"
                for origins in f.service_origins
                for o in origins
                for c in o.calls
            )
            check(
                call("write-held", method="POST")["status"] == 503,
                "unsafe writes not held",
            )
            check(
                sum(
                    c[1] == "POST"
                    for origins in f.service_origins
                    for o in origins
                    for c in o.calls
                )
                == writes_before,
                "held write dispatched to origin",
            )
            event(case, "recovery-measured", secondsToAlternative=recovery_seconds)
        check(f.store.snapshot() == f.before, "control weights/revisions changed")
        check(
            all(r["status"] == 200 for r in records if r["serviceId"] != SIDS[0]),
            "other service requests failed (including fixture scheduling/deadline failures)",
        )
        check(
            max(r["latencyMs"] for r in records) <= 1500,
            "fixture observed request exceeded candidate 1500ms target",
        )
    except Exception as error:  # noqa: BLE001 - record failure and still clean all owned fixtures
        issues.append("fixture exception: " + repr(error))
        event(case, "FIXTURE_ERROR", error=repr(error))
    finally:
        stop.set()
        if monitor:
            monitor.join(timeout=4)
        for name in ("routes.yaml", "clusters.yaml"):
            source = Path(f.app.DYNAMIC_DIR) / name
            if source.exists():
                shutil.copyfile(source, root / name)
        shutil.copyfile(f.store.read_state_path, root / "read-failover.json")
        post_keys = Counter(
            c[3]
            for origins in f.service_origins
            for o in origins
            for c in o.calls
            if c[1] == "POST"
        )
        (root / "origin-post-keys.json").write_text(
            json.dumps(dict(post_keys), indent=2)
        )
        summary = {
            "case": case,
            "requests": len(records),
            "errors": sum(r["status"] >= 500 or r["status"] == 0 for r in records),
            "otherServiceErrors": sum(
                r["status"] >= 500 or r["status"] == 0
                for r in records
                if r["serviceId"] != SIDS[0]
            ),
            "warmupErrors": sum(
                r["status"] >= 500 or r["status"] == 0
                for r in records
                if r["stage"] == "warmup"
            ),
            "postSentToOrigins": sum(post_keys.values()),
            "duplicatePostTransmissions": sum(
                max(count - 1, 0) for count in post_keys.values()
            ),
            "durableMissingWrites": "UNVERIFIED",
            "durableDuplicateWrites": "UNVERIFIED",
            "maxLatencyMs": max((r["latencyMs"] for r in records), default=0),
            "secondsToAlternative": recovery_seconds,
            "configBudgetMs": 1500,
            "fixtureOriginTimeoutMs": 500,
            "fixtureClientTimeoutMs": 700,
            "nativeEnforcement": "UNVERIFIED",
            "fixtureAcceptance": "liveness + no failback; NOT zero errors",
            "fixtureHealthTimeoutMs": 250,
            "fixtureHealthUnhealthyThreshold": 2,
            "fixtureHealthHealthyThreshold": 3,
            "startedAt": records[0]["at"] if records else None,
            "endedAt": stamp(),
            "durationSeconds": time.monotonic() - records[0]["mono"] if records else 0,
            "controlSnapshotUnchanged": f.store.snapshot() == f.before,
            "pass": not issues,
            "issues": issues,
        }
        (root / "summary.json").write_text(json.dumps(summary, indent=2))
        ALL.append(summary)
        close_server(api)
        close_server(proxy)
        f.tearDown()
        for resource in resources:
            probe = socket.socket()
            probe.settimeout(0.1)
            resource["closedAfter"] = (
                probe.connect_ex(("127.0.0.1", resource["port"])) != 0
            )
            probe.close()
        RESOURCES.extend(resources)
        (root / "resources.json").write_text(json.dumps(resources, indent=2))
        (OUT / "summary-partial.json").write_text(json.dumps(ALL, indent=2))


for case in ("reset", "refused", "blackhole", "delay", "control-outage", "all-dead"):
    exercise(case)
    print(case, ALL[-1], flush=True)
(OUT / "events.json").write_text(json.dumps(EVENTS, indent=2))
(OUT / "resources.json").write_text(json.dumps(RESOURCES, indent=2))
(OUT / "summary.json").write_text(
    json.dumps(
        {
            "layer": "real sockets + fixture RDS interpreter; NOT native Envoy",
            "cases": ALL,
            "allOwnedPortsClosed": all(r["closedAfter"] for r in RESOURCES),
            "newDockerResources": 0,
            "nativeEnvoy": "BLOCKED by tool policy before daemon info/pull/run",
        },
        indent=2,
    )
)
suite = ET.Element(
    "testsuite",
    name="network-fault-fixture-NOT-envoy",
    tests=str(len(ALL)),
    failures=str(sum(not result["pass"] for result in ALL)),
    errors="0",
)
for result in ALL:
    case_xml = ET.SubElement(
        suite, "testcase", name=result["case"], time=str(result["durationSeconds"])
    )
    if not result["pass"]:
        ET.SubElement(case_xml, "failure", message="; ".join(result["issues"]))
ET.ElementTree(suite).write(OUT / "junit.xml", encoding="unicode")
sys.exit(1 if any(not result["pass"] for result in ALL) else 0)
