#!/usr/bin/env python3
"""Offline lifecycle regression checks, with no model or real-service access.

Run from the repository root:
    python3 -B services/runtime/test_supervisor.py

All launchctl, lsof, port and HTTP operations are mocked or fail closed. Disk
fixtures live under TemporaryDirectory. Real process checks launch only this
file's small Python fixtures, in fresh sessions, and clean up only those PIDs;
the EPERM fallback may run exactly /bin/ps -axo pgid= (read-only group IDs).
This is engineering contract coverage, not model/GUI/real-library acceptance.
"""

from contextlib import ExitStack
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import types
import unittest
from unittest.mock import Mock, patch


SOURCE_PATH = Path(__file__).with_name("supervisor.py")
SOURCE = SOURCE_PATH.read_bytes()
SOURCE_SHA256 = hashlib.sha256(SOURCE).hexdigest()
PYTHON = str(Path(sys.executable).resolve())
PRIVATE_SENTINEL = "SYNTHETIC-PRIVATE-JOB-OUTPUT"


def forbidden(*args, **kwargs):
    raise AssertionError("Offline test attempted a real service/network operation")


def load_supervisor():
    # Execute the exact bytes whose digest is reported. No .pyc or fixture files
    # are written into the checkout; import cannot accidentally execute main().
    module = types.ModuleType("askbase_supervisor_under_test")
    module.__file__ = str(SOURCE_PATH)
    exec(compile(SOURCE, str(SOURCE_PATH), "exec"), module.__dict__)
    return module


def result(code=0, stdout="", stderr=""):
    return types.SimpleNamespace(returncode=code, stdout=stdout, stderr=stderr)


def identity(definition, pid=24680, **changes):
    value = {
        "program": definition["ProgramArguments"][0],
        "arguments": list(definition["ProgramArguments"]),
        "directory": definition["WorkingDirectory"],
        "pid": pid,
    }
    value.update(changes)
    return value


def listing(value):
    lines = [
        "synthetic-job = {",
        f"\tprogram = {value['program']}",
        "\targuments = {",
        *[f"\t\t{arg}" for arg in value["arguments"]],
        "\t}",
        f"\tworking directory = {value['directory']}",
    ]
    if value["pid"] is not None:
        lines.append(f"\tpid = {value['pid']}")
    lines += [f"\tenvironment = {{ {PRIVATE_SENTINEL} }}", "}"]
    return "\n".join(lines) + "\n"


class FakeLaunchd:
    def __init__(self, target, actual):
        self.target = target
        self.actual = actual
        self.calls = []
        self.bootout_result = result()
        self.after_bootout = None
        self.linger = 0
        self.booted = False

    def __call__(self, *args):
        self.calls.append(args)
        if args == ("print", self.target):
            if self.booted:
                if self.linger:
                    self.linger -= 1
                else:
                    self.actual = None
            return result(stdout=listing(self.actual)) if self.actual else result(113)
        if args == ("bootout", self.target):
            if self.bootout_result.returncode == 0:
                self.booted = True
                if self.after_bootout:
                    self.after_bootout()
            return self.bootout_result
        raise AssertionError(f"Unexpected mocked launchctl action: {args}")

    @property
    def mutations(self):
        return [call for call in self.calls if call[0] != "print"]


