"""Envoy active config의 전송 보호만 노출하는 읽기 전용 관측."""
import datetime
import ipaddress
import json
import socket
import ssl
import urllib.request

MAX_CONFIG_BYTES = 1048576


def _check(route, result, reason, observed_at):
    return {"id": route, "result": result, "reason": reason,
            "observed_at": observed_at, "source": "TLS_PROBE"}


def _clusters(payload):
    found = {}
    for config in payload.get("configs", []):
        kind = str(config.get("@type", ""))
        if kind.endswith("ClustersConfigDump.DynamicCluster"):
            entries = [config]
        elif kind.endswith("ClustersConfigDump"):
            entries = config.get("dynamic_active_clusters", []) + config.get("static_clusters", [])
        else:
            continue
        for entry in entries:
            cluster = entry.get("cluster", {})
            name = cluster.get("name")
            if isinstance(name, str):
                found[name] = cluster
    return found


def _probe(cluster, context, sni):
    endpoints = cluster.get("load_assignment", {}).get("endpoints", [])
    peers = [item.get("endpoint", {}).get("address", {}).get("socket_address", {})
             for group in endpoints for item in group.get("lb_endpoints", [])]
    if not peers or len(peers) > 8:
        return "UNKNOWN", "UPSTREAM_ENDPOINT_MISSING"
    # 모든 실제 peer를 확인한다. 첫 성공으로 다른 경로의 실패를 숨기지 않는다.
    for peer in peers:
        host, port = peer.get("address"), peer.get("port_value")
        if not isinstance(host, str) or not isinstance(port, int) or not 1 <= port <= 65535:
            return "UNKNOWN", "UPSTREAM_ENDPOINT_INVALID"
        try:
            addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
            for address in addresses:
                ip = ipaddress.ip_address(address[4][0])
                ip = getattr(ip, "ipv4_mapped", None) or ip
                if ip.is_loopback or ip.is_link_local or ip.is_unspecified or ip.is_multicast or ip.is_reserved:
                    return "UNKNOWN", "UPSTREAM_ADDRESS_FORBIDDEN"
            if not addresses:
                return "UNKNOWN", "UPSTREAM_UNREACHABLE"
            with socket.create_connection((addresses[0][4][0], port), timeout=3) as sock:
                with context.wrap_socket(sock, server_hostname=sni) as tls:
                    if tls.version() not in ("TLSv1.2", "TLSv1.3"):
                        return "WARN", "TLS_VERSION_TOO_LOW"
        except ssl.SSLError:
            return "WARN", "TLS_VERIFICATION_FAILED"
        except (OSError, ValueError):
            return "UNKNOWN", "TLS_PROBE_UNAVAILABLE"
    return "PASS", "TLS_SESSION_VERIFIED"


