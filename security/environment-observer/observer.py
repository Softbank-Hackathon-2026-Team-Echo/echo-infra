"""Read-only DB transport observer. Emits identifiers/results, never SQL or credentials."""
import csv
import datetime
import io
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import urllib.request

IDENTIFIER = re.compile(r"^[a-z][a-z0-9_-]{0,62}$")
MAX_BYTES = 65536
QUERIES = {
    "postgres": "SELECT target, ssl, version, session_count FROM echo_security.transport_sessions();",
    "pool-clients": "SHOW CLIENTS;",
    "pool-servers": "SHOW SERVERS;",
}


def inspect_rows(target, rows, now):
    kind = target["kind"]
    if kind == "postgres":
        selected = [r for r in rows if r.get("target") == target["session_target"]]
        if any(not str(r.get("session_count", "")).isdigit() for r in selected):
            return check(target["id"], "UNKNOWN", "OBSERVATION_INVALID", now)
        selected = [r for r in selected if int(r["session_count"]) > 0]
        if not selected:
            return check(target["id"], "UNKNOWN", "NO_ACTIVE_SESSION", now)
        if any(r.get("ssl") not in ("t", "true", "f", "false") for r in selected):
            return check(target["id"], "UNKNOWN", "OBSERVATION_INVALID", now)
        if any(r["ssl"] in ("f", "false") for r in selected):
            return check(target["id"], "WARN", "PLAINTEXT_DATABASE_SESSION", now)
        versions = [r.get("version", "") for r in selected]
    else:
        selected = [r for r in rows if r.get("database") == target["database"]
                    and r.get("user") == target["user"]]
        if not selected:
            return check(target["id"], "UNKNOWN", "NO_ACTIVE_SESSION", now)
        if any("tls" not in r for r in selected):
            return check(target["id"], "UNKNOWN", "TLS_COLUMN_UNAVAILABLE", now)
        if any(not r["tls"] for r in selected):
            return check(target["id"], "WARN", "PLAINTEXT_DATABASE_SESSION", now)
        versions = [r["tls"].split("/")[0] for r in selected]
    if any(version not in ("TLSv1.2", "TLSv1.3") for version in versions):
        return check(target["id"], "WARN", "TLS_VERSION_TOO_LOW", now)
    # Server-side TLS counters cannot prove client verify-full / hostname verification.
    return check(target["id"], "UNKNOWN", "TLS_PEER_VERIFICATION_UNOBSERVED", now)


def check(name, result, reason, now):
    return {"id": name, "result": result, "reason": reason,
            "observed_at": now, "source": "DATA_ENGINE"}


def validate(config):
    if set(config) != {"revision", "targets"} or not isinstance(config["revision"], str):
        raise ValueError("invalid observer config")
    if not 1 <= len(config["revision"]) <= 64 or not 1 <= len(config["targets"]) <= 32:
        raise ValueError("invalid observer config")
    ids = []
    for target in config["targets"]:
        if target.get("kind") not in QUERIES:
            raise ValueError("unsupported target")
        required = {"id", "kind", "service"}
        required |= {"session_target"} if target["kind"] == "postgres" else {"database", "user"}
        if set(target) != required:
            raise ValueError("invalid target")
        if not all(isinstance(v, str) and IDENTIFIER.fullmatch(v) for v in target.values()):
            raise ValueError("invalid identifier")
        ids.append(target["id"])
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate target")
    return config


def collect(config, query=None):
    config = validate(config)
    query = query or read_query
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    checks = []
    for target in config["targets"]:
        try:
            checks.append(inspect_rows(target, query(target), now))
        except (OSError, ValueError, subprocess.SubprocessError):
            checks.append(check(target["id"], "UNKNOWN", "DATABASE_READ_FAILED", now))
    return {"schema_version": 1, "revision": config["revision"],
            "observed_at": now, "checks": checks}


def read_query(target):
    # Fixed query, service-name-only argv. Passwords stay in the mounted libpq service file.
    env = os.environ.copy()
    env["PGCONNECT_TIMEOUT"] = "5"
    env["PGAPPNAME"] = "echo-security-observer"
    result = subprocess.run(
        ["psql", "-X", "--no-password", "--csv", "--set", "ON_ERROR_STOP=1",
         "--dbname", "service=" + target["service"], "--command", QUERIES[target["kind"]]],
        env=env, capture_output=True, timeout=10, check=True,
    )
    if len(result.stdout) > MAX_BYTES:
        raise ValueError("observation exceeds budget")
    return list(csv.DictReader(io.StringIO(result.stdout.decode("utf-8"))))


def publish(observation):
    # Only this pre-created ConfigMap can be patched by the service account.
    root = Path("/var/run/secrets/kubernetes.io/serviceaccount")
    token = (root / "token").read_text().strip()
    body = json.dumps({"data": {"observation.json": json.dumps(observation)}}).encode()
    request = urllib.request.Request(
        "https://kubernetes.default.svc/api/v1/namespaces/echo-security/configmaps/transport-evidence",
        data=body, method="PATCH",
        headers={"Authorization": "Bearer " + token,
                 "Content-Type": "application/merge-patch+json"},
    )
    context = ssl.create_default_context(cafile=str(root / "ca.crt"))
    with urllib.request.urlopen(request, context=context, timeout=10) as response:
        if response.status != 200:
            raise ValueError("snapshot publish failed")


def main():
    try:
        raw = Path("/etc/echo-security/targets.json").read_bytes()
        if len(raw) > MAX_BYTES:
            raise ValueError("config exceeds budget")
        publish(collect(json.loads(raw)))
    except Exception:
        # Neither DB errors nor Kubernetes response bodies may enter logs.
        print('{"action":"collect_database_transport","result":"FAILED"}')
        return 1
    print('{"action":"collect_database_transport","result":"RECORDED"}')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
