import importlib.util
import json
import unittest
from copy import deepcopy
from pathlib import Path
from uuid import UUID

ROOT = Path(__file__).resolve().parents[1]


class PairContractTest(unittest.TestCase):
    def test_validator_rejects_reversed_pair_before_side_effect_hook(self):
        spec = importlib.util.spec_from_file_location(
            "pair_contract", ROOT / "contracts" / "validate_db_pair.py"
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest = json.loads((ROOT / "tests" / "fixtures" / "db-pair-job.json").read_text())
        registry = json.loads((ROOT / "tests" / "fixtures" / "db-pair-registry.json").read_text())
        module.validate_job_contract(manifest, registry, "aws-a-app")
        env = manifest["spec"]["template"]["spec"]["containers"][0]["env"]
        for item in env:
            if item["name"] == "SOURCE_DB":
                item["value"] = "gcp-b-app"
        calls = []
        with self.assertRaises(ValueError):
            module.validate_job_contract(manifest, registry, "aws-a-app")
            calls.append("PAUSE")
        self.assertEqual(calls, [])

    def test_rejects_static_contract_mutations(self):
        spec = importlib.util.spec_from_file_location(
            "pair_contract", ROOT / "contracts" / "validate_db_pair.py"
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original = json.loads((ROOT / "tests" / "fixtures" / "db-pair-job.json").read_text())
        registry = json.loads((ROOT / "tests" / "fixtures" / "db-pair-registry.json").read_text())
        for name, value in [
            ("SOURCE_DB", "unknown"),
            ("TARGET_DB", "onprem-demo"),
            ("KIND", "rollback"),
            ("EXPECTED_WRITER_DB", "gcp-b-app"),
            ("DB_PAIR_CONTRACT_VERSION", "v0"),
            ("DB_PAIR_REGISTRY_SHA256", "f" * 64),
            ("ORGANIZATION_ID", str(UUID(int=999))),
            ("SERVICE_ID", str(UUID(int=999))),
            ("SOURCE_ENVIRONMENT_ID", str(UUID(int=999))),
            ("TARGET_DEPLOYMENT_ID", str(UUID(int=999))),
            ("ALLOW_PROMOTE", "yes"),
        ]:
            with self.subTest(name=name):
                job = deepcopy(original)
                for entry in job["spec"]["template"]["spec"]["containers"][0]["env"]:
                    if entry["name"] == name:
                        entry["value"] = value
                with self.assertRaises(ValueError):
                    module.validate_job_contract(job, registry, "aws-a-app")
        for key in ("command", "args", "envFrom", "volumeMounts"):
            with self.subTest(key=key):
                job = deepcopy(original)
                job["spec"]["template"]["spec"]["containers"][0][key] = []
                with self.assertRaises(ValueError):
                    module.validate_job_contract(job, registry, "aws-a-app")
        with self.assertRaises(ValueError):
            module.validate_job_contract(original, registry, "gcp-b-app")

    def test_registry_contents_cannot_change_under_the_same_digest(self):
        spec = importlib.util.spec_from_file_location(
            "pair_contract", ROOT / "contracts" / "validate_db_pair.py"
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        job = json.loads((ROOT / "tests" / "fixtures" / "db-pair-job.json").read_text())
        registry = json.loads((ROOT / "tests" / "fixtures" / "db-pair-registry.json").read_text())
        registry["configuration"]["revision"] = "changed-without-new-plan"
        with self.assertRaisesRegex(ValueError, "REGISTRY_CONTENT_CHANGED"):
            module.validate_job_contract(job, registry, "aws-a-app")


if __name__ == "__main__":
    unittest.main()
