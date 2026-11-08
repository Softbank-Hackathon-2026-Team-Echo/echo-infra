"""Local Envoy 1.39.6 / current routing / TLS integration, isolated from production."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

PREFIX = "echo-secu131-envoy-check"
SID = "00000000-0000-0000-0000-000000000001"
EIDS = ["10000000-0000-0000-0000-00000000000" + str(n) for n in (1, 2, 3)]


def run(*args, ok=True):
    value = subprocess.run(args, text=True, capture_output=True, timeout=30)
    if ok and value.returncode:
        raise AssertionError("fixture failed: " + args[0] + " " + value.stderr[:300])
    return value.stdout.strip()


def wait(call, expected):
    last = None
    for _ in range(70):
        try:
            last = call()
            if expected(last):
                return last
        except Exception as error:
            last = type(error).__name__
        time.sleep(.2)
    raise AssertionError("fixture did not converge: " + str(last))


with tempfile.TemporaryDirectory(prefix=PREFIX) as directory:
    root = Path(directory)
    os.chmod(root, 0o755)
    dynamic = root / "dynamic"
    dynamic.mkdir()
    os.chmod(dynamic, 0o777)
    run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-addext", "basicConstraints=critical,CA:TRUE",
        "-addext", "keyUsage=critical,keyCertSign,cRLSign",
        "-subj", "/CN=fixture-ca", "-keyout", str(root/"ca.key"), "-out", str(root/"ca.crt"))
    run("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
        "-subj", "/CN=tls.origin.test", "-keyout", str(root/"server.key"),
        "-out", str(root/"server.csr"))
    (root/"ext").write_text(
        "subjectAltName=DNS:tls.origin.test\nextendedKeyUsage=serverAuth\n"
        "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
        "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n"
    )
    run("openssl", "x509", "-req", "-in", str(root/"server.csr"), "-CA", str(root/"ca.crt"),
        "-CAkey", str(root/"ca.key"), "-CAcreateserial", "-days", "1",
        "-extfile", str(root/"ext"), "-out", str(root/"server.crt"))
    backend = """import http.server,ssl,threading
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200); self.end_headers(); self.wfile.write(b'fixture-ok')
 def log_message(self,*args): pass
plain=http.server.ThreadingHTTPServer(('0.0.0.0',8081),Handler)
threading.Thread(target=plain.serve_forever,daemon=True).start()
secure=http.server.ThreadingHTTPServer(('0.0.0.0',8883),Handler)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain('/fixture/server.crt','/fixture/server.key')
secure.socket=context.wrap_socket(secure.socket,server_side=True)
secure.serve_forever()
"""
    (root/"backend.py").write_text(backend)
    origins = [
        {"host":"plain.origin.test","port":8081},
        {"host":"tls.origin.test","port":8883,"tls":True},
        {"host":"wrong.origin.test","port":8883,"tls":True},
    ]
    (root/"registry.json").write_text(json.dumps({"services":[{
        "serviceId":SID, "publicHost":"a.echo.test",
        "environments":dict(zip(EIDS,origins)),
        "initialWeights":dict(zip(EIDS,[100,0,0]))
    }]}))
    def source(path):
        return {"resource_api_version":"V3","path_config_source":{
            "path":"/etc/envoy/dynamic/"+path,"watched_directory":{"path":"/etc/envoy/dynamic"}}}
    address = lambda port: {"socket_address":{"address":"0.0.0.0","port_value":port}}
    config = {
        "node":{"id":"local-security-test","cluster":"local-security-test"},
        "admin":{"address":address(9901)},
        "dynamic_resources":{"cds_config":source("clusters.yaml")},
        "static_resources":{"listeners":[{"name":"http","address":address(10000),
            "filter_chains":[{"filters":[{"name":"envoy.filters.network.http_connection_manager",
                "typed_config":{"@type":"type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
                    "stat_prefix":"ingress","rds":{"route_config_name":"echo_routes","config_source":source("routes.yaml")},
                    "http_filters":[{"name":"envoy.filters.http.router",
                        "typed_config":{"@type":"type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"}}]}}]}]}]}
    }
    (root/"envoy.json").write_text(json.dumps(config))
    for file in root.iterdir():
        if file.is_file():
            os.chmod(file,0o644)
    started = []
    try:
        run("docker","network","create","--internal",PREFIX)
        run("docker","run","--rm","-d","--name",PREFIX+"-origin","--network",PREFIX,
            "--network-alias","plain.origin.test","--network-alias","tls.origin.test","--network-alias","wrong.origin.test",
            "-v",directory+":/fixture:ro","--entrypoint","python3","echo-secu131-weights:test","/fixture/backend.py")
        started.append(PREFIX+"-origin")
        run("docker","run","--rm","-d","--name",PREFIX+"-weights","--network",PREFIX,
            "-e","UPSTREAMS=aws=plain.origin.test:8081,gcp=tls.origin.test:8883",
            "-e","DEFAULT_WEIGHTS=aws=100,gcp=0","-e","SERVICE_ROUTING_ENABLED=1",
            "-e","SERVICE_ROUTES_FILE=/fixture/registry.json",
            "-e","ENVOY_ADMIN=http://"+PREFIX+"-envoy:9901",
            "-e","WEIGHTS_TOKEN=local-write","-e","SECURITY_READ_TOKEN=local-read",
            "-v",directory+":/fixture:ro","-v",str(dynamic)+":/etc/envoy/dynamic",
            "-v",str(root/"ca.crt")+":/etc/ssl/certs/ca-certificates.crt:ro","echo-secu131-weights:test")
        started.append(PREFIX+"-weights")
        api = "http://127.0.0.1:8080"
        def request(path, token="local-read", body=None, base=api):
            client = """import sys,urllib.request