def summarize(payload, routes, observed_at, probe=_probe):
    result = []
    clusters = _clusters(payload)
    for route in routes:
        cluster = clusters.get(route)
        if cluster is None:
            result.append(_check(route, "UNKNOWN", "ACTIVE_CLUSTER_MISSING", observed_at))
            continue
        if cluster.get("transport_socket_matches"):
            result.append(_check(route, "UNKNOWN", "CONDITIONAL_TRANSPORT", observed_at))
            continue
        transport = cluster.get("transport_socket")
        if not transport:
            status, reason = _plaintext(cluster)
            result.append(_check(route, status, reason, observed_at))
            continue
        if transport.get("name") != "envoy.transport_sockets.tls":
            result.append(_check(route, "UNKNOWN", "TRANSPORT_UNSUPPORTED", observed_at))
            continue
        config = transport.get("typed_config", {})
        common = config.get("common_tls_context", {})
        validation = common.get("validation_context", {})
        sni = config.get("sni")
        minimum = common.get("tls_params", {}).get("tls_minimum_protocol_version")
        if minimum not in (None, "TLS_AUTO", "TLSv1_2", "TLSv1_3"):
            result.append(_check(route, "WARN", "TLS_MINIMUM_TOO_LOW", observed_at))
            continue
        if common.get("combined_validation_context") or common.get("tls_certificate_sds_secret_configs"):
            result.append(_check(route, "UNKNOWN", "TLS_CONTEXT_UNRESOLVED", observed_at))
            continue
        if not validation.get("trusted_ca") or not validation.get("match_typed_subject_alt_names") or not sni:
            result.append(_check(route, "WARN", "TLS_PEER_VALIDATION_DISABLED", observed_at))
            continue
        if validation.get("trust_chain_verification", "VERIFY_TRUST_CHAIN") != "VERIFY_TRUST_CHAIN":
            result.append(_check(route, "WARN", "TLS_PEER_VALIDATION_DISABLED", observed_at))
            continue
        if validation.get("trusted_ca") != {"filename": "/etc/ssl/certs/ca-certificates.crt"}:
            result.append(_check(route, "UNKNOWN", "TLS_TRUST_STORE_UNSUPPORTED", observed_at))
            continue
        matchers = validation.get("match_typed_subject_alt_names", [])
        accepted = {sni, "*." + sni.split(".", 1)[1]} if "." in sni else {sni}
        if not matchers or any(
            m.get("san_type") != "DNS"
            or set(m.get("matcher", {})) != {"exact"}
            or m["matcher"]["exact"] not in accepted
            for m in matchers
        ):
            result.append(_check(route, "UNKNOWN", "TLS_PEER_MATCH_UNSUPPORTED", observed_at))
            continue
        try:
            # 원문의 임의 파일 경로를 읽지 않는다. 공개 CA를 사용하는 경로만 자동 접속 검증.
            context = ssl.create_default_context()
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            status, reason = probe(cluster, context, sni)
        except (OSError, ValueError, ssl.SSLError):
            status, reason = "UNKNOWN", "TLS_PROBE_UNAVAILABLE"
        result.append(_check(route, status, reason, observed_at))
    return result


def _plaintext(cluster):
    peers = [item.get("endpoint", {}).get("address", {}).get("socket_address", {})
             for group in cluster.get("load_assignment", {}).get("endpoints", [])
             for item in group.get("lb_endpoints", [])]
    if not peers or len(peers) > 8:
        return "UNKNOWN", "UPSTREAM_ENDPOINT_MISSING"
    public = False
    try:
        for peer in peers:
            host, port = peer.get("address"), peer.get("port_value")
            if not isinstance(host, str) or type(port) is not int or not 1 <= port <= 65535:
                return "UNKNOWN", "UPSTREAM_ENDPOINT_INVALID"
            addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
            if not addresses:
                return "UNKNOWN", "UPSTREAM_UNREACHABLE"
            for address in addresses:
                ip = ipaddress.ip_address(address[4][0])
                ip = getattr(ip, "ipv4_mapped", None) or ip
                if ip.is_loopback or ip.is_link_local or ip.is_unspecified or ip.is_multicast or ip.is_reserved:
                    return "UNKNOWN", "UPSTREAM_ADDRESS_FORBIDDEN"
                public = public or ip.is_global
    except (OSError, ValueError):
        return "UNKNOWN", "UPSTREAM_UNREACHABLE"
    return ("FAIL", "PUBLIC_PLAINTEXT_TRANSPORT") if public else ("WARN", "PLAINTEXT_TRANSPORT")


def collect(admin_url, routes, revision="v1"):
    observed_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    try:
        with urllib.request.urlopen(admin_url + "/config_dump?resource=dynamic_active_clusters", timeout=3) as response:
            raw = response.read(MAX_CONFIG_BYTES + 1)
        if len(raw) > MAX_CONFIG_BYTES:
            raise ValueError("config exceeds budget")
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise ValueError("invalid config")
        # resource 필터로 cluster만 읽는다. SecretsConfigDump는 요청하지 않는다.
        checks = summarize(payload, routes, observed_at)
    except (OSError, ValueError, TypeError, AttributeError):
        checks = [_check(route, "UNKNOWN", "ENVOY_OBSERVATION_UNAVAILABLE", observed_at)
                  for route in routes]
    return {"schema_version": 1, "revision": revision,
            "observed_at": observed_at, "checks": checks}
