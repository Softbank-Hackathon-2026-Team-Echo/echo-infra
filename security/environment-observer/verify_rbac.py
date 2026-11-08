"""Disposable local k3s: actual read, patch and denied mutations. No current context."""
import json
from pathlib import Path
import subprocess
import time
import urllib.request

NAME = "echo-secu131-runtime-k3s"
ROOT = Path(__file__).resolve().parent

def run(*args, data=None, check=True):
    result = subprocess.run(args, input=data, text=True, capture_output=True, timeout=40)
    if check and result.returncode:
        raise AssertionError(result.stderr[:250])
    return result

def kube(*args, **kwargs):
    return run("docker", "exec", "-i", NAME, "kubectl", *args, **kwargs)

def apply(path):
    kube("apply", "-f", "-", data=path.read_text().replace("REPLACE_WITH_DEDICATED_GSA", "reader@example.iam.gserviceaccount.com"))

try:
    run("docker", "run", "-d", "--privileged", "--name", NAME, "-p", "127.0.0.1::18080", "rancher/k3s:v1.33.4-k3s1",
        "server", "--disable", "traefik", "--disable", "metrics-server", "--disable", "servicelb")
    for _ in range(90):
        if kube("get", "--raw", "/readyz", check=False).returncode == 0:
            break
        time.sleep(1)
    else:
        raise AssertionError("k3s not ready")
    kube("create", "namespace", "echo-security")
    # Only the namespace, SA, ConfigMap and RBAC; never schedule an unconfigured observer image.
    manifest = (ROOT/"manifests.yaml").read_text().split("---\napiVersion: batch/v1")[0]
    kube("apply", "-f", "-", data=manifest)
    apply(ROOT/"reader-rbac.yaml")
    apply(ROOT/"reader-bindings.example.yaml")
    identities = [
        ["--as=system:serviceaccount:echo-security:security-reader"],
        ["--as=reader@example.iam.gserviceaccount.com"],
        ["--as=aws-role", "--as-group=echo-security-reader"],
    ]
    checks = 0
    for identity in identities:
        for verb, resource, namespace, allowed in [
            ("list", "clusterrolebindings", None, True),
            ("get", "configmaps/transport-evidence", "echo-security", True),
            ("get", "secrets", "echo-security", False),
            ("get", "configmaps/other", "echo-security", False),
            ("patch", "configmaps/transport-evidence", "echo-security", False),
            ("create", "jobs", "echo-security", False),
            ("create", "pods/exec", "echo-security", False),
            ("patch", "deployments", "echo-security", False),
            ("impersonate", "serviceaccounts", "echo-security", False),
        ]:
            args = ["auth", "can-i", verb, resource, *identity]
            if namespace:
                args += ["-n", namespace]
            result = kube(*args, check=False)
            assert result.stdout.strip() == ("yes" if allowed else "no"), args
            checks += 1
        kube("get", "configmap", "transport-evidence", "-n", "echo-security", *identity)
        denied = kube("patch", "configmap", "transport-evidence", "-n", "echo-security",
                      "--type=merge", "-p", '{"data":{"forged":"true"}}', *identity, check=False)
        assert denied.returncode and "Forbidden" in denied.stderr
        checks += 2
    observer = "--as=system:serviceaccount:echo-security:transport-observer"
    # kubectl patch first GETs the resource; the observer intentionally has PATCH only.
    # Send its real PATCH via an impersonated local API proxy instead.
    run("docker", "exec", "-d", NAME, "kubectl", "proxy", "--port=18080", "--address=0.0.0.0", observer)
    time.sleep(1)
    address = run("docker", "port", NAME, "18080/tcp").stdout.strip()
    request = urllib.request.Request(
        "http://" + address + "/api/v1/namespaces/echo-security/configmaps/transport-evidence",
        data=b'{"data":{"fixture":"observed"}}', method="PATCH",
        headers={"Content-Type":"application/merge-patch+json"})
    with urllib.request.urlopen(request, timeout=5) as response:
        assert response.status == 200
    for resource in ("secrets", "configmaps/other"):
        assert kube("auth", "can-i", "get", resource, "-n", "echo-security", observer, check=False).stdout.strip() == "no"
        checks += 1
    print(json.dumps({"k3s": "PASS", "checks": checks + 1, "cloudFederation": "NOT_TESTED"}))
finally:
    run("docker", "rm", "-f", "-v", NAME, check=False)