data=None if sys.argv[3]=='' else sys.argv[3].encode()
req=urllib.request.Request(sys.argv[1],data=data,headers={'Authorization':'Bearer '+sys.argv[2],
'Host':'a.echo.test','Content-Type':'application/json'},method='GET' if data is None else 'PUT')
with urllib.request.urlopen(req,timeout=5) as response: print(response.read().decode())
"""
            raw = run("docker","exec",PREFIX+"-weights","python3","-c",client,base+path,token,
                      "" if body is None else json.dumps(body))
            return json.loads(raw) if base==api else raw
        wait(lambda:request("/health"), lambda value: value.get("ready"))
        run("docker","run","--rm","-d","--name",PREFIX+"-envoy","--network",PREFIX,
            "-v",directory+":/fixture:ro",
            "-v",str(dynamic)+":/etc/envoy/dynamic:ro",
            "-v",str(root/"ca.crt")+":/etc/ssl/certs/ca-certificates.crt:ro",
            "envoyproxy/envoy:v1.39.6","envoy","-c","/fixture/envoy.json","--concurrency","1")
        started.append(PREFIX+"-envoy")
        proxy="http://"+PREFIX+"-envoy:10000"
        wait(lambda:request("/",base=proxy),lambda value:value=="fixture-ok")
        path="/v1/services/"+SID+"/weights?publicHost=a.echo.test"
        before=request(path,"local-write")
        checks=[]
        for eid, expected in zip(EIDS,("WARN","PASS","WARN")):
            cluster="svc_"+SID.replace("-","")+"_"+eid.replace("-","")
            value=wait(lambda:request("/security/transport?route="+cluster),
                       lambda value:value["checks"][0]["result"]==expected)
            checks.append(value["checks"][0])
        assert checks[2]["reason"]=="TLS_VERIFICATION_FAILED"
        assert request(path,"local-write")==before, "observation changed routing"
        changed=request(path,"local-write",{"publicHost":"a.echo.test",
            "expectedRevision":before["revision"],"weights":dict(zip(EIDS,[0,100,0]))})
        assert changed["revision"]==before["revision"]+1
        wait(lambda:request("/",base=proxy),lambda value:value=="fixture-ok")
        print(json.dumps({"envoy":"1.39.6","plainOrigin":"WARN","verifiedTls":"PASS",
            "wrongHostname":"WARN","observationPreservesWeights":"PASS","httpAndTlsTraffic":"PASS"}))
    finally:
        for container in reversed(started):
            run("docker","stop",container,ok=False)
        run("docker","network","rm",PREFIX,ok=False)
