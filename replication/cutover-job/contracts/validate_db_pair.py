"""Offline contract validator only. Does not access Kubernetes or databases."""

import hashlib
import json
import re
from typing import Any
from uuid import UUID

ENV_NAMES = frozenset(
    {
        "KIND",
        "PLAN_ID",
        "ALLOW_PROMOTE",
        "SOURCE_DB",
        "TARGET_DB",
        "EXPECTED_WRITER_DB",
        "DB_PAIR_CONTRACT_VERSION",
        "DB_PAIR_REGISTRY_SHA256",
        "ORGANIZATION_ID",
        "SERVICE_ID",
        "SOURCE_ENVIRONMENT_ID",
        "TARGET_ENVIRONMENT_ID",
        "SOURCE_DEPLOYMENT_ID",
        "TARGET_DEPLOYMENT_ID",
    }
)
UUID_NAMES = (
    "PLAN_ID",
    "ORGANIZATION_ID",
    "SERVICE_ID",
    "SOURCE_ENVIRONMENT_ID",
    "TARGET_ENVIRONMENT_ID",
    "SOURCE_DEPLOYMENT_ID",
    "TARGET_DEPLOYMENT_ID",
)


def validate_job_contract(
    job: dict[str, Any], registry: dict[str, Any], observed_writer: str
) -> None:
    """Validate a sanitized Job fixture, not admission or a live writer attestation."""

    def require(condition: bool, reason: str) -> None:
        if not condition:
            raise ValueError(reason)

    try:
        pod = job["spec"]["template"]["spec"]
        require(job["kind"] == "Job" and job["metadata"]["namespace"] == "echo-ops", "JOB_SCOPE")
        containers = pod["containers"]
        require(
            len(containers) == 1 and pod["serviceAccountName"] == "echo-cutover", "JOB_TEMPLATE"
        )
        container = containers[0]
        require(
            not any(key in container for key in ("command", "args", "envFrom", "volumeMounts"))
            and "volumes" not in pod,
            "JOB_INJECTION",
        )
        require(
            bool(re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", container["image"])), "IMAGE_DIGEST"
        )
        entries = container["env"]
        require(all(set(entry) == {"name", "value"} for entry in entries), "ENV_INJECTION")
        env = {entry["name"]: entry["value"] for entry in entries}
        require(len(env) == len(entries) and set(env) == ENV_NAMES, "ENV_ALLOWLIST")
        require(all(isinstance(value, str) for value in env.values()), "ENV_VALUE")
        for name in UUID_NAMES:
            require(str(UUID(env[name])) == env[name], "UUID_FORMAT")
        require(env["DB_PAIR_CONTRACT_VERSION"] == "db-pair/v1", "CONTRACT_VERSION")
        require(
            bool(re.fullmatch(r"[0-9a-f]{64}", env["DB_PAIR_REGISTRY_SHA256"])), "REGISTRY_HASH"
        )
        require(env["SOURCE_DB"] != env["TARGET_DB"], "SAME_DATABASE")
        require(
            env["DB_PAIR_REGISTRY_SHA256"] == registry["registry_sha256"], "REGISTRY_HASH_MISMATCH"
        )
        digest = registry["registry_sha256"]
        registry = registry["configuration"]
        canonical = json.dumps(registry, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        require(
            hashlib.sha256(canonical.encode()).hexdigest() == digest, "REGISTRY_CONTENT_CHANGED"
        )
        databases = registry["databases"]
        by_id = {entry["id"]: entry for entry in databases}
        require(len(by_id) == len(databases), "DUPLICATE_DB")
        require(env["SOURCE_DB"] in by_id and env["TARGET_DB"] in by_id, "UNREGISTERED_DATABASE")
        source, target = by_id[env["SOURCE_DB"]], by_id[env["TARGET_DB"]]
        for side, db in (("SOURCE", source), ("TARGET", target)):
            for key, field in (
                ("ORGANIZATION_ID", "organization_id"),
                ("SERVICE_ID", "service_id"),
                (f"{side}_ENVIRONMENT_ID", "environment_id"),
                (f"{side}_DEPLOYMENT_ID", "deployment_id"),
            ):
                require(env[key] == db[field], "DB_SCOPE_BINDING")
        matches = [
            pair
            for pair in registry["pairs"]
            if pair["source_db_id"] == source["id"] and pair["target_db_id"] == target["id"]
        ]
        require(len(matches) == 1 and matches[0]["adapter"] == "legacy-ab-v1", "PAIR_UNSUPPORTED")
        slots = (source["adapter_slot"], target["adapter_slot"])
        require(source["database_name"] == target["database_name"] == "app", "DB_ADAPTER")
        require(slots in (("A", "B"), ("B", "A")), "DB_ADAPTER")
        expected_kind = "cutover" if slots == ("A", "B") else "rollback"
        require(
            env["KIND"] == expected_kind or (env["KIND"] == "promote" and slots == ("A", "B")),
            "KIND_DIRECTION",
        )
        require(env["ALLOW_PROMOTE"] in ("true", "false"), "PROMOTE_VALUE")
        require(env["ALLOW_PROMOTE"] == "false" or slots == ("A", "B"), "PROMOTE_DIRECTION")
        require(observed_writer == env["EXPECTED_WRITER_DB"] == source["id"], "WRITER_MISMATCH")
    except (KeyError, TypeError, IndexError) as exc:
        raise ValueError("CONTRACT_STRUCTURE") from exc
