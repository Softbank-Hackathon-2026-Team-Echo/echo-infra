import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("security_transport", pathlib.Path(__file__).with_name("security_transport.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
NOW = "2026-11-08T00:00:00+00:00"


def plain_cluster():
    return {"name": "aws", "load_assignment": {"endpoints": [{"lb_endpoints": [
        {"endpoint": {"address": {"socket_address": {"address": "10.0.0.1", "port_value": 80}}}}
    ]}]}}


def dump(cluster):
    return {"configs": [{"@type": "type.googleapis.com/envoy.admin.v3.ClustersConfigDump",
                         "dynamic_active_clusters": [{"cluster": cluster}]}]}


class TransportTests(unittest.TestCase):
    def test_actual_envoy_dynamic_cluster_shape(self):
        payload = {"configs":[{"@type":"type.googleapis.com/envoy.admin.v3.ClustersConfigDump.DynamicCluster",
                               "cluster":plain_cluster()}]}
        self.assertEqual(module.summarize(payload, ["aws"], NOW)[0]["reason"], "PLAINTEXT_TRANSPORT")

    def test_plaintext_active_cluster_warns(self):
        result = module.summarize(dump(plain_cluster()), ["aws"], NOW)
        self.assertEqual(result[0]["result"], "WARN")
        self.assertEqual(result[0]["reason"], "PLAINTEXT_TRANSPORT")

    def test_missing_cluster_is_unknown(self):
        self.assertEqual(module.summarize(dump(plain_cluster()), ["gcp"], NOW)[0]["result"], "UNKNOWN")

    def test_tls_without_validation_warns(self):
        cluster = {"name": "aws", "transport_socket": {"name": "envoy.transport_sockets.tls", "typed_config": {}}}
        self.assertEqual(module.summarize(dump(cluster), ["aws"], NOW)[0]["result"], "WARN")

    def test_tls_requires_actual_probe(self):
        cluster = {"name": "aws", "transport_socket": {"name": "envoy.transport_sockets.tls", "typed_config": {
            "sni": "example.org", "common_tls_context": {"validation_context": {
                "trusted_ca": {"filename": "/etc/ssl/certs/ca-certificates.crt"}, "match_typed_subject_alt_names": [{"san_type": "DNS", "matcher": {"exact": "example.org"}}]}}}}}
        for outcome in ("PASS", "WARN", "UNKNOWN"):
            result = module.summarize(dump(cluster), ["aws"], NOW,
                                      probe=lambda *_: (outcome, "PROBE_RESULT"))
            self.assertEqual(result[0]["result"], outcome)
            self.assertNotIn("/not/read", str(result))

    def test_conditional_transport_never_passes(self):
        cluster = {"name": "aws", "transport_socket_matches": [{}]}
        self.assertEqual(module.summarize(dump(cluster), ["aws"], NOW)[0]["result"], "UNKNOWN")

class TlsBoundaryTests(unittest.TestCase):
    def cluster(self):
        return {"name": "gcp", "transport_socket": {
            "name": "envoy.transport_sockets.tls",
            "typed_config": {"sni": "origin.example.org", "common_tls_context": {
                "validation_context": {
                    "trusted_ca": {"filename": "/etc/ssl/certs/ca-certificates.crt"},
                    "match_typed_subject_alt_names": [{"san_type": "DNS", "matcher": {"exact": "origin.example.org"}}]
                }
            }}
        }}
    def test_ca_path_and_weakened_peer_checks_are_not_pass(self):
        from unittest.mock import Mock
        for changed, reason in [
            ({"trusted_ca": {"filename": "/private/ca.pem"}}, "TLS_TRUST_STORE_UNSUPPORTED"),
            ({"trust_chain_verification": "ACCEPT_UNTRUSTED"}, "TLS_PEER_VALIDATION_DISABLED"),
            ({"match_typed_subject_alt_names": [{"san_type": "DNS", "matcher": {"suffix": ".org"}}]}, "TLS_PEER_MATCH_UNSUPPORTED"),
        ]:
            cluster = self.cluster()
            cluster["transport_socket"]["typed_config"]["common_tls_context"]["validation_context"].update(changed)
            probe = Mock(side_effect=AssertionError("must not probe unsupported settings"))
            value = module.summarize(dump(cluster), ["gcp"], NOW, probe)[0]
            self.assertEqual(value["reason"], reason)
            self.assertNotEqual(value["result"], "PASS")
            probe.assert_not_called()

    def test_explicit_legacy_tls_minimum_warns(self):
        cluster = self.cluster()
        cluster["transport_socket"]["typed_config"]["common_tls_context"]["tls_params"] = {"tls_minimum_protocol_version": "TLSv1_0"}
        self.assertEqual(module.summarize(dump(cluster), ["gcp"], NOW)[0]["reason"], "TLS_MINIMUM_TOO_LOW")

    def test_metadata_loopback_and_mixed_dns_are_rejected_before_connection(self):
        from unittest.mock import patch, Mock
        cluster = {"load_assignment": {"endpoints": [{"lb_endpoints": [
            {"endpoint": {"address": {"socket_address": {"address": "origin.example.org", "port_value": 443}}}}
        ]}]}}
        for addresses in (["127.0.0.1"], ["169.254.169.254"], ["::ffff:127.0.0.1"], ["10.0.0.1", "169.254.169.254"]):
            resolved = [(2, 1, 6, "", (ip, 443)) for ip in addresses]
            with patch.object(module.socket, "getaddrinfo", return_value=resolved), patch.object(module.socket, "create_connection") as connect:
                self.assertEqual(module._probe(cluster, Mock(), "origin.example.org"),
                                 ("UNKNOWN", "UPSTREAM_ADDRESS_FORBIDDEN"))
                connect.assert_not_called()


class PlaintextBoundaryTests(unittest.TestCase):
    def test_public_plaintext_is_fail_private_is_warn(self):
        from unittest.mock import patch
        for address, result in (("8.8.8.8", "FAIL"), ("10.0.0.1", "WARN")):
            with patch.object(module.socket, "getaddrinfo", return_value=[(2, 1, 6, "", (address, 80))]):
                self.assertEqual(module.summarize(dump(plain_cluster()), ["aws"], NOW)[0]["result"], result)
    def test_unresolved_plaintext_scope_is_unknown(self):
        from unittest.mock import patch
        with patch.object(module.socket, "getaddrinfo", side_effect=OSError):
            self.assertEqual(module.summarize(dump(plain_cluster()), ["aws"], NOW)[0]["result"], "UNKNOWN")


if __name__ == "__main__":
    unittest.main()