class OfflineCase(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.home = Path(self.stack.enter_context(tempfile.TemporaryDirectory(prefix="askbase-supervisor-")))
        self.module = load_supervisor()
        # Facades prevent a future implementation change from escaping mocks.
        self.module.subprocess = types.SimpleNamespace(
            run=forbidden, Popen=forbidden, DEVNULL=subprocess.DEVNULL,
            PIPE=subprocess.PIPE, STDOUT=subprocess.STDOUT,
            TimeoutExpired=subprocess.TimeoutExpired,
            SubprocessError=subprocess.SubprocessError,
        )
        self.module.socket = types.SimpleNamespace(socket=forbidden)
        self.module.launchctl = Mock(side_effect=forbidden)
        self.module.listener_pids = Mock(side_effect=forbidden)
        self.module.port_busy = Mock(side_effect=forbidden)
        self.events = []
        self.module.emit = lambda event, **fields: self.events.append({"event": event, **fields})
        self.runtime = self.module.Supervisor(
            os.getppid(), "http://127.0.0.1:8871", "http://127.0.0.1:11434", home=self.home,
        )
        self.runtime.opener.open = Mock(side_effect=forbidden)

    def fixture(self, definition=None, actual=True, saved=True):
        definition = definition or self.runtime.embedding_definition()
        plist = self.home / "Library/LaunchAgents" / (definition["Label"] + ".plist")
        if saved:
            plist.parent.mkdir(parents=True, exist_ok=True)
            plist.write_bytes(plistlib.dumps(dict(
                definition, RunAtLoad=True, KeepAlive={"SuccessfulExit": False},
                SyntheticUnrelatedField="preserve-this",
            )))
        actual_value = identity(definition) if actual is True else actual or None
        launchd = FakeLaunchd(f"gui/{os.getuid()}/{definition['Label']}", actual_value)
        self.module.launchctl = launchd
        self.module.listener_pids.return_value = {24680}
        self.module.listener_pids.side_effect = None
        self.module.port_busy.return_value = False
        self.module.port_busy.side_effect = None
        return definition, plist, launchd

    def install_embedding_fixture(self, **config):
        root = self.runtime.embedding_root
        (root / ".venv/bin").mkdir(parents=True)
        (root / ".venv/bin/python").write_text("fixture; never executed")
        (root / "server.py").write_text("fixture; never executed")
        (root / "config.json").write_text(json.dumps({
            "host": "127.0.0.1", "port": 8871,
            "model_id": "synthetic-model", "revision": "synthetic-revision", **config,
        }))


class EndpointTests(OfflineCase):
    def test_only_exact_default_endpoints_are_managed(self):
        for url in ("http://127.0.0.1:8871", "http://localhost:8871/"):
            with self.subTest(url=url):
                self.assertTrue(self.module.is_default_endpoint(url, 8871))
        for url in (
            "http://127.0.0.1:9000", "https://localhost:8871",
            "http://localhost:8871/api", "http://localhost:8871?x=y",
            "http://localhost:8871/#fragment", "http://user@localhost:8871",
            "http://[::1]:8871", "http://example.invalid:8871",
            "http://localhost:invalid", "not-a-url",
        ):
            with self.subTest(url=url):
                self.assertFalse(self.module.is_default_endpoint(url, 8871))

    def test_custom_endpoints_never_probe_migrate_or_spawn(self):
        self.runtime.embedding_url = "http://127.0.0.1:9001"
        self.runtime.ollama_url = "http://localhost:9002"
        with patch.object(self.runtime, "migrate_legacy", side_effect=forbidden), \
                patch.object(self.runtime, "spawn", side_effect=forbidden), \
                patch.object(self.runtime, "ollama_binary", side_effect=forbidden):
            self.assertEqual(self.runtime.start_embedding(), "external")
            self.assertEqual(self.runtime.start_ollama(), "external")
        self.module.launchctl.assert_not_called()
        self.module.port_busy.assert_not_called()
        self.assertEqual(self.runtime.children, [])
        self.assertFalse(self.runtime.root.exists())

    def test_custom_embedding_config_is_external_before_migration(self):
        self.install_embedding_fixture(port=9003)
        with patch.object(self.runtime, "migrate_legacy", side_effect=forbidden), \
                patch.object(self.runtime, "spawn", side_effect=forbidden):
            self.assertEqual(self.runtime.start_embedding(), "external")

    def test_missing_installations_are_unavailable(self):
        self.assertEqual(self.runtime.start_embedding(), "unavailable")
        with patch.object(self.runtime, "ollama_binary", return_value=None):
            self.assertEqual(self.runtime.start_ollama(), "unavailable")
        self.module.launchctl.assert_not_called()
        self.assertEqual(self.runtime.children, [])

    def test_unknown_listener_is_preserved_for_both_services(self):
        self.install_embedding_fixture()
        self.module.port_busy.side_effect = None
        self.module.port_busy.return_value = True
        self.module.launchctl = Mock(return_value=result(113))
        with patch.object(self.runtime, "ollama_binary", return_value="/synthetic/ollama"), \
                patch.object(self.runtime, "spawn", side_effect=forbidden):
            self.assertEqual(self.runtime.start_embedding(), "external")
            self.assertEqual(self.runtime.start_ollama(), "external")
        self.assertTrue(all(call.args[0] == "print" for call in self.module.launchctl.call_args_list))
        self.assertEqual(self.runtime.children, [])


class MigrationTests(OfflineCase):
    def test_exact_jobs_disable_both_flags_preserve_fields_and_original_backup(self):
        for definition, port in (
            (self.runtime.embedding_definition(), 8871),
            (self.runtime.ollama_definition("/synthetic/ollama"), 11434),
        ):
            with self.subTest(label=definition["Label"]):
                definition, plist, launchd = self.fixture(definition)
                before = plist.read_bytes()
                self.runtime.migrate_legacy(definition, port)
                updated = plistlib.loads(plist.read_bytes())
                self.assertIs(updated.pop("RunAtLoad"), False)
                self.assertIs(updated.pop("KeepAlive"), False)
                self.assertEqual(updated, dict(definition, SyntheticUnrelatedField="preserve-this"))
                backup = self.runtime.root / "LaunchAgentBackups" / plist.name
                self.assertEqual(backup.read_bytes(), before)
                self.assertEqual(plist.stat().st_mode & 0o777, 0o600)
                self.assertEqual(launchd.mutations, [("bootout", launchd.target)])
                self.runtime.migrate_legacy(definition, port)
                self.assertEqual(backup.read_bytes(), before)
                self.assertEqual(launchd.mutations, [("bootout", launchd.target)])

    def test_foreign_disk_definition_is_never_changed_or_stopped(self):
        definition, plist, launchd = self.fixture()
        for key, value in (
            ("Label", "another.application"),
            ("ProgramArguments", ["/synthetic/another-program"]),
            ("WorkingDirectory", "/synthetic/another-install"),
        ):
            with self.subTest(field=key):
                plist.write_bytes(plistlib.dumps(dict(definition, **{key: value})))
                before = plist.read_bytes()
                with self.assertRaises(self.module.RuntimeFailure):
                    self.runtime.migrate_legacy(definition, 8871)
                self.assertEqual(plist.read_bytes(), before)
                self.assertEqual(launchd.calls, [])
                self.assertFalse(self.runtime.root.exists())

    def test_foreign_loaded_definition_is_never_changed_or_stopped(self):
        definition, plist, launchd = self.fixture()
        before = plist.read_bytes()
        for change in (
            {"program": "/synthetic/foreign"},
            {"arguments": definition["ProgramArguments"] + ["--foreign"]},
            {"directory": "/synthetic/foreign"},
        ):
            with self.subTest(change=change):
                launchd.actual = identity(definition, **change)
                with self.assertRaises(self.module.RuntimeFailure):
                    self.runtime.migrate_legacy(definition, 8871)
                self.assertEqual(plist.read_bytes(), before)
                self.assertEqual(launchd.mutations, [])
                self.assertFalse(self.runtime.root.exists())

    def test_foreign_or_additional_listener_prevents_all_mutations(self):
        definition, plist, launchd = self.fixture()
        before = plist.read_bytes()
        for pids in ({12345}, {24680, 12345}):
            with self.subTest(pids=pids):
                self.module.listener_pids.return_value = pids
                with self.assertRaises(self.module.RuntimeFailure):
                    self.runtime.migrate_legacy(definition, 8871)
                self.assertEqual(plist.read_bytes(), before)
                self.assertEqual(launchd.mutations, [])

    def test_missing_job_pid_cannot_claim_a_listener(self):
        definition, plist, launchd = self.fixture()
        before = plist.read_bytes()
        launchd.actual["pid"] = None
        with self.assertRaises(self.module.RuntimeFailure):
            self.runtime.migrate_legacy(definition, 8871)
        self.assertEqual(launchd.mutations, [])
        self.assertEqual(plist.read_bytes(), before)

    def test_launchctl_print_error_fails_closed_and_redacts_output(self):
        definition, plist, _ = self.fixture()
        before = plist.read_bytes()
        self.module.launchctl = Mock(return_value=result(5, PRIVATE_SENTINEL, PRIVATE_SENTINEL))
        with self.assertRaises(self.module.RuntimeFailure) as caught:
            self.runtime.migrate_legacy(definition, 8871)
        self.assertNotIn(PRIVATE_SENTINEL, str(caught.exception))
        self.assertEqual(plist.read_bytes(), before)
        self.assertEqual(self.module.launchctl.call_count, 1)

    def test_unparseable_loaded_identity_fails_closed(self):
        definition, plist, _ = self.fixture()
        before = plist.read_bytes()
        self.module.launchctl = Mock(return_value=result(stdout="program = /usr/bin/env\n"))
        with self.assertRaises(self.module.RuntimeFailure):
            self.runtime.migrate_legacy(definition, 8871)
        self.assertEqual(plist.read_bytes(), before)
        self.assertEqual(self.module.launchctl.call_count, 1)

    def test_unloaded_matching_plist_disables_flags_without_bootout(self):
        definition, plist, launchd = self.fixture(actual=False)
        self.runtime.migrate_legacy(definition, 8871)
        updated = plistlib.loads(plist.read_bytes())
        self.assertIs(updated["RunAtLoad"], False)
        self.assertIs(updated["KeepAlive"], False)
        self.assertEqual(launchd.mutations, [])
        self.module.listener_pids.assert_not_called()

    def test_bootout_failure_is_reported_without_spawning_or_pid_signals(self):
        definition, plist, launchd = self.fixture()
        launchd.bootout_result = result(5, PRIVATE_SENTINEL, PRIVATE_SENTINEL)
        with patch.object(self.module.os, "killpg", side_effect=forbidden):
            with self.assertRaises(self.module.RuntimeFailure) as caught:
                self.runtime.migrate_legacy(definition, 8871)
        self.assertNotIn(PRIVATE_SENTINEL, str(caught.exception))
        self.assertEqual(launchd.mutations, [("bootout", launchd.target)])
        self.assertIs(plistlib.loads(plist.read_bytes())["KeepAlive"], False)
        self.assertEqual(self.runtime.children, [])

    def test_cancellation_before_migration_has_no_effects(self):
        definition, plist, launchd = self.fixture()
        before = plist.read_bytes()
        self.runtime.stop_event.set()
        with self.assertRaises(self.module.Stopping):
            self.runtime.migrate_legacy(definition, 8871)
        self.assertEqual(plist.read_bytes(), before)
        self.assertEqual(launchd.calls, [])

    def test_cancel_after_flags_write_still_boots_out_and_waits_for_exit(self):
        definition, plist, launchd = self.fixture()
        launchd.linger = 2
        original_write = self.module.atomic_write

        def cancel_after_write(path, data):
            original_write(path, data)
            if path == plist:
                self.runtime.stop_event.set()

        with patch.object(self.module, "atomic_write", side_effect=cancel_after_write):
            try:
                self.runtime.migrate_legacy(definition, 8871)
            except self.module.Stopping:
                pass
        self.assertEqual(launchd.mutations, [("bootout", launchd.target)])
        self.assertIsNone(launchd.actual, "Cancellation returned before the old job disappeared")
        self.module.port_busy.assert_called()
        with self.assertRaises(self.module.Stopping):
            self.runtime.checkpoint()

    def test_cancel_after_bootout_waits_for_job_disappearance(self):
        definition, _, launchd = self.fixture()
        launchd.linger = 2
        launchd.after_bootout = self.runtime.stop_event.set
        try:
            self.runtime.migrate_legacy(definition, 8871)
        except self.module.Stopping:
            pass
        self.assertIsNone(launchd.actual, "Stopping must not interrupt legacy termination polling")
        self.module.port_busy.assert_called()
        with self.assertRaises(self.module.Stopping):
            self.runtime.checkpoint()


class ReadinessTests(OfflineCase):
    def test_health_success_requires_exact_owned_listener(self):
        child = Mock(pid=24680)
        child.poll.return_value = None
        self.runtime.request_json = Mock(return_value={"status": "ok"})
        self.module.listener_pids.side_effect = None
        for pids in (set(), {12345}, {24680, 12345}):
            with self.subTest(pids=pids):
                self.module.listener_pids.return_value = pids
                with self.assertRaises(self.module.RuntimeFailure):
                    self.runtime.await_ready(child, 8871, "/health", lambda x: True, 0)
        self.module.listener_pids.return_value = {24680}
        self.runtime.await_ready(child, 8871, "/health", lambda x: True, 0)

    def test_dead_child_never_becomes_ready(self):
        child = Mock(pid=24680)
        child.poll.return_value = 1
        with self.assertRaises(self.module.RuntimeFailure):
            self.runtime.await_ready(child, 8871, "/health", lambda x: True, 0)
        self.runtime.opener.open.assert_not_called()

    def test_timeout_and_cancel_are_distinct(self):
        child = Mock(pid=24680)
        child.poll.return_value = None
        self.runtime.request_json = Mock(side_effect=OSError("synthetic offline"))
        with self.assertRaises(self.module.RuntimeFailure):
            self.runtime.await_ready(child, 8871, "/health", lambda x: True, 0)
        self.runtime.stop_event.set()
        with self.assertRaises(self.module.Stopping):
            self.runtime.await_ready(child, 8871, "/health", lambda x: True, 0)

    def test_embedding_health_checks_model_and_revision_before_acceptance(self):
        self.install_embedding_fixture()
        child = Mock(pid=24680)
        self.runtime.migrate_legacy = Mock()
        self.runtime.spawn = Mock(return_value=child)
        self.module.port_busy.side_effect = None
        self.module.port_busy.return_value = False

        def verify(actual_child, port, path, valid, timeout):
            self.assertIs(actual_child, child)
            self.assertEqual((port, path), (8871, "/health"))
            expected = {"status": "ok", "model": "synthetic-model", "revision": "synthetic-revision"}
            self.assertTrue(valid(expected))
            for change in ({"status": "loading"}, {"model": "foreign-model"}, {"revision": "foreign-revision"}):
                self.assertFalse(valid(dict(expected, **change)))

        self.runtime.await_ready = verify
        self.assertEqual(self.runtime.start_embedding(), "managed")


class FailureIsolationTests(OfflineCase):
    def test_eperm_cannot_mark_a_live_or_unknown_group_released(self):
        # Entirely synthetic: no real PID signals and no real ps invocation.
        pgid = 24680
        self.module.os = types.SimpleNamespace(killpg=Mock(side_effect=PermissionError("synthetic EPERM")))
        self.module.subprocess.run = Mock(return_value=result(stdout=" 24680\n 124680\n"))
        self.assertTrue(self.module.group_alive(pgid), "EPERM with an exact member is still alive")
        self.module.subprocess.run.assert_called_once_with(
            ["/bin/ps", "-axo", "pgid="], capture_output=True, text=True, timeout=3,
        )
        self.module.subprocess.run.return_value = result(stdout=" 124680\n 246801\n")
        self.assertFalse(self.module.group_alive(pgid), "PGID matching must be exact")

        self.module.subprocess.run.return_value = result(1, stderr=PRIVATE_SENTINEL)
        with self.assertRaises(self.module.RuntimeFailure):
            self.module.group_alive(pgid)
        child = Mock(pid=pgid)
        self.runtime.children = [("unknown-owned-group", child)]
        clock = iter(range(100))
        self.module.time = types.SimpleNamespace(monotonic=lambda: next(clock), sleep=lambda _: None)
        with self.assertRaises(self.module.RuntimeFailure):
            self.runtime.cleanup(grace=0)
        self.assertEqual(self.runtime.children, [("unknown-owned-group", child)])

    def test_cleanup_failure_in_one_group_does_not_skip_remaining_owned_group(self):
        healthy, denied = Mock(pid=10000001), Mock(pid=10000002)
        self.runtime.children = [("healthy", healthy), ("denied", denied)]
        groups = {healthy.pid, denied.pid}
        sent = []

        def killpg(pgid, sig):
            sent.append((pgid, sig))
            if pgid == denied.pid:
                raise PermissionError("synthetic one-group permission failure")
            if sig == signal.SIGKILL:
                groups.discard(pgid)

        # No real PID signals: the entire os facade used by cleanup is replaced.
        self.module.os = types.SimpleNamespace(killpg=killpg)
        self.module.group_alive = lambda pgid: pgid in groups
        clock = iter(range(100))
        self.module.time = types.SimpleNamespace(monotonic=lambda: next(clock), sleep=lambda _: None)
        caught = None
        try:
            self.runtime.cleanup(grace=0)
        except Exception as error:
            caught = error
        self.assertIn(
            (healthy.pid, signal.SIGKILL), sent,
            "Failure for one owned group skipped cleanup of another spawned group",
        )
        self.assertIsInstance(caught, self.module.RuntimeFailure)
        self.assertEqual(self.runtime.children, [("denied", denied)])

    def test_lock_timeout_never_starts_or_cleans_another_instance(self):
        self.runtime.root.mkdir(parents=True)
        with (self.runtime.root / "supervisor.lock").open("a") as owner_lock:
            fcntl.flock(owner_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            clock = iter([0, 31])
            self.module.time = types.SimpleNamespace(monotonic=lambda: next(clock))
            self.runtime.start_embedding = Mock(side_effect=forbidden)
            self.runtime.start_ollama = Mock(side_effect=forbidden)
            self.runtime.cleanup = Mock(side_effect=forbidden)
            with self.assertRaises(self.module.RuntimeFailure):
                self.runtime.run()
            self.runtime.start_embedding.assert_not_called()
            self.runtime.start_ollama.assert_not_called()
            self.runtime.cleanup.assert_not_called()

    def test_main_reports_cleanup_failure_without_false_stopped_event(self):
        fake = Mock()
        fake.children = [("unreleased-owned-group", object())]
        fake.run.side_effect = self.module.RuntimeFailure("synthetic cleanup failure")
        with patch.object(self.module, "Supervisor", return_value=fake), \
                patch.object(self.module.threading, "Thread") as thread, \
                patch.object(self.module.signal, "signal"), \
                patch.object(sys, "argv", [
                    "supervisor", "--parent-pid", str(os.getppid()),
                    "--embedding-url", "http://localhost:8871",
                    "--ollama-url", "http://localhost:11434",
                ]):
            self.assertEqual(self.module.main(), 1)
            self.assertEqual(thread.call_count, 2)
        self.assertEqual(self.events, [{"event": "error", "message": "synthetic cleanup failure"}])


# The worker and its descendant intentionally stay in one freshly created group.
# The unrelated control worker gets its own session and must survive cleanup.
WORKER = textwrap.dedent("""
    import json, os, pathlib, signal, subprocess, sys, time
    path, mode = sys.argv[1:]
    child_code = 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(90)'
    child = subprocess.Popen([sys.executable, '-B', '-c', child_code])
    if mode == 'ignore':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(.12)
    pathlib.Path(path).write_text(json.dumps({'leader':os.getpid(),'child':child.pid,'pgid':os.getpgrp()}))
    if mode == 'leader-exits':
        sys.exit(0)
    time.sleep(90)
""")


def wait_for_file(path, timeout=6):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            try:
                return json.loads(path.read_text())
            except json.JSONDecodeError:
                pass
        time.sleep(0.02)
    raise AssertionError(f"Fixture did not become ready: {path.name}")


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_gone(pids, timeout=7):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if all(not alive(pid) for pid in pids):
            return
        time.sleep(0.03)
    raise AssertionError(f"Fixture processes survived cleanup: {[pid for pid in pids if alive(pid)]}")


def kill_fixture_group(process):
    # Only PIDs returned by this test's own Popen are passed here.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        # macOS can return EPERM for a dying group. Rescue still reaps this
        # exact child; this exception is deliberately NOT hidden in production.
        if process.poll() is None:
            raise
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is not None:
            stream.close()


@unittest.skipUnless(os.name == "posix", "Process-group checks require POSIX")
class RealGroupTests(OfflineCase):
    def setUp(self):
        super().setUp()
        self.real_children = []
        self.worker_pids = []
        self.addCleanup(self.rescue)

        def safe_popen(args, **kwargs):
            self.assertEqual(args[:4], [PYTHON, "-B", "-c", WORKER])
            self.assertTrue(Path(args[4]).is_relative_to(self.home))
            self.assertEqual(kwargs.get("start_new_session"), True)
            self.assertEqual(kwargs.get("stdin"), subprocess.DEVNULL)
            child = subprocess.Popen(args, **kwargs)
            self.real_children.append(child)
            return child

        self.module.subprocess.Popen = safe_popen

        def safe_group_probe(args, **kwargs):
            self.assertEqual(args, ["/bin/ps", "-axo", "pgid="])
            self.assertEqual(kwargs, {"capture_output": True, "text": True, "timeout": 3})
            return subprocess.run(args, **kwargs)

        self.module.subprocess.run = safe_group_probe

    def rescue(self):
        for child in self.real_children:
            kill_fixture_group(child)
        wait_gone(self.worker_pids)

    def worker(self, name="worker", mode="ignore"):
        marker = self.home / (name + ".json")
        child = self.runtime.spawn(
            name, [PYTHON, "-B", "-c", WORKER, str(marker), mode],
            self.home / name, {"PATH": "/usr/bin:/bin"},
        )
        data = wait_for_file(marker)
        self.worker_pids.extend([data["leader"], data["child"]])
        self.assertEqual(data["leader"], data["pgid"])
        self.assertEqual(data["leader"], child.pid)
        return child, data

    def test_cleanup_kills_term_resistant_leader_and_descendant_but_not_control(self):
        child, data = self.worker()
        control = subprocess.Popen(
            [PYTHON, "-B", "-c", "import time; time.sleep(90)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
        self.real_children.append(control)
        self.runtime.cleanup(grace=0.1)
        wait_gone([data["leader"], data["child"]])
        self.assertEqual(child.returncode, -signal.SIGKILL)
        self.assertIsNone(control.poll(), "Cleanup stopped a process it did not spawn")
        self.assertEqual(self.runtime.children, [])
        self.runtime.cleanup(grace=0)
        self.assertIsNone(control.poll())

    def test_cleanup_reaches_descendant_after_leader_already_exited(self):
        child, data = self.worker(mode="leader-exits")
        self.assertEqual(child.wait(timeout=3), 0)
        self.assertTrue(alive(data["child"]))
        self.runtime.cleanup(grace=0.1)
        wait_gone([data["child"]])
        self.assertEqual(self.runtime.children, [])

    def test_run_cleans_first_group_when_second_start_fails(self):
        records = []

        def first():
            records.append(self.worker()[1])
            return "managed"

        self.runtime.start_embedding = first
        self.runtime.start_ollama = Mock(side_effect=self.module.RuntimeFailure("synthetic second-start failure"))
        cleanup = self.runtime.cleanup
        self.runtime.cleanup = lambda: cleanup(grace=0.1)
        with self.assertRaisesRegex(self.module.RuntimeFailure, "second-start"):
            self.runtime.run()
        wait_gone([records[0]["leader"], records[0]["child"]])
        self.assertEqual(self.runtime.children, [])
        self.assertNotIn("ready", [event["event"] for event in self.events])

    def test_run_cleans_all_groups_when_second_start_fails_after_spawn(self):
        records = []

        def first():
            records.append(self.worker("first")[1])
            return "managed"

        def second():
            records.append(self.worker("second")[1])
            raise ValueError("synthetic failure after second spawn")

        self.runtime.start_embedding = first
        self.runtime.start_ollama = second
        cleanup = self.runtime.cleanup
        self.runtime.cleanup = lambda: cleanup(grace=0.1)
        with self.assertRaisesRegex(ValueError, "second spawn"):
            self.runtime.run()
        wait_gone([record[key] for record in records for key in ("leader", "child")])
        self.assertEqual(self.runtime.children, [])

    def test_cancellation_immediately_after_spawn_cleans_owned_group(self):
        records = []

        def first():
            child, data = self.worker()
            records.append(data)
            self.runtime.stop_event.set()
            self.runtime.await_ready(child, 8871, "/health", lambda x: True, 0)

        self.runtime.start_embedding = first
        self.runtime.start_ollama = Mock(side_effect=forbidden)
        cleanup = self.runtime.cleanup
        self.runtime.cleanup = lambda: cleanup(grace=0.1)
        with self.assertRaises(self.module.Stopping):
            self.runtime.run()
        wait_gone([records[0]["leader"], records[0]["child"]])
        self.runtime.start_ollama.assert_not_called()

    def test_second_popen_failure_still_cleans_first_group(self):
        records = []

        def first():
            records.append(self.worker()[1])
            self.module.subprocess.Popen = Mock(side_effect=OSError("synthetic cannot spawn"))
            return "managed"

        self.runtime.start_embedding = first
        self.runtime.start_ollama = lambda: self.worker("second")
        cleanup = self.runtime.cleanup
        self.runtime.cleanup = lambda: cleanup(grace=0.1)
        with self.assertRaisesRegex(OSError, "cannot spawn"):
            self.runtime.run()
        wait_gone([records[0]["leader"], records[0]["child"]])


# A separate helper runs the production main/run/watchers and production
# spawn/cleanup. Only startup/model IO is replaced; no monkeypatch of parent
# polling, stdin handling, flock, process groups, or signals.
HELPER = textwrap.dedent("""
    import json, os, pathlib, sys, types
    source, home, marker, worker = sys.argv[1:]
    module = types.ModuleType('fixture_supervisor')
    module.__file__ = source
    exec(compile(pathlib.Path(source).read_bytes(), source, 'exec'), module.__dict__)
    def blocked(*a, **kw):
        raise AssertionError('Forbidden real service operation')
    module.launchctl = module.port_busy = module.listener_pids = blocked
    module.socket = types.SimpleNamespace(socket=blocked)
    original_init = module.Supervisor.__init__
    def init(self, parent_pid, embedding_url, ollama_url):
        original_init(self, parent_pid, embedding_url, ollama_url, home=home)
        self.opener.open = blocked
    module.Supervisor.__init__ = init
    original_cleanup = module.Supervisor.cleanup
    module.Supervisor.cleanup = lambda self: original_cleanup(self, grace=.1)
    def start(self):
        self.spawn('worker', [sys.executable, '-B', '-c', worker, marker, 'ignore'],
                   pathlib.Path(home)/'worker', {'PATH':'/usr/bin:/bin'})
        return 'managed'
    module.Supervisor.start_embedding = start
    module.Supervisor.start_ollama = lambda self: 'external'
    sys.argv = ['supervisor', '--parent-pid', str(os.getppid()),
                '--embedding-url', 'http://127.0.0.1:8871',
                '--ollama-url', 'http://127.0.0.1:11434']
    sys.exit(module.main())
""")

PARENT = textwrap.dedent("""
    import json, os, pathlib, subprocess, sys, time
    helper, source, home, marker, worker, parent_marker, out, err = sys.argv[1:]
    with open(out, 'w') as stdout, open(err, 'w') as stderr:
        process = subprocess.Popen(
            [sys.executable, '-B', '-c', helper, source, home, marker, worker],
            stdin=subprocess.PIPE, stdout=stdout, stderr=stderr,
            start_new_session=True)
    # Deliberately keep an extra pipe writer in this test's process. EOF cannot
    # explain cleanup after this synthetic parent receives SIGKILL.
    import array, socket
    channel = socket.socket(fileno=int(os.environ['FIXTURE_FD']))
    channel.sendmsg([b'w'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [process.stdin.fileno()]))])
    channel.close()
    pathlib.Path(parent_marker).write_text(json.dumps({'helper':process.pid,'parent':os.getpid()}))
    time.sleep(90)
""")


@unittest.skipUnless(os.name == "posix", "Process lifecycle checks require POSIX")
class HelperProtocolTests(OfflineCase):
    def setUp(self):
        super().setUp()
        self.snapshot = self.home / "supervisor_snapshot.py"
        self.snapshot.write_bytes(SOURCE)
        self.processes = []
        self.fixture_groups = []
        self.addCleanup(self.rescue)

    def rescue(self):
        for pgid in self.fixture_groups:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                # Test-only cleanup: the assertion paths check the exact PIDs.
                pass
        for process in self.processes:
            kill_fixture_group(process)

    def helper(self, name="one"):
        marker = self.home / (name + ".json")
        stdout = self.stack.enter_context((self.home / (name + ".stdout")).open("w"))
        stderr = self.stack.enter_context((self.home / (name + ".stderr")).open("w"))
        process = subprocess.Popen(
            [PYTHON, "-B", "-c", HELPER, str(self.snapshot), str(self.home), str(marker), WORKER],
            stdin=subprocess.PIPE, stdout=stdout, stderr=stderr, start_new_session=True,
        )
        self.processes.append(process)
        return process, marker

    def record_worker(self, marker):
        data = wait_for_file(marker)
        self.fixture_groups.append(data["pgid"])
        return data

    def events_for(self, name="one"):
        return [json.loads(line) for line in (self.home / (name + ".stdout")).read_text().splitlines()]

    def test_stdin_stop_cleans_real_worker_and_child(self):
        helper, marker = self.helper()
        data = self.record_worker(marker)
        helper.stdin.write(b"stop\n")
        helper.stdin.flush()
        self.assertEqual(helper.wait(timeout=10), 0)
        wait_gone([data["leader"], data["child"]])
        self.assertEqual([event["event"] for event in self.events_for()], ["ready", "stopped"])

    def test_stdin_eof_cleans_real_worker_and_child(self):
        helper, marker = self.helper()
        data = self.record_worker(marker)
        helper.stdin.close()
        self.assertEqual(helper.wait(timeout=10), 0)
        wait_gone([data["leader"], data["child"]])
        self.assertEqual(self.events_for()[-1]["event"], "stopped")

    def test_sigterm_to_helper_requests_cleanup(self):
        helper, marker = self.helper()
        data = self.record_worker(marker)
        helper.send_signal(signal.SIGTERM)
        self.assertEqual(helper.wait(timeout=10), 0)
        wait_gone([data["leader"], data["child"]])
        self.assertEqual(self.events_for()[-1]["event"], "stopped")

    @unittest.skipUnless(sys.platform == "darwin", "Strong parent-death fixture uses macOS reaping semantics")
    def test_force_killed_parent_cleans_group_even_with_stdin_writer_kept_open(self):
        import array
        import socket

        receiver, sender = socket.socketpair()
        self.addCleanup(receiver.close)
        self.addCleanup(sender.close)
        marker = self.home / "worker.json"
        parent_marker = self.home / "parent.json"
        out, err = self.home / "parent.stdout", self.home / "parent.stderr"
        parent = subprocess.Popen(
            [PYTHON, "-B", "-c", PARENT, HELPER, str(self.snapshot), str(self.home),
             str(marker), WORKER, str(parent_marker), str(out), str(err)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True, pass_fds=(sender.fileno(),),
            env={"PATH": "/usr/bin:/bin", "FIXTURE_FD": str(sender.fileno())},
        )
        self.processes.append(parent)
        sender.close()
        receiver.settimeout(6)
        _, ancillary, _, _ = receiver.recvmsg(1, socket.CMSG_SPACE(array.array("i").itemsize))
        descriptors = array.array("i")
        descriptors.frombytes(ancillary[0][2][:descriptors.itemsize])
        writer = os.fdopen(descriptors[0], "wb", buffering=0)
        self.addCleanup(writer.close)
        parent_data = wait_for_file(parent_marker)
        self.fixture_groups.append(parent_data["helper"])
        data = self.record_worker(marker)
        parent.kill()
        self.assertEqual(parent.wait(timeout=3), -signal.SIGKILL)
        wait_gone([parent_data["helper"], data["leader"], data["child"]], timeout=10)
        self.assertFalse(writer.closed, "Parent-death test must not rely on stdin EOF")
        events = [json.loads(line) for line in out.read_text().splitlines()]
        self.assertEqual(events[-1]["event"], "stopped")

    def test_duplicate_waits_for_lock_and_cancel_does_not_touch_owner(self):
        owner, first_marker = self.helper("one")
        first = self.record_worker(first_marker)
        duplicate, second_marker = self.helper("two")
        time.sleep(0.35)
        self.assertIsNone(duplicate.poll())
        self.assertFalse(second_marker.exists(), "Duplicate started before acquiring the lifecycle lock")
        duplicate.stdin.write(b"stop\n")
        duplicate.stdin.flush()
        self.assertEqual(duplicate.wait(timeout=5), 0)
        self.assertEqual(self.events_for("two"), [{"event": "stopped"}])
        self.assertIsNone(owner.poll())
        self.assertTrue(alive(first["child"]))
        owner.stdin.close()
        self.assertEqual(owner.wait(timeout=10), 0)
        wait_gone([first["leader"], first["child"]])

    def test_lock_is_released_only_after_previous_cleanup(self):
        owner, first_marker = self.helper("one")
        first = self.record_worker(first_marker)
        duplicate, second_marker = self.helper("two")
        time.sleep(0.25)
        self.assertFalse(second_marker.exists())
        owner.stdin.close()
        self.assertEqual(owner.wait(timeout=10), 0)
        second = self.record_worker(second_marker)
        wait_gone([first["leader"], first["child"]])
        duplicate.stdin.close()
        self.assertEqual(duplicate.wait(timeout=10), 0)
        wait_gone([second["leader"], second["child"]])


if __name__ == "__main__":
    print(f"supervisor_sha256={SOURCE_SHA256}", flush=True)
    print(f"test_sha256={hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}", flush=True)
    print(f"python={sys.version.split()[0]} platform={sys.platform}", flush=True)
    unittest.main(verbosity=2)
