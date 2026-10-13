#!/usr/bin/env python3
"""Offline guard regression tests; standard library and isolated fixtures only.

Run: python3 -B scripts/test_deployment_guards.py

The tested functions are extracted from the actual source AST. Neither service
module is imported. No models, network, launchctl, subprocesses, or real
LaunchAgents are used. Startup tests write only to temporary directories.
"""

import ast
from contextlib import redirect_stderr, redirect_stdout
import copy
import hashlib
import io
import json
from pathlib import Path
import plistlib
import re
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock


ROOT = Path(__file__).resolve().parents[1]
ENCODER_PATH = ROOT / "encoder.py"
MANAGER_PATH = ROOT / "scripts/manage.py"
SOURCES = {
    str(ENCODER_PATH): ENCODER_PATH.read_bytes(),
    str(MANAGER_PATH): MANAGER_PATH.read_bytes(),
}
SOURCE_HASHES = {name: hashlib.sha256(raw).hexdigest() for name, raw in SOURCES.items()}
SYNTHETIC_PRIVATE_VALUE = "SYNTHETIC-ONLY-DO-NOT-RETURN-RAW-JOB-TEXT"


def extract_functions(path, names, namespace):
    """Load only named function definitions, with all dependencies injected."""
    tree = ast.parse(SOURCES[str(path)], filename=str(path))
    definitions = {
        node.name: node for node in tree.body if isinstance(node, ast.FunctionDef)
    }
    missing = set(names) - definitions.keys()
    if missing:
        raise AssertionError(f"Expected patched functions are absent: {sorted(missing)}")
    selected = ast.Module(body=[definitions[name] for name in names], type_ignores=[])
    exec(compile(selected, str(path), "exec"), namespace)
    return namespace


class MemoryPath:
    """Minimal read-only path/file fixture for verify_model_files."""

    def __init__(self, files, name=""):
        self.files = files
        self.name = name

    def __truediv__(self, name):
        return MemoryPath(self.files, f"{self.name}/{name}".lstrip("/"))

    def read_bytes(self):
        if self.name not in self.files:
            raise FileNotFoundError(self.name)
        return self.files[self.name]

    def stat(self):
        return SimpleNamespace(st_size=len(self.read_bytes()))

    def open(self, mode):
        if mode != "rb":
            raise AssertionError("The integrity verifier must only read binary input")
        return io.BytesIO(self.read_bytes())


class ModelIntegrityTests(unittest.TestCase):
    def setUp(self):
        namespace = extract_functions(
            ENCODER_PATH, ["verify_model_files"], {"hashlib": hashlib}
        )
        self.verify = namespace["verify_model_files"]
        self.original = {
            "model.safetensors": b"original-weights",
            "tokenizer.json": b'{"tokenizer":"original"}',
        }
        self.files = dict(self.original)
        self.path = MemoryPath(self.files)
        self.manifest = {
            "files": [
                {"path": name, "bytes": len(content), "verified": True,
                 "sha256": hashlib.sha256(content).hexdigest()}
                for name, content in self.original.items()
            ]
        }

    def test_unchanged_content_is_accepted_and_returns_verified_hashes(self):
        expected = {
            name: hashlib.sha256(content).hexdigest()
            for name, content in self.original.items()
        }
        self.assertEqual(self.verify(self.path, self.manifest), expected)

    def test_same_length_content_change_is_rejected_despite_verified_flag(self):
        self.files["model.safetensors"] = b"tampered-weights"
        self.assertEqual(len(self.files["model.safetensors"]), len(self.original["model.safetensors"]))
        self.assertTrue(self.manifest["files"][0]["verified"])
        with self.assertRaisesRegex(RuntimeError, "hash mismatch"):
            self.verify(self.path, self.manifest)

    def test_same_length_tokenizer_change_is_also_rejected(self):
        self.files["tokenizer.json"] = b'{"tokenizer":"modified"}'
        self.assertEqual(len(self.files["tokenizer.json"]), len(self.original["tokenizer.json"]))
        with self.assertRaisesRegex(RuntimeError, "hash mismatch"):
            self.verify(self.path, self.manifest)

    def test_missing_file_cannot_be_silently_skipped(self):
        del self.files["tokenizer.json"]
        with self.assertRaises((FileNotFoundError, RuntimeError)):
            self.verify(self.path, self.manifest)


class MemoryPlist:
    def __init__(self, definition, present):
        self.definition = definition
        self.present = present

    def exists(self):
        return self.present

    def read_bytes(self):
        if not self.present:
            raise FileNotFoundError("synthetic plist")
        return plistlib.dumps(self.definition)


