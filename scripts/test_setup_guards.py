"""Offline regression tests: never call launchctl, install packages, or load a model."""
import importlib.util
import io
import json
from pathlib import Path
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
