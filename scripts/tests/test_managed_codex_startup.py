"""Actual native startup parser and guarded OS pipes; no coding provider or model."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[2]
MODULE_CACHE = None
NONCE = "00000000-0000-4000-8000-000000000001"
PROFILE_SHA = "5dd7978748e6bee503ee1ccf593181fc46c058843fc0943daee191898885ca8f"
CATALOG_SHA = "c21244950ae26f4e029cf91d9c3d85ff1691c83292ab91627bb528cfe0d7e0a9"
FEATURES = [
    "multi_agent_v2", "goals", "memories", "guardian_approval", "sleep_tool",
    "code_mode", "code_mode_only", "code_mode_prewarm", "hooks",
    "web_search_request", "web_search_cached", "image_generation", "apps", "plugins",
    "skill_mcp_dependency_install", "skill_search",
]


def profile():
    return json.loads((ROOT / "scripts/tests/fixtures/managed_codex_profile.json").read_bytes())


def descriptor():
    return {
        "method": "cmux/codex/descriptor",
        "params": {
            "bootNonce": NONCE, "cwd": "/controlled/project", "storeId": "cmux-" + NONCE,
            "profileDigest": PROFILE_SHA, "profile": profile(),
            "effective": {
                "model": "gpt-5.5", "modelProviderId": "openai", "ephemeral": True,
                "agentsEnabled": False, "approvalPolicy": "never", "webSearch": "disabled",
                "features": {key: False for key in FEATURES},
                "toolModesByAvailability": [["direct", "direct"], ["direct", "direct"]],
                "catalogSha256": CATALOG_SHA, "modelExperimentalTools": [],
                "modelMultiAgentVersion": "disabled", "mcpServerCount": 0, "legacyNotifyCount": 0,
                "orchestratorSkillsEnabled": False, "orchestratorMcpEnabled": False,
                "generateMemories": False, "useMemories": False, "dedicatedMemoryTools": False,
                "historyNotes": False, "threadStore": {"type": "inMemory", "id": "cmux-" + NONCE},
            },
        },
    }


def ready():
    return {
        "thread": {
            "id": "actual-controlled-sdk-thread", "sessionId": "actual-controlled-sdk-session",
            "cwd": "/controlled/project", "modelProvider": "openai", "ephemeral": True,
            "preview": "", "createdAt": 0, "updatedAt": 0,
            "status": {"type": "idle"}, "source": "cli", "cliVersion": "0.154.0", "turns": [],
            "forkedFromId": None, "parentThreadId": None, "agentNickname": None, "agentRole": None,
        },
        "model": "gpt-5.5", "modelProvider": "openai", "serviceTier": None,
        "cwd": "/controlled/project", "runtimeWorkspaceRoots": [], "instructionSources": [],
        "approvalPolicy": "never", "approvalsReviewer": "user",
        "sandbox": {"type": "dangerFullAccess"}, "activePermissionProfile": None,
        "reasoningEffort": None,
        "multiAgentMode": "explicitRequestOnly",
    }


def at(value, path, replacement):
    current = value
    for key in path[:-1]:
        current = current[key]
    current[path[-1]] = replacement
    return value


class ManagedCodexStartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        manifest = json.dumps(profile(), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        if hashlib.sha256(manifest).hexdigest() != PROFILE_SHA:
            raise RuntimeError("Fixture profile differs from the actual pinned helper output")
        cls.build = Path(tempfile.mkdtemp(prefix="cmux-managed-codex-startup-source-"))
        print(f"Retained exact-source startup fixture: {cls.build}", file=sys.stderr)
        flags = ["swiftc", "-swift-version", "6", "-gnone", "-module-cache-path",
                 str(MODULE_CACHE or cls.build / "cache")]
        control = ROOT / "Packages/macOS/CmuxControlSocket/Sources/CmuxControlSocket/Shepherd"
        commands = [
            flags + ["-emit-library", "-emit-module", "-module-name", "CmuxControlSocket",
                     str(control / "ShepherdManagedPipeWriter.swift"),
                     "-o", str(cls.build / "libCmuxControlSocket.dylib")],
            flags + ["-parse-as-library", "-I", str(cls.build), "-L", str(cls.build),
                     "-lCmuxControlSocket", "-Xlinker", "-rpath", "-Xlinker", str(cls.build),
                     *(str(ROOT / "Sources/Panels" / name) for name in (
                         "AgentSessionManagedJSON.swift", "CodexManagedStreamDecoder.swift",
                         "CodexManagedStartup.swift")),
                     str(ROOT / "scripts/tests/fixtures/managed_codex_startup.swift"),
                     "-o", str(cls.build / "startup")],
        ]
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
        cls.executable = cls.build / "startup"

    def startup(self, value=None, **options):
        request = {"nonce": NONCE, "cwd": "/controlled/project",
                   "descriptor": descriptor() if value is None else value, "ready": ready(), **options}
        request.setdefault("wire", json.dumps(
            request["descriptor"], ensure_ascii=False, separators=(",", ":")) + "\n")
        result = subprocess.run(
            [str(self.executable)], input=json.dumps(request, ensure_ascii=False),
            capture_output=True, text=True, timeout=6)
        self.assertEqual(result.returncode, 0, result.stderr)
        decoded = json.loads(result.stdout)
        actual_wire = b"\xff\n" if request.get("invalidUTF8") else request["wire"].encode()
        self.assertEqual(decoded["descriptorWireSHA256"], hashlib.sha256(actual_wire).hexdigest(),
                         "Fixture changed descriptor bytes before the actual parser")
        return decoded

    def test_exact_descriptor_initializes_only_the_bound_birth_and_real_thread(self):
        result = self.startup()
        self.assertEqual(result["failure"], "", "CMUX_NATIVE_CODEX_STARTUP_UNAVAILABLE: " + str(result))
        frame = result["initializeFrame"]
        self.assertEqual(set(frame), {"id", "method", "params"})
        self.assertEqual(frame["method"], "cmux/initialize")
        self.assertEqual(frame["params"], {"bootNonce": NONCE, "profileDigest": PROFILE_SHA})
        self.assertIsInstance(frame["id"], str)
        self.assertFalse(result["readyBeforeWrite"])
        self.assertTrue(result["initializeWritten"])
        self.assertTrue(result["ready"])
        self.assertEqual(result["threadID"], "actual-controlled-sdk-thread")

    def test_early_ready_waits_for_the_actual_initialize_write_witness(self):
        result = self.startup(readyBeforeWritten=True)
        self.assertFalse(result["readyBeforeWrite"])
        self.assertTrue(result["ready"], "CMUX_NATIVE_CODEX_EARLY_READY_NOT_JOINED: " + str(result))
        self.assertTrue(result["initializeWritten"])

    def test_source_catalog_schema_and_profile_changes_never_initialize(self):
        for path, value in [
            (["profile", "upstreamCommit"], "0" * 40),
            (["profile", "integrationPatchSha256"], "0" * 64),
            (["profile", "catalogSha256"], "0" * 64),
            (["profile", "commandSchemaSha256"], "0" * 64),
            (["profile", "privateBridgeVersion"], 1.0),
            (["profile", "privateBridgeVersion"], True),
            (["profile", "startupOptions", "channelCapacity"], 1.0),
            (["profile", "commandAuthority", "rpcActivationAllowed"], True),
            (["profileDigest"], "0" * 64),
        ]:
            with self.subTest(path=path, value=value):
                item = descriptor()
                at(item["params"], path, value)
                result = self.startup(item)
                self.assertFalse(result["ready"], result)
                self.assertEqual(result["initializeFrame"], {})
                self.assertTrue(result["failure"])

    def test_every_effective_policy_field_is_checked_before_initialization(self):
        effective = descriptor()["params"]["effective"]
        bad_values = {
            "model": "another-model", "modelProviderId": "other", "ephemeral": False,
            "agentsEnabled": True, "approvalPolicy": "on-request", "webSearch": "live",
            "features": {}, "toolModesByAvailability": [["code_mode", "direct"], ["direct", "direct"]],
            "catalogSha256": "0" * 64, "modelExperimentalTools": ["shell"],
            "modelMultiAgentVersion": "v2", "mcpServerCount": 1, "legacyNotifyCount": 1,
            "orchestratorSkillsEnabled": True, "orchestratorMcpEnabled": True,
            "generateMemories": True, "useMemories": True, "dedicatedMemoryTools": True,
            "historyNotes": True, "threadStore": {"type": "local"},
        }
        self.assertEqual(set(bad_values), set(effective))
        for key, value in bad_values.items():
            with self.subTest(field=key):
                item = descriptor()
                item["params"]["effective"][key] = value
                result = self.startup(item)
                self.assertEqual(result["initializeFrame"], {})
                self.assertTrue(result["failure"])

    def test_every_closed_feature_and_missing_or_extra_policy_value_refuses(self):
        for key in FEATURES:
            item = descriptor()
            item["params"]["effective"]["features"][key] = True
            with self.subTest(feature=key):
                self.assertEqual(self.startup(item)["initializeFrame"], {})
        for key in descriptor()["params"]["effective"]:
            item = descriptor()
            del item["params"]["effective"][key]
            with self.subTest(missing=key):
                self.assertEqual(self.startup(item)["initializeFrame"], {})
        item = descriptor()
        item["params"]["effective"]["extra"] = False
        self.assertEqual(self.startup(item)["initializeFrame"], {})

    def test_nonce_cwd_store_and_envelope_drift_cannot_bind(self):
        for key, value in [
            ("bootNonce", str(uuid.uuid4())), ("bootNonce", NONCE.upper().replace("001", "00A")),
            ("cwd", "/controlled/project/."), ("cwd", "/another/project"),
            ("storeId", "another-store"),
        ]:
            item = descriptor()
            item["params"][key] = value
            with self.subTest(field=key):
                result = self.startup(item)
                self.assertEqual(result["initializeFrame"], {})
                self.assertFalse(result["ready"])
        for key, value in [("id", "not-a-notification"), ("extra", None)]:
            item = descriptor()
            item[key] = value
            self.assertEqual(self.startup(item)["initializeFrame"], {})

    def test_boolean_number_and_nested_policy_coercions_refuse(self):
        for path, value in [
            (["effective", "ephemeral"], 1), (["effective", "mcpServerCount"], False),
            (["effective", "legacyNotifyCount"], 0.0),
            (["effective", "features", "hooks"], 0),
            (["effective", "threadStore", "id"], "cmux-" + str(uuid.uuid4())),
        ]:
            item = descriptor()
            at(item["params"], path, value)
            with self.subTest(path=path):
                result = self.startup(item)
                self.assertEqual(result["initializeFrame"], {}, result)

    def test_duplicate_keys_invalid_utf8_and_truncated_descriptors_hold(self):
        good = json.dumps(descriptor(), separators=(",", ":")) + "\n"
        for wire in [
            good.replace('"method":', '"method":"forged","method":', 1),
            good.replace('"ephemeral":true', '"ephemeral":false,"ephemeral":true'),
            good[:-1], "[]\n", '{"method":"cmux/codex/descriptor"}\n',
        ]:
            with self.subTest(wire=wire[:80]):
                result = self.startup(wire=wire, eof=True)
                self.assertFalse(result["ready"])
                self.assertEqual(result["initializeFrame"], {})
                self.assertTrue(result["failure"])
        result = self.startup(invalidUTF8=True)
        self.assertEqual(result["initializeFrame"], {})
        self.assertTrue(result["failure"])

    def test_coalesced_duplicate_descriptor_or_preinitialize_work_writes_nothing(self):
        one = json.dumps(descriptor()) + "\n"
        for tail in [one, '{"method":"turn/started","params":{}}\n']:
            result = self.startup(wire=one + tail)
            self.assertEqual(result["initializeFrame"], {})
            self.assertTrue(result["failure"])

    def test_refused_initialize_write_cannot_create_readiness(self):
        result = self.startup(refuseWrite=True)
        self.assertFalse(result["initializeWritten"])
        self.assertFalse(result["ready"])

    def test_ready_identity_or_policy_drift_and_foreign_ack_hold(self):
        for path, value in [
            (["thread", "id"], ""), (["thread", "id"], "x" * 129),
            (["thread", "cwd"], "/other"), (["thread", "modelProvider"], "other"),
            (["thread", "ephemeral"], False), (["cwd"], "/other"),
            (["thread", "forkedFromId"], "previous-thread"),
            (["thread", "parentThreadId"], "parent-thread"), (["thread", "agentRole"], "subagent"),
            (["thread", "unknownField"], None),
            (["model"], "other"), (["modelProvider"], "other"),
            (["approvalPolicy"], "on-request"), (["sandbox"], {"type": "workspaceWrite"}),
        ]:
            response = ready()
            at(response, path, value)
            with self.subTest(path=path):
                result = self.startup(ready=response)
                self.assertFalse(result["ready"])
                self.assertTrue(result["failure"])
        result = self.startup(foreignReadyID=True)
        self.assertFalse(result["ready"])
        self.assertTrue(result["failure"])

    def test_fragmented_bytes_preserve_the_same_exact_descriptor_binding(self):
        result = self.startup(fragmentBytes=1)
        self.assertTrue(result["ready"], "CMUX_NATIVE_CODEX_FRAGMENTED_STARTUP_UNAVAILABLE: " + str(result))
        self.assertEqual(result["threadID"], "actual-controlled-sdk-thread")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--module-cache-path", type=Path)
    args, remaining = parser.parse_known_args()
    MODULE_CACHE = args.module_cache_path
    unittest.main(argv=[sys.argv[0], *remaining])