class FakeClock:
    def __init__(self):
        self.value = 0.0

    def monotonic(self):
        return self.value

    def sleep(self, seconds):
        self.value += seconds


class FakeLaunchctl:
    def __init__(self, target, output, loaded=True):
        self.target = target
        self.output = output
        self.is_loaded = loaded
        self.started = False
        self.failure = None
        self.calls = []

    def run(self, *arguments):
        self.calls.append(arguments)
        if arguments[0] == self.failure:
            return SimpleNamespace(returncode=5, stdout="", stderr=SYNTHETIC_PRIVATE_VALUE)
        if arguments == ("print", self.target):
            return SimpleNamespace(
                returncode=0 if self.is_loaded else 113,
                stdout=self.output if self.is_loaded else "",
                stderr="",
            )
        if arguments == ("bootout", self.target):
            self.is_loaded = False
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if arguments[0] == "bootstrap" and arguments[1] == self.target.rsplit("/", 1)[0]:
            self.is_loaded = True
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if arguments == ("kickstart", self.target) and self.is_loaded:
            self.started = True
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        raise AssertionError(f"Unexpected command in offline test: {arguments!r}")

    @property
    def bootouts(self):
        return [arguments for arguments in self.calls if arguments[0] == "bootout"]


def launchctl_fixture(definition, changes=None):
    """A job listing with unrelated sensitive-looking data, never real secrets."""
    fields = {
        "program": definition["ProgramArguments"][0],
        "arguments": list(definition["ProgramArguments"]),
        "working_directory": definition["WorkingDirectory"],
        "pid": 24680,
    }
    fields.update(changes or {})
    lines = [
        "synthetic-domain/synthetic.eg2 = {",
        f"\tprogram = {fields['program']}",
        "\targuments = {",
        *[f"\t\t{argument}" for argument in fields["arguments"]],
        "\t}",
        f"\tworking directory = {fields['working_directory']}",
        f"\tpid = {fields['pid']}",
        "\tenvironment = {",
        f"\t\tSYNTHETIC_PRIVATE_FIELD => {SYNTHETIC_PRIVATE_VALUE}",
        "\t}",
        "}",
    ]
    return "\n".join(lines) + "\n"


def manager_fixture(plist_present=True, changes=None, loaded=True, output=None,
                    foreign_disk_plist=False):
    namespace = {
        "ROOT": Path("/synthetic/Library/Application Support/AskBase/EmbeddingGemma2"),
        "LABEL": "synthetic.eg2",
        "TARGET": "synthetic-domain/synthetic.eg2",
        "plistlib": plistlib,
        "re": re,
        "time": FakeClock(),
    }
    extract_functions(
        MANAGER_PATH,
        ["definition", "verify_owned_plist", "loaded", "verify_loaded_identity", "stop"],
        namespace,
    )
    expected = namespace["definition"]()
    disk_definition = copy.deepcopy(expected)
    if foreign_disk_plist:
        disk_definition["ProgramArguments"][-1] = "/other-checkout/server.py"
    namespace["PLIST"] = MemoryPlist(disk_definition, plist_present)
    job = FakeLaunchctl(
        namespace["TARGET"],
        launchctl_fixture(expected, changes) if output is None else output,
        loaded=loaded,
    )
    namespace["run"] = job.run
    return namespace, job, expected


