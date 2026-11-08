"""Disposable PgBouncer integration. Run verify_postgres.py first; no production input."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

pg = sys.argv[1]
if not pg.startswith("echo-secu131-"):
    raise SystemExit("disposable test container required")
network = "echo-secu131-pool-test-net"
pool = "echo-secu131-final-pool"


def run(*args, ok=True):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    if ok and result.returncode:
        raise AssertionError("test command failed: " + args[0] + " " + result.stderr[:300])
    return result


with tempfile.TemporaryDirectory(prefix="echo-secu131-pool-") as directory:
    root = Path(directory)
    # Credentials here belong only to disposable local containers.
    (root / "pgbouncer.ini").write_text(f"""[databases]
app = host={pg} port=5432 dbname=secu_observer_test user=echo password=echo
[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = plain
auth_file = /etc/pgbouncer/userlist.txt
stats_users = secu_stats
admin_users = echo
pool_mode = transaction
log_connections = 0
log_disconnections = 0
""")
    (root / "userlist.txt").write_text('"echo" "echo"\n"secu_stats" "local-test"\n')
    (root / "pg_service.conf").write_text(f"""[pool-monitor]
host={pool}
port=6432
dbname=pgbouncer
user=secu_stats
password=local-test
sslmode=disable
""")
    targets = {"revision": "local-test", "targets": [
        {"id": name, "kind": name, "service": "pool-monitor", "database": "app", "user": "echo"}
        for name in ("pool-clients", "pool-servers")
    ]}
    (root / "targets.json").write_text(json.dumps(targets))
    os.chmod(root, 0o755)
    for file in root.iterdir():
        os.chmod(file, 0o644)
    fixture = None
    try:
        run("docker", "network", "create", "--internal", network)
        run("docker", "network", "connect", network, pg)
        run("docker", "run", "--rm", "-d", "--name", pool, "--network", network,
            "-v", directory + ":/etc/pgbouncer:ro", "edoburu/pgbouncer:v1.26.1-p0")
        def query(statement):
            return run("docker", "exec", "-e", "PGPASSWORD=local-test", pg, "psql",
                       "-X", "-w", "-h", pool, "-p", "6432", "-U", "secu_stats",
                       "-d", "pgbouncer", "-v", "ON_ERROR_STOP=1", "-c", statement, ok=False)
        for _ in range(50):
            if query("SHOW VERSION;").returncode == 0:
                break
            time.sleep(.1)
        else:
            raise AssertionError("pool startup failed")
        assert query("PAUSE;").returncode != 0, "stats user must not pause traffic"
        fixture = subprocess.Popen(["docker", "exec", "-e", "PGPASSWORD=echo", pg,
            "psql", "-X", "-w", "-h", pool, "-p", "6432", "-U", "echo", "-d", "app",
            "-c", "SELECT pg_sleep(30);"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        code = ("import json,sys; sys.path.insert(0,'/opt/echo-security'); import observer; "
                "print(json.dumps(observer.collect(json.load(open('/fixture/targets.json')))))")
        for _ in range(15):
            value = run("docker", "run", "--rm", "--network", network,
                "-v", directory + ":/fixture:ro", "-e", "PGSERVICEFILE=/fixture/pg_service.conf",
                "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
                "--entrypoint", "python3", "echo-secu131-observer:test", "-B", "-c", code)
            observation = json.loads(value.stdout)
            if all(check["result"] == "WARN" and check["reason"] == "PLAINTEXT_DATABASE_SESSION"
                   for check in observation["checks"]):
                break
            time.sleep(.1)
        else:
            raise AssertionError("pool TLS observation missing: " + json.dumps(observation))
        print(json.dumps({"pgbouncer": "1.26.1", "observerImagePsql": "PASS",
                          "clientAndServerPlaintext": "WARN", "statsPauseDenied": "PASS"}))
    finally:
        run("docker", "stop", pool, ok=False)
        if fixture is not None:
            fixture.wait(timeout=10)
        run("docker", "network", "disconnect", network, pg, ok=False)
        run("docker", "network", "rm", network, ok=False)
