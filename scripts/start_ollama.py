#!/usr/bin/env python3
"""Start installed Ollama as a loopback-only user service; never download a model."""
import json
import fcntl
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import subprocess
import time
import tempfile
import urllib.request

LABEL = "local.askbasemac.ollama"
DOMAIN = f"gui/{os.getuid()}"
ROOT = Path.home() / "Library/Application Support/AskBaseMac/Ollama"
PLIST = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"


def local_models():
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open("http://127.0.0.1:11434/api/tags", timeout=2) as response:
        payload = json.load(response)
    return [model["name"] for model in payload["models"]]


def loaded_identity_matches(definition):
    result = subprocess.run(["launchctl", "print", f"{DOMAIN}/{LABEL}"], capture_output=True, text=True)
    if result.returncode:
        if "Could not find service" in result.stderr or result.returncode == 113:
            return False
        raise SystemExit("Cannot inspect the existing launch job; no service was changed.")
    # Raw launchctl output can contain inherited credentials. Never log it.
    arguments = re.search(r"(?ms)^\s*arguments = \{\n(.*?)^\s*\}", result.stdout)
    program = re.search(r"(?m)^\s*program = (.+)$", result.stdout)
    directory = re.search(r"(?m)^\s*working directory = (.+)$", result.stdout)
    if not (arguments and program and directory):
        raise SystemExit("Cannot verify the loaded service identity; no service was changed.")
    actual_arguments = [line.strip() for line in arguments.group(1).splitlines() if line.strip()]
    if (actual_arguments != definition["ProgramArguments"]
            or program.group(1).strip() != definition["ProgramArguments"][0]
            or directory.group(1).strip() != definition["WorkingDirectory"]):
        raise SystemExit("A different loaded job uses this label; no service was changed.")
    return True


def start():
    try:
        models = local_models()
        print(json.dumps({"status": "already_running", "models": models}, ensure_ascii=False))
        return
    except Exception:
        pass
    with socket.socket() as listener:
        if listener.connect_ex(("127.0.0.1", 11434)) == 0:
            raise SystemExit("Port 11434 is occupied by another service. No process was stopped.")
    candidates = [
        shutil.which("ollama"),
        str(Path.home() / "Applications/Ollama.app/Contents/Resources/ollama"),
        "/Applications/Ollama.app/Contents/Resources/ollama",
    ]
    binary = next((str(Path(p).resolve()) for p in candidates if p and Path(p).is_file()), None)
    if binary is None:
        raise SystemExit("Install Ollama from https://ollama.com/download/mac first.")
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    definition = {
        "Label": LABEL,
        "ProgramArguments": [
            "/usr/bin/env", "-i", f"HOME={Path.home()}",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "OLLAMA_HOST=127.0.0.1:11434", "OLLAMA_NO_CLOUD=1",
            "OLLAMA_MAX_LOADED_MODELS=1", "OLLAMA_KEEP_ALIVE=5m",
            binary, "serve",
        ],
        "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 30,
        "StandardOutPath": str(ROOT / "stdout.log"),
        "StandardErrorPath": str(ROOT / "stderr.log"),
        "WorkingDirectory": str(ROOT),
    }
    if PLIST.exists() and plistlib.loads(PLIST.read_bytes()) != definition:
        raise SystemExit("An existing launch configuration differs; it was left unchanged.")
    already_loaded = loaded_identity_matches(definition)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=PLIST.parent, prefix=LABEL + ".", suffix=".tmp", delete=False) as stream:
        temp = Path(stream.name)
        stream.write(plistlib.dumps(definition))
    try:
        temp.chmod(0o600)
        temp.replace(PLIST)
    finally:
        temp.unlink(missing_ok=True)
    command = (["launchctl", "kickstart", f"{DOMAIN}/{LABEL}"] if already_loaded
               else ["launchctl", "bootstrap", DOMAIN, str(PLIST)])
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"launchd refused to start the verified job (code {result.returncode}); no fallback job was started.")
    for _ in range(20):
        try:
            models = local_models()
            print(json.dumps({"status": "running", "models": models, "launch_agent": LABEL}, ensure_ascii=False))
            return
        except Exception:
            time.sleep(1)
    raise SystemExit(f"Ollama did not become ready. Inspect {ROOT / 'stderr.log'}.")


def main():
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (ROOT / "startup.lock").open("a") as lock:
        deadline = time.monotonic() + 45
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise SystemExit("Another startup is still in progress; try again after it finishes.")
                time.sleep(0.2)
        # Health, disk definition and loaded identity are all re-read inside the lock.
        start()


if __name__ == "__main__":
    main()
