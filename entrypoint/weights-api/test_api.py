"""HTTP regression for the existing weights API and the separate observation token."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location("weights_under_test", Path(__file__).with_name("app.py"))
app = importlib.util.module_from_spec(spec)
with patch.dict(os.environ, {"UPSTREAMS":"aws=192.0.2.1:80,gcp=192.0.2.2:80", "DEFAULT_WEIGHTS":"aws=100,gcp=0"}):
    spec.loader.exec_module(app)


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.tokens = patch.multiple(app, TOKEN="write-test-token", SECURITY_READ_TOKEN="read-test-token",
                                     ENVS=["aws","gcp"], CURRENT={"aws":100,"gcp":0})
        self.tokens.start()
        self.server = app.ThreadingHTTPServer(("127.0.0.1",0),app.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:" + str(self.server.server_port)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tokens.stop()

    def request(self,path,token=None,method="GET",body=None):
        headers = {"Authorization":"Bearer "+token} if token else {}
        request = urllib.request.Request(self.url+path,method=method,headers=headers,
                                         data=json.dumps(body).encode() if body is not None else None)
        try:
            with urllib.request.urlopen(request,timeout=3) as response:
                return response.status,json.load(response)
        except urllib.error.HTTPError as error:
            with error:
                return error.code,json.load(error)

    def test_read_api_requires_separate_token(self):
        with patch.object(app,"collect_security_transport",return_value={"checks":[]}) as collect:
            self.assertEqual(self.request("/security/transport")[0],401)
            self.assertEqual(self.request("/security/transport","write-test-token")[0],401)
            collect.assert_not_called()
            self.assertEqual(self.request("/security/transport","read-test-token")[0],200)
            collect.assert_called_once()

    def test_read_token_cannot_change_weights(self):
        with patch.object(app,"apply_weights") as apply:
            self.assertEqual(self.request("/weights","read-test-token","PUT",{"aws":0,"gcp":100})[0],401)
            apply.assert_not_called()

    def test_existing_health_weights_write_remain_available(self):
        self.assertEqual(self.request("/health"),(200,{"ready":True}))
        self.assertEqual(self.request("/weights","write-test-token"),(200,{"aws":100,"gcp":0}))
        with patch.object(app,"apply_weights") as apply:
            self.assertEqual(self.request("/weights","write-test-token","PUT",{"aws":0,"gcp":100})[0],200)
            apply.assert_called_once_with({"aws":0,"gcp":100})

    def test_shared_token_disables_observation(self):
        with patch.object(app,"SECURITY_READ_TOKEN","write-test-token"):
            self.assertEqual(self.request("/security/transport","write-test-token")[0],503)

    def test_missing_read_token_disables_observation(self):
        with patch.object(app,"SECURITY_READ_TOKEN",""):
            self.assertEqual(self.request("/security/transport","read-test-token")[0],503)

    def test_service_observation_uses_registered_cluster_without_changing_weights(self):
        from test_service_routing import registration, A, B, AWS
        with tempfile.TemporaryDirectory() as directory:
            registry = Path(directory) / "registration.json"
            registry.write_text(json.dumps(registration()))
            store = app.ServiceRouteStore(directory, str(registry))
            store.seed()
            before = {sid: store.get(sid, e["publicHost"]) for sid, e in store.registry.items()}
            with patch.multiple(app, SERVICE_ROUTING_ENABLED=True, SCOPED_STORE=store):
                with patch.object(app, "collect_security_transport", return_value={"checks": []}) as collect:
                    self.assertEqual(self.request("/security/transport", "read-test-token")[0], 400)
                    self.assertEqual(self.request("/security/transport?route=aws", "read-test-token")[0], 404)
                    for sid in (A, B):
                        route = app.cluster_id(sid, AWS)
                        self.assertEqual(self.request("/security/transport?route=" + route, "read-test-token")[0], 200)
                        self.assertEqual(collect.call_args.args[1], [route])
                    self.assertEqual(self.request("/security/transport?route=aws&route=gcp", "read-test-token")[0], 400)
                for sid, entry in store.registry.items():
                    self.assertEqual(store.get(sid, entry["publicHost"]), before[sid])
                path = "/v1/services/" + A + "/weights?publicHost=a.echo.test"
                self.assertEqual(self.request(path, "read-test-token", "PUT", {})[0], 401)