class LoadedJobOwnershipTests(unittest.TestCase):
    def assert_refused_without_bootout_or_raw_dump(self, namespace, job):
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            with self.assertRaises(RuntimeError) as caught:
                namespace["stop"]()
        self.assertEqual(job.bootouts, [])
        self.assertTrue(job.is_loaded, "Foreign job must remain untouched")
        diagnostic = stdout.getvalue() + stderr.getvalue() + str(caught.exception)
        self.assertNotIn(SYNTHETIC_PRIVATE_VALUE, diagnostic)
        self.assertNotIn("environment = {", diagnostic)

    def test_mismatched_loaded_program_arguments_or_directory_never_boots_out(self):
        _, _, expected = manager_fixture()
        wrong_arguments = list(expected["ProgramArguments"])
        wrong_arguments[-1] = "/other-checkout/server.py"
        for field, value in (
            ("program", "/other-checkout/python"),
            ("arguments", wrong_arguments),
            ("working_directory", "/other-checkout"),
        ):
            with self.subTest(field=field):
                namespace, job, _ = manager_fixture(changes={field: value})
                self.assert_refused_without_bootout_or_raw_dump(namespace, job)

    def test_missing_plist_and_foreign_loaded_job_never_boots_out(self):
        namespace, job, _ = manager_fixture(
            plist_present=False, changes={"working_directory": "/other-checkout"}
        )
        self.assert_refused_without_bootout_or_raw_dump(namespace, job)

    def test_unparseable_loaded_definition_fails_closed_without_raw_dump(self):
        namespace, job, _ = manager_fixture(
            output="unparseable synthetic job\n" + SYNTHETIC_PRIVATE_VALUE
        )
        self.assert_refused_without_bootout_or_raw_dump(namespace, job)

    def test_matching_loaded_identity_can_stop_with_or_without_disk_plist(self):
        for present in (True, False):
            with self.subTest(plist_present=present):
                namespace, job, _ = manager_fixture(plist_present=present)
                namespace["stop"]()
                self.assertEqual(job.bootouts, [("bootout", namespace["TARGET"])])
                self.assertFalse(job.is_loaded)

    def test_identity_returns_only_selected_fields_and_preserves_spaces(self):
        namespace, job, expected = manager_fixture()
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            identity = namespace["verify_loaded_identity"]()
        self.assertEqual(identity, {
            "program": expected["ProgramArguments"][0],
            "arguments": expected["ProgramArguments"],
            "working_directory": expected["WorkingDirectory"],
            "pid": 24680,
        })
        self.assertEqual(identity["arguments"][:2], ["/usr/bin/env", "-i"])
        self.assertIn("Application Support", identity["working_directory"])
        self.assertNotIn(SYNTHETIC_PRIVATE_VALUE, json.dumps(identity))
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(job.bootouts, [])

    def test_absent_loaded_job_returns_none_and_stop_has_no_side_effect(self):
        namespace, job, _ = manager_fixture(plist_present=False, loaded=False)
        self.assertIsNone(namespace["verify_loaded_identity"]())
        namespace["stop"]()
        self.assertEqual(job.bootouts, [])

    def test_foreign_disk_plist_is_also_rejected(self):
        namespace, job, _ = manager_fixture(foreign_disk_plist=True)
        self.assert_refused_without_bootout_or_raw_dump(namespace, job)
        namespace, job, _ = manager_fixture()
        namespace["PLIST"].definition["WorkingDirectory"] = "/other-checkout"
        self.assert_refused_without_bootout_or_raw_dump(namespace, job)


class OnDemandStartupTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name) / "runtime"
        root.mkdir()
        self.plist = Path(directory.name) / "agents/job.plist"
        self.listener = Mock()
        self.listener.connect_ex.return_value = 1
        socket = Mock()
        socket.return_value.__enter__ = Mock(return_value=self.listener)
        socket.return_value.__exit__ = Mock(return_value=None)
        self.namespace = {
            "ROOT": root,
            "LABEL": "synthetic.eg2",
            "DOMAIN": "synthetic-domain",
            "TARGET": "synthetic-domain/synthetic.eg2",
            "PLIST": self.plist,
            "CONFIG": {
                "host": "127.0.0.1", "port": 8871,
                "revision": "fixture-revision", "model_id": "embeddinggemma-2",
            },
            "plistlib": plistlib,
            "re": re,
            "time": FakeClock(),
            "socket": SimpleNamespace(socket=socket),
        }
        extract_functions(
            MANAGER_PATH,
            ["definition", "verify_owned_plist", "verify_loaded_identity", "start"],
            self.namespace,
        )
        self.expected = self.namespace["definition"]()
        self.job = FakeLaunchctl(
            self.namespace["TARGET"], launchctl_fixture(self.expected), loaded=False
        )
        self.namespace["run"] = self.job.run
        self.ready = {
            "status": "ok", "revision": "fixture-revision", "model": "embeddinggemma-2",
        }
        self.health = Mock(side_effect=lambda: self.ready if self.job.started else None)
        self.namespace["health"] = self.health

    def write_plist(self, data):
        self.plist.parent.mkdir(parents=True, exist_ok=True)
        self.plist.write_bytes(plistlib.dumps(data))
        return self.plist.read_bytes()

    def mutations(self):
        return [call for call in self.job.calls if call[0] != "print"]

    def test_new_install_registers_then_explicitly_starts_before_ready(self):
        self.assertEqual(self.namespace["start"](), self.ready)
        self.assertEqual(self.mutations(), [
            ("bootstrap", self.namespace["DOMAIN"], str(self.plist)),
            ("kickstart", self.namespace["TARGET"]),
        ])
        installed = plistlib.loads(self.plist.read_bytes())
        self.assertIs(installed["RunAtLoad"], False)
        self.assertIs(installed["KeepAlive"], False)
        self.assertEqual(installed, self.expected)
        self.assertEqual(self.plist.stat().st_mode & 0o777, 0o600)
        self.assertEqual(
            (self.namespace["ROOT"] / "launchd.plist").read_bytes(), self.plist.read_bytes()
        )
        self.health.assert_called_once_with()
        self.assertFalse(list(self.plist.parent.glob("*.tmp")))

    def test_legacy_policies_migrate_without_restarting_loaded_job(self):
        for loaded in (False, True):
            for run_at_load, keep_alive in ((True, True), (True, False), (False, True)):
                with self.subTest(loaded=loaded, policies=(run_at_load, keep_alive)):
                    previous = dict(self.expected, RunAtLoad=run_at_load, KeepAlive=keep_alive)
                    self.write_plist(previous)
                    self.job.is_loaded = loaded
                    self.job.started = False
                    self.job.calls.clear()
                    self.assertEqual(self.namespace["start"](), self.ready)
                    self.assertEqual(plistlib.loads(self.plist.read_bytes()), self.expected)
                    self.assertEqual(
                        [call[0] for call in self.mutations()],
                        ["kickstart"] if loaded else ["bootstrap", "kickstart"],
                    )
                    self.assertNotIn("-k", self.mutations()[-1])

    def test_nonpolicy_disk_changes_refuse_start_and_preserve_file(self):
        for field, value in (
            ("Label", "other.label"),
            ("ProgramArguments", ["/other/python", "/other/server.py"]),
            ("WorkingDirectory", "/other-checkout"),
            ("StandardOutPath", "/other/log"),
        ):
            with self.subTest(field=field):
                original = self.write_plist(dict(self.expected, **{field: value}))
                with self.assertRaises(RuntimeError):
                    self.namespace["start"]()
                self.assertEqual(self.plist.read_bytes(), original)
                self.assertEqual(self.job.calls, [])
                self.health.assert_not_called()

    def test_foreign_loaded_job_refuses_start_before_policy_write(self):
        for field, value in (
            ("program", "/other/python"),
            ("arguments", ["/other/python", "/other/server.py"]),
            ("working_directory", "/other-checkout"),
        ):
            with self.subTest(field=field):
                original = self.write_plist(dict(self.expected, RunAtLoad=True, KeepAlive=True))
                self.job.output = launchctl_fixture(self.expected, {field: value})
                self.job.is_loaded = True
                with self.assertRaises(RuntimeError):
                    self.namespace["start"]()
                self.assertEqual(self.plist.read_bytes(), original)
                self.assertEqual(self.mutations(), [])
                self.assertTrue(self.job.is_loaded)
                self.health.assert_not_called()

    def test_bootstrap_or_kickstart_failure_does_not_fall_back_or_poll_health(self):
        for operation in ("bootstrap", "kickstart"):
            with self.subTest(operation=operation):
                self.job.is_loaded = False
                self.job.failure = operation
                self.job.calls.clear()
                with self.assertRaisesRegex(RuntimeError, operation) as caught:
                    self.namespace["start"]()
                self.assertNotIn(SYNTHETIC_PRIVATE_VALUE, str(caught.exception))
                self.assertEqual(
                    [call[0] for call in self.mutations()],
                    ["bootstrap"] if operation == "bootstrap" else ["bootstrap", "kickstart"],
                )
                self.health.assert_not_called()

    def test_identity_is_rechecked_after_bootstrap_before_kickstart(self):
        self.job.output = launchctl_fixture(self.expected, {"working_directory": "/other-checkout"})
        with self.assertRaises(RuntimeError):
            self.namespace["start"]()
        self.assertEqual([call[0] for call in self.mutations()], ["bootstrap"])
        self.health.assert_not_called()

    def test_occupied_port_never_writes_or_starts_or_stops_a_job(self):
        self.listener.connect_ex.return_value = 0
        with self.assertRaisesRegex(RuntimeError, "already occupied"):
            self.namespace["start"]()
        self.assertFalse(self.plist.exists())
        self.assertEqual(self.mutations(), [])
        self.health.assert_not_called()

    def test_kickstart_success_still_requires_matching_service_health(self):
        self.health.side_effect = None
        self.health.return_value = dict(self.ready, revision="other-revision")
        with self.assertRaisesRegex(RuntimeError, "did not become ready"):
            self.namespace["start"]()
        self.assertEqual([call[0] for call in self.mutations()], ["bootstrap", "kickstart"])
        self.assertEqual(self.namespace["time"].monotonic(), 45)


if __name__ == "__main__":
    print("OFFLINE: AST-extracted guards; synthetic files and launchctl only", file=sys.stderr)
    for source, digest in SOURCE_HASHES.items():
        print(f"Source SHA256 {source}: {digest}", file=sys.stderr)
    unittest.main(verbosity=2)
