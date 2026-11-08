"""Run only against an explicitly named disposable secu131 PostgreSQL container."""
import json
from pathlib import Path
import subprocess
import sys
import time

container = sys.argv[1]
if not container.startswith("echo-secu131-"):
    raise SystemExit("disposable test container required")
base = ["docker","exec","-i",container,"psql","-X","-v","ON_ERROR_STOP=1","-U","echo"]


def sql(query, database="secu_observer_test", expect_success=True):
    result = subprocess.run(base+["-d",database,"-tAc",query],capture_output=True,text=True)
    if expect_success and result.returncode:
        raise AssertionError("test SQL failed")
    return result


sql("CREATE DATABASE secu_observer_test;", "postgres")
sql(Path(__file__).with_name("monitor.sql").read_text())
sql("CREATE ROLE echo_transport_monitor LOGIN; GRANT USAGE ON SCHEMA echo_security TO echo_transport_monitor; GRANT EXECUTE ON FUNCTION echo_security.transport_sessions() TO echo_transport_monitor;")
sql("INSERT INTO echo_security.transport_targets VALUES ('replication','secu_observer_test','echo','fixture-transport');")
process = subprocess.Popen(["docker","exec","-e","PGAPPNAME=fixture-transport","-e","PGPASSWORD=echo",container,
                            "psql","-h","127.0.0.1","-U","echo","-d","secu_observer_test","-c","SELECT pg_sleep(20);"],
                           stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
try:
    observed = False
    for _ in range(30):
        result = sql("SET ROLE echo_transport_monitor; SELECT target || ':' || ssl || ':' || session_count FROM echo_security.transport_sessions();")
        if "replication:false:1" in result.stdout:
            observed = True
            break
        time.sleep(.1)
    assert observed, "plaintext TCP session not observed"
    assert sql("SET ROLE echo_transport_monitor; SELECT * FROM echo_security.transport_targets;",expect_success=False).returncode != 0
    assert sql("SET ROLE echo_transport_monitor; INSERT INTO echo_security.transport_targets VALUES ('bad','x','x','x');",expect_success=False).returncode != 0
    assert sql("SET ROLE echo_transport_monitor; CREATE ROLE forbidden_admin SUPERUSER;",expect_success=False).returncode != 0
    print(json.dumps({"postgres": "17", "activePlaintextSession":"observed",
                      "monitorFunction":"PASS","tableReadDenied":"PASS","tableWriteDenied":"PASS","roleEscalationDenied":"PASS"}))
finally:
    # End only this test session; no global connection termination.
    sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='secu_observer_test' AND application_name='fixture-transport';")
    process.wait(timeout=10)
