import importlib.util
from pathlib import Path
import subprocess
import unittest

spec = importlib.util.spec_from_file_location("observer", Path(__file__).with_name("observer.py"))
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)
PG = {"id":"replication","kind":"postgres","service":"db_monitor","session_target":"replication"}
POOL = {"id":"pool-db","kind":"pool-servers","service":"pool_monitor","database":"app","user":"app_user"}


class ObserverTests(unittest.TestCase):
    def test_plaintext_postgres(self):
        result = observer.inspect_rows(PG, [{"target":"replication","ssl":"f","version":"","session_count":"1"}], "now")
        self.assertEqual(result["result"], "WARN")

    def test_tls_does_not_prove_peer_validation(self):
        result = observer.inspect_rows(PG, [{"target":"replication","ssl":"t","version":"TLSv1.3","session_count":"1"}], "now")
        self.assertEqual(result["reason"], "TLS_PEER_VERIFICATION_UNOBSERVED")

    def test_no_active_session_unknown(self):
        self.assertEqual(observer.inspect_rows(PG, [], "now")["result"], "UNKNOWN")

    def test_unrelated_session_not_evidence(self):
        self.assertEqual(observer.inspect_rows(POOL, [{"user":"other","database":"app","tls":"TLSv1.3"}], "now")["result"], "UNKNOWN")

    def test_mixed_pool_connections_warn(self):
        rows = [{"user":"app_user","database":"app","tls":"TLSv1.3/cipher"},
                {"user":"app_user","database":"app","tls":""}]
        self.assertEqual(observer.inspect_rows(POOL, rows, "now")["result"], "WARN")

    def test_old_pool_without_tls_column_unknown(self):
        self.assertEqual(observer.inspect_rows(POOL, [{"user":"app_user","database":"app"}], "now")["result"], "UNKNOWN")

    def test_read_failure_is_sanitized(self):
        def fail(target):
            raise subprocess.CalledProcessError(1, "psql", stderr="SECRET")
        result = observer.collect({"revision":"v1","targets":[PG,POOL]}, fail)
        self.assertEqual(len(result["checks"]), 2)
        self.assertNotIn("SECRET", str(result))
        self.assertTrue(all(x["result"] == "UNKNOWN" for x in result["checks"]))

    def test_config_rejects_extra_queries(self):
        with self.assertRaises(ValueError):
            observer.validate({"revision":"v1","targets":[dict(PG,query="DELETE")]})

    def test_query_is_fixed_and_no_password_in_argv(self):
        from unittest.mock import patch
        with patch.object(observer.subprocess, "run") as run:
            run.return_value.stdout = b"target,ssl,version,session_count\n"
            observer.read_query(PG)
            args = run.call_args.args[0]
            self.assertIn("service=db_monitor", args)
            self.assertIn(observer.QUERIES["postgres"], args)
            self.assertTrue(run.call_args.kwargs["check"])
