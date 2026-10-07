#!/usr/bin/env python3
"""Offline guard regression tests; standard library, in-memory fixtures only.

Run: python3 -B scripts/test_deployment_guards.py

The tested functions are extracted from the actual source AST. Neither service
module is imported. No models, network, launchctl, subprocesses, real plist
files, or temporary files are used.
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
from types import SimpleNamespace
import unittest


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
        self.calls = []

    def run(self, *arguments):
        self.calls.append(arguments)
        if arguments == ("print", self.target):
            return SimpleNamespace(
                returncode=0 if self.is_loaded else 113,
                stdout=self.output if self.is_loaded else "",
                stderr="",
            )
        if arguments == ("bootout", self.target):
            self.is_loaded = False
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


if __name__ == "__main__":
    print("OFFLINE: AST-extracted guards; in-memory files and launchctl only", file=sys.stderr)
    for source, digest in SOURCE_HASHES.items():
        print(f"Source SHA256 {source}: {digest}", file=sys.stderr)
    unittest.main(verbosity=2)
