#!/usr/bin/env python3
"""Own AskBase's local model processes for exactly one application lifetime.

This helper requires only the standard library of the already installed Python.
stdout is a JSON-lines protocol; model output stays in private local log files.
No model downloads, document reads, arbitrary process kills or network fallbacks.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request


class RuntimeFailure(RuntimeError):
    pass


class Stopping(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def emit(event, **fields):
    try:
        print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)
    except (BrokenPipeError, OSError):
        # The app can disappear before its pipe is closed. Cleanup must continue.
        pass


def is_default_endpoint(value, port):
    try:
        url = urllib.parse.urlsplit(value)
        return (
            url.scheme == "http"
            and url.hostname in ("127.0.0.1", "localhost")
            and url.port == port
            and url.path in ("", "/")
            and not (url.username or url.password or url.query or url.fragment)
        )
    except ValueError:
        return False


def port_busy(port):
    with socket.socket() as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def listener_pids(port):
    result = subprocess.run(
        ["/usr/sbin/lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
        capture_output=True, text=True, timeout=5,
    )
    if result.returncode not in (0, 1):
        raise RuntimeFailure("无法核对本机服务的端口归属，未接管该服务。")
    return {int(line) for line in result.stdout.splitlines() if line.isdigit()}


def launchctl(*args):
    # Never expose captured launchctl output: inherited environments may contain secrets.
    return subprocess.run(
        ["/bin/launchctl", *args], capture_output=True, text=True, timeout=25,
    )


def loaded_identity(target):
    result = launchctl("print", target)
    if result.returncode:
        if result.returncode == 113 or "Could not find service" in result.stderr:
            return None
        raise RuntimeFailure("无法读取原有后台服务状态，未改变其配置。")
    arguments = re.search(r"(?ms)^\s*arguments = \{\n(.*?)^\s*\}", result.stdout)
    program = re.search(r"(?m)^\s*program = (.+)$", result.stdout)
    directory = re.search(r"(?m)^\s*working directory = (.+)$", result.stdout)
    pid = re.search(r"(?m)^\s*pid = (\d+)$", result.stdout)
    if not (arguments and program and directory):
        raise RuntimeFailure("无法确认原有后台服务归属，未接管该服务。")
    return {
        "program": program.group(1).strip(),
        "arguments": [line.strip() for line in arguments.group(1).splitlines() if line.strip()],
        "directory": directory.group(1).strip(),
        "pid": int(pid.group(1)) if pid else None,
    }


def matches_definition(identity, definition):
    return (
        identity["program"] == definition["ProgramArguments"][0]
        and identity["arguments"] == definition["ProgramArguments"]
        and identity["directory"] == definition["WorkingDirectory"]
    )


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + ".", delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
    try:
        temporary.chmod(0o600)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Darwin can return EPERM briefly when a killed group is disappearing.
        # Do not equate permission denial with absence: independently enumerate
        # exact group IDs, without inspecting unrelated process commands.
        result = subprocess.run(
            ["/bin/ps", "-axo", "pgid="], capture_output=True, text=True, timeout=3,
        )
        if result.returncode:
            raise RuntimeFailure("无法确认模型进程组是否已经退出。")
        return str(pgid) in {line.strip() for line in result.stdout.splitlines()}


class Supervisor:
    def __init__(self, parent_pid, embedding_url, ollama_url, home=None):
        self.home = Path(home) if home else Path.home()
        self.root = self.home / "Library/Application Support/AskBase/ModelRuntime"
        self.embedding_root = self.home / "Library/Application Support/AskBase/EmbeddingGemma2"
        self.ollama_root = self.home / "Library/Application Support/AskBaseMac/Ollama"
        self.parent_pid = parent_pid
        self.embedding_url = embedding_url
        self.ollama_url = ollama_url
        self.stop_event = threading.Event()
        self.children = []  # Each child was spawned in a new session owned by this helper.
        self.messages = []
        self.states = {"embedding": "unavailable", "ollama": "unavailable"}
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def checkpoint(self):
        if self.stop_event.is_set() or os.getppid() != self.parent_pid:
            raise Stopping()

    def pause(self, seconds):
        self.stop_event.wait(seconds)
        self.checkpoint()

    def watch_parent(self):
        while not self.stop_event.wait(0.25):
            if os.getppid() != self.parent_pid:
                self.stop_event.set()

    def watch_input(self):
        # Children have DEVNULL stdin and cannot keep this pipe alive after app death.
        try:
            for line in sys.stdin:
                if line.strip() == "stop":
                    break
        finally:
            self.stop_event.set()

    def request_stop(self, *_):
        self.stop_event.set()

    def request_json(self, port, path):
        with self.opener.open(f"http://127.0.0.1:{port}{path}", timeout=1) as response:
            return json.load(response)

    def embedding_definition(self):
        root = self.embedding_root
        return {
            "Label": "local.askbase.embeddinggemma2",
            "ProgramArguments": [
                "/usr/bin/env", "-i", f"PATH={root / '.venv/bin'}:/usr/bin:/bin",
                "LANG=en_US.UTF-8", "PYTHONUNBUFFERED=1", "HF_HUB_OFFLINE=1",
                "TRANSFORMERS_OFFLINE=1", "HF_HUB_DISABLE_IMPLICIT_TOKEN=1",
                "TOKENIZERS_PARALLELISM=false", str(root / ".venv/bin/python"), str(root / "server.py"),
            ],
            "WorkingDirectory": str(root),
        }

    def ollama_binary(self):
        candidates = [
            self.home / "Applications/Ollama.app/Contents/Resources/ollama",
            Path("/Applications/Ollama.app/Contents/Resources/ollama"),
            Path("/opt/homebrew/bin/ollama"), Path("/usr/local/bin/ollama"),
        ]
        return next((str(path.resolve()) for path in candidates if path.is_file()), None)

    def ollama_definition(self, binary):
        return {
            "Label": "local.askbasemac.ollama",
            "ProgramArguments": [
                "/usr/bin/env", "-i", f"HOME={self.home}", "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                "OLLAMA_HOST=127.0.0.1:11434", "OLLAMA_NO_CLOUD=1",
                "OLLAMA_MAX_LOADED_MODELS=1", "OLLAMA_KEEP_ALIVE=5m", binary, "serve",
            ],
            "WorkingDirectory": str(self.ollama_root),
        }

    def migrate_legacy(self, definition, port):
        """Disable only the exact AskBase LaunchAgent, then let launchd stop its job."""
        self.checkpoint()
        label = definition["Label"]
        target = f"gui/{os.getuid()}/{label}"
        plist = self.home / "Library/LaunchAgents" / f"{label}.plist"
        data = plist.read_bytes() if plist.exists() else None
        saved = plistlib.loads(data) if data else None
        if saved and any(saved.get(key) != value for key, value in definition.items()):
            raise RuntimeFailure("同名后台配置不属于当前 AskBase 安装，未接管该服务。")
        actual = loaded_identity(target)
        if actual and not matches_definition(actual, definition):
            raise RuntimeFailure("同名运行服务不属于当前 AskBase 安装，未接管该服务。")
        if actual:
            listeners = listener_pids(port)
            if listeners and listeners != {actual["pid"]}:
                raise RuntimeFailure("端口属于另一进程，未停止或接管任何服务。")
        # Preserve the original definition once, even across later application launches.
        # Disable before bootout so an interrupted migration cannot re-enable login loading.
        if saved:
            backup = self.root / "LaunchAgentBackups" / plist.name
            if not backup.exists():
                atomic_write(backup, data)
            updated = dict(saved, RunAtLoad=False, KeepAlive=False)
            atomic_write(plist, plistlib.dumps(updated))
        if actual:
            # Once ownership is verified, finish this bounded migration even if
            # app shutdown starts here. Cancelling before bootout would leave the
            # old model resident after disabling only its next-login policy.
            result = launchctl("bootout", target)
            if result.returncode:
                raise RuntimeFailure("原有 AskBase 后台服务未能停止，请重试退出后再打开应用。")
            deadline = time.monotonic() + 25
            while loaded_identity(target) is not None or port_busy(port):
                if time.monotonic() >= deadline:
                    raise RuntimeFailure("原有 AskBase 服务未及时释放端口，未创建重复服务。")
                time.sleep(0.1)

    def spawn(self, name, args, directory, environment):
        self.checkpoint()
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        logs = self.root / "logs"
        logs.mkdir(parents=True, exist_ok=True, mode=0o700)
        log_path = logs / f"{name}.log"
        # Bound accumulation across launches without touching model or user data.
        if log_path.exists() and log_path.stat().st_size > 4 * 1024 * 1024:
            log_path.replace(logs / f"{name}.previous.log")
        with log_path.open("ab") as log:
            log_path.chmod(0o600)
            child = subprocess.Popen(
                args, cwd=directory, env=environment, stdin=subprocess.DEVNULL,
                stdout=log, stderr=log, start_new_session=True, close_fds=True,
            )
        # Record immediately: cancellation between spawn and readiness still cleans it up.
        self.children.append((name, child))
        return child

    def await_ready(self, child, port, path, valid, timeout):
        deadline = time.monotonic() + timeout
        while True:
            self.checkpoint()
            if child.poll() is not None:
                raise RuntimeFailure("本地模型服务启动失败，请查看设置中的连接状态及本地服务日志。")
            try:
                if valid(self.request_json(port, path)):
                    # Health cannot establish ownership. Also verify the listener PID.
                    if listener_pids(port) != {child.pid}:
                        raise RuntimeFailure("模型端口归属已变化，已取消本次接管。")
                    return
            except (OSError, ValueError):
                pass
            if time.monotonic() >= deadline:
                raise RuntimeFailure("本地模型加载超时，已释放本次启动的服务；可重新打开应用重试。")
            self.pause(0.25)

    def start_embedding(self):
        if not is_default_endpoint(self.embedding_url, 8871):
            self.messages.append("嵌入地址由外部服务管理，退出时不会停止该外部服务。")
            return "external"
        root = self.embedding_root
        if not all((root / name).is_file() for name in (".venv/bin/python", "server.py", "config.json")):
            self.messages.append("尚未安装本地嵌入环境，请先完成模型安装。")
            return "unavailable"
        config = json.loads((root / "config.json").read_text())
        if config.get("host") != "127.0.0.1" or config.get("port") != 8871:
            self.messages.append("嵌入环境使用自定义端口，由其原启动方式管理。")
            return "external"
        self.migrate_legacy(self.embedding_definition(), 8871)
        if port_busy(8871):
            self.messages.append("嵌入端口已有外部服务，退出时保留该服务。")
            return "external"
        emit("status", message="正在加载本地嵌入模型…")
        child = self.spawn("embedding", [str(root / ".venv/bin/python"), str(root / "server.py")], root, {
            "PATH": f"{root / '.venv/bin'}:/usr/bin:/bin", "LANG": "en_US.UTF-8",
            "PYTHONUNBUFFERED": "1", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1", "TOKENIZERS_PARALLELISM": "false",
        })
        self.await_ready(child, 8871, "/health", lambda value: (
            value.get("status") == "ok" and value.get("model") == config.get("model_id")
            and value.get("revision") == config.get("revision")
        ), timeout=180)
        return "managed"

    def start_ollama(self):
        if not is_default_endpoint(self.ollama_url, 11434):
            self.messages.append("问答地址由外部服务管理，退出时不会停止该外部服务。")
            return "external"
        binary = self.ollama_binary()
        if not binary:
            self.messages.append("未找到已安装的 Ollama；资料库仍可打开。")
            return "unavailable"
        self.migrate_legacy(self.ollama_definition(binary), 11434)
        if port_busy(11434):
            self.messages.append("Ollama 由其他应用启动，退出时保留该共享服务。")
            return "external"
        emit("status", message="正在启动本地问答服务…")
        child = self.spawn("ollama", [binary, "serve"], self.ollama_root, {
            "HOME": str(self.home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "OLLAMA_HOST": "127.0.0.1:11434", "OLLAMA_NO_CLOUD": "1",
            "OLLAMA_MAX_LOADED_MODELS": "1", "OLLAMA_KEEP_ALIVE": "-1",
        })
        self.await_ready(child, 11434, "/api/tags", lambda value: isinstance(value.get("models"), list), timeout=30)
        return "managed"

    def cleanup(self, grace=15):
        """Signal every owned process group together, then reap leaders and verify."""
        children = list(reversed(self.children))
        def alive(child):
            try:
                child.poll()
                return group_alive(child.pid)
            except (OSError, RuntimeFailure, subprocess.SubprocessError):
                # Unknown is still pending, never proof that resources are gone.
                return True

        for _, child in children:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except OSError:
                # A failure in one group must not skip the other owned groups.
                # Final membership checks below decide whether cleanup succeeded.
                pass
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            remaining = [child for _, child in children if alive(child)]
            if not remaining:
                break
            time.sleep(0.05)
        for _, child in children:
            if alive(child):
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except OSError:
                    pass
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            remaining = [child for _, child in children if alive(child)]
            if not remaining:
                break
            time.sleep(0.05)
        self.children = [(name, child) for name, child in children if alive(child)]
        if self.children:
            raise RuntimeFailure("仍有本次启动的模型进程未退出：" + "、".join(name for name, _ in self.children))

    def run(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.root / "supervisor.lock").open("a") as lock:
            # A previous app may still be cleaning up while a new app opens.
            deadline = time.monotonic() + 30
            while True:
                self.checkpoint()
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise RuntimeFailure("另一份 AskBase 正在管理模型，请关闭另一份应用后重试。")
                    self.pause(0.1)
            try:
                self.states["embedding"] = self.start_embedding()
                self.states["ollama"] = self.start_ollama()
                self.checkpoint()
                emit("ready", **self.states, messages=self.messages)
                while True:
                    self.pause(0.25)
                    if any(child.poll() is not None for _, child in self.children):
                        raise RuntimeFailure("本地模型服务意外退出，请重新打开应用加载模型。")
            finally:
                self.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parent-pid", type=int, required=True)
    parser.add_argument("--embedding-url", required=True)
    parser.add_argument("--ollama-url", required=True)
    args = parser.parse_args()
    supervisor = Supervisor(args.parent_pid, args.embedding_url, args.ollama_url)
    signal.signal(signal.SIGTERM, supervisor.request_stop)
    signal.signal(signal.SIGINT, supervisor.request_stop)
    threading.Thread(target=supervisor.watch_parent, daemon=True).start()
    threading.Thread(target=supervisor.watch_input, daemon=True).start()
    code = 0
    try:
        supervisor.run()
    except Stopping:
        pass
    except RuntimeFailure as error:
        emit("error", message=str(error))
        code = 1
    except Exception as error:
        # Do not put paths, environment values or arbitrary exception bodies in the UI protocol.
        emit("error", message=f"本地服务管理失败（{type(error).__name__}），请检查安装环境。")
        code = 1
    if not supervisor.children:
        emit("stopped")
    return code


if __name__ == "__main__":
    sys.exit(main())
