"""Install/start/stop only this service's macOS LaunchAgent."""

import argparse
import json
import os
import plistlib
import re
import socket
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path.home() / "Library/Application Support/AskBase/EmbeddingGemma2"
CONFIG = json.loads((ROOT / "config.json").read_text())
LABEL = "local.askbase.embeddinggemma2"
DOMAIN = f"gui/{os.getuid()}"
TARGET = f"{DOMAIN}/{LABEL}"
PLIST = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
BASE_URL = f"http://{CONFIG['host']}:{CONFIG['port']}"


def run(*arguments):
    return subprocess.run(
        ["launchctl", *arguments], capture_output=True, text=True, check=False
    )


def definition():
    return {
        "Label": LABEL,
        "ProgramArguments": [
            "/usr/bin/env", "-i",
            f"PATH={ROOT / '.venv/bin'}:/usr/bin:/bin",
            "LANG=en_US.UTF-8",
            "PYTHONUNBUFFERED=1",
            "HF_HUB_OFFLINE=1",
            "TRANSFORMERS_OFFLINE=1",
            "HF_HUB_DISABLE_IMPLICIT_TOKEN=1",
            "TOKENIZERS_PARALLELISM=false",
            str(ROOT / ".venv/bin/python"),
            str(ROOT / "server.py"),
        ],
        "WorkingDirectory": str(ROOT),
        "RunAtLoad": False,
        "KeepAlive": False,
        "ThrottleInterval": 30,
        "ExitTimeOut": 20,
        "StandardOutPath": str(ROOT / "logs/service.stdout.log"),
        "StandardErrorPath": str(ROOT / "logs/service.stderr.log"),
    }


def verify_owned_plist():
    if not PLIST.exists():
        return
    value = plistlib.loads(PLIST.read_bytes())
    expected = definition()
    if (
        value.get("Label") != LABEL
        or value.get("ProgramArguments") != expected["ProgramArguments"]
        or value.get("WorkingDirectory") != expected["WorkingDirectory"]
    ):
        raise RuntimeError(f"Existing LaunchAgent belongs to another checkout: {PLIST}")
    return value


def loaded():
    return run("print", TARGET).returncode == 0


def verify_loaded_identity():
    result = run("print", TARGET)
    if result.returncode:
        return None
    # launchctl output may include inherited credentials. Never log or return
    # the raw text; retain only this job's explicitly selected identity fields.
    arguments_match = re.search(
        r"(?ms)^\s*arguments = \{\n(.*?)^\s*\}", result.stdout
    )
    program_match = re.search(r"(?m)^\s*program = (.+)$", result.stdout)
    directory_match = re.search(r"(?m)^\s*working directory = (.+)$", result.stdout)
    pid_match = re.search(r"(?m)^\s*pid = (\d+)$", result.stdout)
    if not (arguments_match and program_match and directory_match):
        raise RuntimeError("Cannot verify loaded LaunchAgent ownership; no action taken")
    identity = {
        "program": program_match.group(1).strip(),
        "arguments": [line.strip() for line in arguments_match.group(1).splitlines() if line.strip()],
        "working_directory": directory_match.group(1).strip(),
        "pid": int(pid_match.group(1)) if pid_match else None,
    }
    expected = definition()
    if (
        identity["program"] != expected["ProgramArguments"][0]
        or identity["arguments"] != expected["ProgramArguments"]
        or identity["working_directory"] != expected["WorkingDirectory"]
    ):
        raise RuntimeError("Loaded LaunchAgent belongs to another checkout; no action taken")
    return identity


def health():
    try:
        with urllib.request.urlopen(f"{BASE_URL}/health", timeout=2) as response:
            return json.load(response)
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None


def stop():
    verify_owned_plist()
    if verify_loaded_identity() is not None:
        result = run("bootout", TARGET)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        deadline = time.monotonic() + 20
        while loaded() and time.monotonic() < deadline:
            time.sleep(0.2)
        if loaded():
            raise RuntimeError("LaunchAgent did not stop within 20 seconds")


def start():
    data = verify_owned_plist()
    expected = definition()
    if data is not None:
        # Only these two lifecycle policies may differ from an older install.
        data.update(RunAtLoad=False, KeepAlive=False)
        if data != expected:
            raise RuntimeError("Existing LaunchAgent configuration differs; it was left unchanged")
    else:
        data = expected
    already_loaded = verify_loaded_identity() is not None
    if not already_loaded:
        with socket.socket() as sock:
            if sock.connect_ex((CONFIG["host"], CONFIG["port"])) == 0:
                raise RuntimeError(f"Port {CONFIG['port']} is already occupied; no process was stopped")
    # Updating the plist does not reload an already running legacy job. The app
    # supervisor handles that takeover after verifying ownership.
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    temporary = PLIST.with_suffix(".plist.tmp")
    try:
        temporary.write_bytes(plistlib.dumps(data))
        temporary.chmod(0o600)
        temporary.replace(PLIST)
    finally:
        temporary.unlink(missing_ok=True)
    (ROOT / "launchd.plist").write_bytes(plistlib.dumps(data))
    if not already_loaded:
        result = run("bootstrap", DOMAIN, str(PLIST))
        if result.returncode:
            raise RuntimeError(f"launchd bootstrap failed (code {result.returncode}); no fallback job was started")
    if verify_loaded_identity() is None:
        raise RuntimeError("The verified LaunchAgent is no longer loaded; no fallback job was started")
    # RunAtLoad is disabled, so bootstrap alone does not start a fresh service.
    # Do not use -k: an already running process must not be killed or restarted.
    result = run("kickstart", TARGET)
    if result.returncode:
        raise RuntimeError(f"launchd kickstart failed (code {result.returncode})")
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        response = health()
        if (
            response
            and response.get("status") == "ok"
            and response.get("revision") == CONFIG["revision"]
            and response.get("model") == CONFIG["model_id"]
        ):
            return response
        time.sleep(0.5)
    raise RuntimeError("Service did not become ready; inspect logs/service.stderr.log")


def status():
    return {
        "label": LABEL,
        "loaded": loaded(),
        "plist": str(PLIST),
        "url": BASE_URL,
        "health": health(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["start", "stop", "restart", "status", "uninstall"])
    action = parser.parse_args().action
    if action in ("stop", "restart", "uninstall"):
        stop()
    if action == "uninstall":
        verify_owned_plist()
        PLIST.unlink(missing_ok=True)
    if action in ("start", "restart"):
        start()
    print(json.dumps(status(), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
