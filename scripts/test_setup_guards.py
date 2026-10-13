"""Offline regression tests: never call launchctl, install packages, or load a model."""
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.error
from unittest.mock import patch, Mock

HERE = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class OllamaOnDemandTests(unittest.TestCase):
    def setUp(self):
        self.module = load("start_ollama")
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.module.ROOT = root / "runtime"
        self.module.PLIST = root / "agents/job.plist"
        self.module.DOMAIN = "synthetic-domain"
        self.module.LABEL = "synthetic.ollama"
        self.target = f"{self.module.DOMAIN}/{self.module.LABEL}"
        binary = root / "ollama"
        binary.write_text("synthetic fixture; never executed")
        self.commands = []
        self.loaded = False
        self.running = False
        self.failure = None
        self.loaded_changes = {}
        self.listener = Mock()
        self.listener.connect_ex.return_value = 1
        socket = Mock()
        socket.__enter__ = Mock(return_value=self.listener)
        socket.__exit__ = Mock(return_value=None)
        for patcher in (
            patch.object(self.module.shutil, "which", return_value=str(binary)),
            patch.object(self.module.socket, "socket", return_value=socket),
            patch.object(self.module.subprocess, "run", side_effect=self.run_launchctl),
            patch.object(self.module, "local_models", side_effect=self.local_models),
            patch.object(self.module.time, "sleep"),
            patch("sys.stdout", new_callable=io.StringIO),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    def local_models(self):
        if not self.running:
            raise OSError("synthetic offline service")
        return []

    def run_launchctl(self, command, **kwargs):
        self.commands.append(command)
        if command[0] != "launchctl":
            raise AssertionError(f"Unexpected offline command: {command!r}")
        if command[1] == self.failure:
            return types.SimpleNamespace(returncode=5, stdout="", stderr="SECRET_SENTINEL")
        if command == ["launchctl", "print", self.target]:
            if not self.loaded:
                return types.SimpleNamespace(returncode=113, stdout="", stderr="")
            data = dict(plistlib.loads(self.module.PLIST.read_bytes()), **self.loaded_changes)
            output = "\n".join([
                f"program = {data['ProgramArguments'][0]}",
                "arguments = {", *data["ProgramArguments"], "}",
                f"working directory = {data['WorkingDirectory']}",
                "environment = { SECRET_SENTINEL }",
            ])
            return types.SimpleNamespace(returncode=0, stdout=output, stderr="")
        if command == ["launchctl", "bootstrap", self.module.DOMAIN, str(self.module.PLIST)]:
            self.loaded = True
        elif command == ["launchctl", "kickstart", self.target] and self.loaded:
            self.running = True
        else:
            raise AssertionError(f"Unexpected offline command: {command!r}")
        return types.SimpleNamespace(returncode=0, stdout="", stderr="")

    def mutations(self):
        return [command for command in self.commands if command[1] != "print"]

    def installed_definition(self):
        self.module.start()
        data = plistlib.loads(self.module.PLIST.read_bytes())
        self.running = False
        self.commands.clear()
        return data

    def test_new_install_bootstraps_then_kickstarts_and_verifies_ready(self):
        self.module.start()
        self.assertEqual(self.mutations(), [
            ["launchctl", "bootstrap", self.module.DOMAIN, str(self.module.PLIST)],
            ["launchctl", "kickstart", self.target],
        ])
        data = plistlib.loads(self.module.PLIST.read_bytes())
        self.assertIs(data["RunAtLoad"], False)
        self.assertIs(data["KeepAlive"], False)
        self.assertEqual(self.module.PLIST.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(sys.stdout.getvalue())["status"], "running")
        self.assertFalse(list(self.module.PLIST.parent.glob("*.tmp")))

    def test_only_legacy_policies_change_for_loaded_or_unloaded_jobs(self):
        expected = self.installed_definition()
        for loaded in (True, False):
            for run_at_load, keep_alive in ((True, True), (True, False), (False, True)):
                with self.subTest(loaded=loaded, policies=(run_at_load, keep_alive)):
                    previous = dict(expected, RunAtLoad=run_at_load, KeepAlive=keep_alive)
                    self.module.PLIST.write_bytes(plistlib.dumps(previous))
                    self.loaded, self.running = loaded, False
                    self.commands.clear()
                    self.module.start()
                    self.assertEqual(plistlib.loads(self.module.PLIST.read_bytes()), expected)
                    self.assertEqual(
                        [command[1] for command in self.mutations()],
                        ["kickstart"] if loaded else ["bootstrap", "kickstart"],
                    )
                    self.assertNotIn("-k", self.mutations()[-1])

    def test_nonpolicy_disk_changes_preserve_file_and_never_start_or_stop(self):
        expected = self.installed_definition()
        for field, value in (
            ("Label", "other.label"),
            ("ProgramArguments", ["/unrelated/binary", "serve"]),
            ("WorkingDirectory", "/unrelated"),
            ("StandardOutPath", "/unrelated/log"),
        ):
            with self.subTest(field=field):
                original = plistlib.dumps(dict(expected, **{field: value}, RunAtLoad=True))
                self.module.PLIST.write_bytes(original)
                with self.assertRaises(SystemExit):
                    self.module.start()
                self.assertEqual(self.module.PLIST.read_bytes(), original)
                self.assertEqual(self.commands, [])

    def test_foreign_loaded_identity_is_checked_before_migration_and_after_bootstrap(self):
        expected = self.installed_definition()
        for loaded in (True, False):
            for field, value in (
                ("ProgramArguments", ["/unrelated/binary", "serve"]),
                ("WorkingDirectory", "/unrelated"),
            ):
                with self.subTest(loaded=loaded, field=field):
                    original = plistlib.dumps(dict(expected, RunAtLoad=True, KeepAlive=True))
                    self.module.PLIST.write_bytes(original)
                    self.loaded, self.running = loaded, False
                    self.loaded_changes = {field: value}
                    self.commands.clear()
                    with self.assertRaises(SystemExit) as caught:
                        self.module.start()
                    self.assertNotIn("SECRET_SENTINEL", str(caught.exception))
                    self.assertEqual(
                        [command[1] for command in self.mutations()], [] if loaded else ["bootstrap"]
                    )
                    if loaded:
                        self.assertEqual(self.module.PLIST.read_bytes(), original)

    def test_kickstart_failure_never_polls_health_or_uses_a_fallback(self):
        self.failure = "kickstart"
        with self.assertRaises(SystemExit) as caught:
            self.module.start()
        self.assertNotIn("SECRET_SENTINEL", str(caught.exception))
        self.assertEqual([command[1] for command in self.mutations()], ["bootstrap", "kickstart"])
        self.module.local_models.assert_called_once_with()

    def test_healthy_external_service_is_reused_without_writes_or_launchctl(self):
        self.running = True
        self.module.start()
        self.assertEqual(json.loads(sys.stdout.getvalue())["status"], "already_running")
        self.assertEqual(self.commands, [])
        self.assertFalse(self.module.PLIST.exists())
        self.module.socket.socket.assert_not_called()

    def test_occupied_unknown_port_is_not_touched(self):
        self.listener.connect_ex.return_value = 0
        with self.assertRaisesRegex(SystemExit, "occupied"):
            self.module.start()
        self.assertEqual(self.commands, [])
        self.assertFalse(self.module.PLIST.exists())

    def test_successful_kickstart_is_not_enough_without_ready_api(self):
        self.module.local_models.side_effect = OSError("synthetic API unavailable")
        with self.assertRaisesRegex(SystemExit, "did not become ready"):
            self.module.start()
        self.assertEqual([command[1] for command in self.mutations()], ["bootstrap", "kickstart"])
        self.assertEqual(self.module.local_models.call_count, 21)


class SetupGuards(unittest.TestCase):
    def test_foreign_loaded_identity_is_rejected_without_exposing_output(self):
        module = load("start_ollama")
        output = """program = /unrelated/binary
arguments = {
 /unrelated/binary
}
working directory = /unrelated
environment = { SECRET_SENTINEL_DO_NOT_PRINT }
"""
        with patch.object(module.subprocess, "run", return_value=types.SimpleNamespace(returncode=0, stdout=output, stderr="")):
            with self.assertRaises(SystemExit) as error:
                module.loaded_identity_matches({
                    "ProgramArguments": ["/usr/bin/env", "-i", "ollama", "serve"],
                    "WorkingDirectory": "/expected",
                })
        self.assertNotIn("SECRET_SENTINEL", str(error.exception))

    def test_bootstrap_failure_never_kickstarts_a_fallback_job(self):
        module = load("start_ollama")
        with tempfile.TemporaryDirectory() as directory:
            module.ROOT = Path(directory) / "runtime"
            module.ROOT.mkdir()
            module.PLIST = Path(directory) / "agents/job.plist"
            socket = Mock()
            socket.__enter__ = Mock(return_value=socket)
            socket.__exit__ = Mock(return_value=None)
            socket.connect_ex.return_value = 1
            commands = []

            def run(command, **kwargs):
                commands.append(command)
                return types.SimpleNamespace(returncode=5, stdout="", stderr="fixture failure")

            with patch.object(module, "local_models", side_effect=OSError("offline")), \
                 patch.object(module, "loaded_identity_matches", return_value=False), \
                 patch.object(module.shutil, "which", return_value="/usr/bin/true"), \
                 patch.object(module.socket, "socket", return_value=socket), \
                 patch.object(module.subprocess, "run", side_effect=run):
                with self.assertRaises(SystemExit):
                    module.start()
            self.assertEqual([command[1] for command in commands], ["bootstrap"])
            self.assertFalse(list(module.PLIST.parent.glob("*.tmp")))

    def test_two_startup_calls_are_serialized(self):
        module = load("start_ollama")
        with tempfile.TemporaryDirectory() as directory:
            module.ROOT = Path(directory)
            entered = threading.Event()
            release = threading.Event()
            active = 0
            peak = 0
            visits = 0
            lock = threading.Lock()

            def start():
                nonlocal active, peak, visits
                with lock:
                    active += 1
                    peak = max(peak, active)
                    visits += 1
                    first = visits == 1
                if first:
                    entered.set()
                    release.wait(3)
                with lock:
                    active -= 1

            with patch.object(module, "start", side_effect=start):
                first = threading.Thread(target=module.main)
                second = threading.Thread(target=module.main)
                first.start()
                self.assertTrue(entered.wait(2))
                second.start()
                time.sleep(0.25)
                self.assertEqual(visits, 1)
                release.set()
                first.join(3)
                second.join(3)
                self.assertFalse(first.is_alive() or second.is_alive())
            self.assertEqual((visits, peak), (2, 1))

    def test_python_executable_does_not_mark_partial_install_complete(self):
        module = load("setup_embedding")
        with tempfile.TemporaryDirectory() as directory:
            module.RUNTIME = Path(directory)
            python = module.RUNTIME / ".venv/bin/python"
            python.parent.mkdir(parents=True)
            python.write_text("")
            manager = module.RUNTIME / "scripts/manage.py"
            manager.parent.mkdir()
            manager.write_text("")
            self.assertFalse(module.runtime_complete())

    def test_partial_install_retries_installation_before_start(self):
        module = load("setup_embedding")
        with tempfile.TemporaryDirectory() as directory:
            module.RUNTIME = Path(directory) / "runtime"
            module.RUNTIME.mkdir()
            (module.RUNTIME / "config.json").write_text(json.dumps({
                "revision": module.REVISION, "repository": "google/embeddinggemma-2",
            }))
            module.SOURCE = Path(directory) / "source"
            module.SOURCE.mkdir()
            socket = Mock()
            socket.__enter__ = Mock(return_value=socket)
            socket.__exit__ = Mock(return_value=None)
            socket.connect_ex.return_value = 1
            opener = Mock()
            opener.open.side_effect = urllib.error.URLError("fixture offline")
            commands = []
            with patch.object(module.platform, "system", return_value="Darwin"), \
                 patch.object(module.platform, "machine", return_value="arm64"), \
                 patch.object(module.urllib.request, "build_opener", return_value=opener), \
                 patch.object(module.socket, "socket", return_value=socket), \
                 patch.object(module.shutil, "which", return_value="/fixture/uv"), \
                 patch.object(module, "runtime_complete", return_value=False), \
                 patch.object(module.subprocess, "run", side_effect=lambda command, **kw: commands.append(command)):
                module.setup()
            self.assertTrue(any("pip" in command and "install" in command for command in commands))
            self.assertTrue(any(str(module.SOURCE / "scripts/install_runtime.py") in command for command in commands))
            self.assertEqual(commands[-1][-1], "start")

    def test_build_refuses_mislabeled_architecture(self):
        module = load("build_app")
        calls = []
        def check_output(command, **kwargs):
            calls.append(command)
            return "/fixture/output\n" if command[0] == "swift" else "x86_64\n"
        with patch.object(sys, "argv", ["build_app.py"]), \
             patch.object(module.subprocess, "run", side_effect=lambda command, **kw: calls.append(command)), \
             patch.object(module.subprocess, "check_output", side_effect=check_output):
            with self.assertRaises(SystemExit):
                module.main()
        for command in calls[:2]:
            self.assertEqual(command[command.index("--arch") + 1], "arm64")
        self.assertEqual(calls[-1][0:2], ["lipo", "-archs"])

    def test_healthy_text_only_service_is_upgraded_instead_of_reported_as_multimodal(self):
        module = load("setup_embedding")
        with tempfile.TemporaryDirectory() as directory:
            module.RUNTIME = Path(directory) / "runtime"
            module.RUNTIME.mkdir()
            (module.RUNTIME / "config.json").write_text(json.dumps({
                "revision": module.REVISION, "repository": "google/embeddinggemma-2",
            }))
            module.SOURCE = Path(directory) / "source"
            module.SOURCE.mkdir()
            response = io.BytesIO(json.dumps({
                "model": "embeddinggemma-2", "revision": module.REVISION,
                "status": "ok", "dimensions": 768, "encoder_signature": "legacy", "modalities": ["text"],
            }).encode())
            opener = Mock()
            opener.open.return_value = response
            socket = Mock()
            socket.__enter__ = Mock(return_value=socket); socket.__exit__ = Mock(return_value=None)
            socket.connect_ex.return_value = 1
            commands = []
            with patch.object(module.platform, "system", return_value="Darwin"), \
                 patch.object(module.platform, "machine", return_value="arm64"), \
                 patch.object(module.urllib.request, "build_opener", return_value=opener), \
                 patch.object(module.socket, "socket", return_value=socket), \
                 patch.object(module.shutil, "which", return_value="/fixture/uv"), \
                 patch.object(module, "runtime_complete", return_value=False), \
                 patch.object(module.subprocess, "run", side_effect=lambda command, **kw: commands.append(command)):
                module.setup()
            self.assertEqual(commands[0][-1], "stop")
            self.assertIn(str(module.SOURCE / "scripts/manage.py"), commands[0])
            self.assertTrue(any(str(module.SOURCE / "scripts/install_runtime.py") in command for command in commands))
            self.assertEqual(commands[-1][-1], "start")

    def test_text_only_listener_without_owned_runtime_is_not_stopped(self):
        module = load("setup_embedding")
        with tempfile.TemporaryDirectory() as directory:
            module.RUNTIME = Path(directory)
            opener = Mock()
            opener.open.return_value = io.BytesIO(json.dumps({
                "model": "embeddinggemma-2", "revision": module.REVISION,
                "status": "ok", "dimensions": 768, "encoder_signature": "legacy", "modalities": ["text"],
            }).encode())
            with patch.object(module.platform, "system", return_value="Darwin"), \
                 patch.object(module.platform, "machine", return_value="arm64"), \
                 patch.object(module.urllib.request, "build_opener", return_value=opener), \
                 patch.object(module.subprocess, "run") as run:
                with self.assertRaises(SystemExit):
                    module.setup()
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
