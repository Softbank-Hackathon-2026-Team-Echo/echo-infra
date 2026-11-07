"""Offline regression for the preflight DNS/Envoy route check; no cloud calls."""
import os
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'preflight.sh'


class RouteCheckTests(unittest.TestCase):
    def run_check(self, dns, upstream, ssh_fail=False):
        src = SCRIPT.read_text()
        self.assertIn('# BEGIN GCP_ROUTE_CHECK', src, 'preflight must compare DNS with the serving ingress')
        block = src.split('# BEGIN GCP_ROUTE_CHECK\n', 1)[1].split('# END GCP_ROUTE_CHECK', 1)[0]
        setup = r'''
APP=demo-y6cz3jrc.echoport.uk
GCFG=echo
ng=0
check() { printf 'CHECK %s %s\n' "$2" "$3"; [ "$2" = 0 ] || ng=$((ng+1)); }
getent() { [ -z "$DNS_FIXTURE" ] || printf '%s demo.gcp-seoul.echoport.uk\n' "$DNS_FIXTURE"; }
curl() { [ -z "$UP_FIXTURE" ] || printf 'gcp::%s:80::health_flags::healthy\n' "$UP_FIXTURE"; }
export -f getent curl
gcloud() { while [ "$#" -gt 0 ]; do if [ "$1" = --command ]; then shift; bash -c "$1"; [ "$SSH_FAIL" != 1 ]; return; fi; shift; done; return 2; }
'''
        env = dict(os.environ, DNS_FIXTURE=dns, UP_FIXTURE=upstream, SSH_FAIL='1' if ssh_fail else '0')
        return subprocess.run(['bash', '-c', setup + '\n' + block + '\n[ "$ng" = 0 ]'], env=env, text=True, capture_output=True)

    def test_old_ingress_fails_even_if_readiness_would_return_200(self):
        r = self.run_check('10.60.0.8', '10.63.0.14')
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn('DNS 10.60.0.8', r.stdout)
        self.assertIn('업스트림 10.63.0.14', r.stdout)


    def test_matching_customer_ingress_passes(self):
        r = self.run_check('10.63.0.14', '10.63.0.14')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_missing_dns_or_upstream_fails_closed(self):
        for dns, upstream in [('', ''), ('', '10.63.0.14'), ('10.63.0.14', '')]:
            with self.subTest(dns=dns, upstream=upstream):
                r = self.run_check(dns, upstream)
                self.assertNotEqual(r.returncode, 0, r.stdout)

    def test_ssh_failure_rejects_even_matching_partial_output(self):
        r = self.run_check('10.63.0.14', '10.63.0.14', ssh_fail=True)
        self.assertNotEqual(r.returncode, 0, r.stdout)


if __name__ == '__main__':
    unittest.main()
