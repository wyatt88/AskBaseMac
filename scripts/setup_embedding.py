#!/usr/bin/env python3
"""Prepare the pinned local embedding runtime. Existing healthy installs are reused."""
import json
import fcntl
import hashlib
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import sys
import urllib.request

SOURCE = Path(__file__).resolve().parents[1] / "services/embeddinggemma2"
RUNTIME = Path.home() / "Library/Application Support/AskBase/EmbeddingGemma2"
REVISION = "914f7f89142e33e77833254d9c9b90c3cef7303b"


def runtime_complete():
    """Check a stopped runtime without loading model weights on the GPU."""
    try:
        config = json.loads((RUNTIME / "config.json").read_text())
        if config != json.loads((SOURCE / "config.json").read_text()):
            return False
        for name in ("encoder.py", "server.py", "scripts/manage.py", "requirements.lock.txt"):
            if (RUNTIME / name).read_bytes() != (SOURCE / name).read_bytes():
                return False
        manifest = json.loads((RUNTIME / "evidence/model-download.json").read_text())
        if manifest["revision"] != REVISION:
            return False
        official = json.loads((SOURCE / "evidence/official-file-tree.json").read_text())
        expected = {entry["path"]: entry for entry in official
                    if entry["type"] == "file" and entry["path"] != ".gitattributes"}
        records = {entry["path"]: entry for entry in manifest["files"]}
        if records.keys() != expected.keys():
            return False
        for name, entry in expected.items():
            if Path(name).name != name:
                return False
            path = RUNTIME / config["model_directory"] / name
            if path.stat().st_size != entry["size"]:
                return False
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
                    digest.update(block)
            if digest.hexdigest() != records[name]["sha256"]:
                return False
            if "lfs" in entry and digest.hexdigest() != entry["lfs"]["oid"]:
                return False
            if "lfs" not in entry:
                raw = path.read_bytes()
                if hashlib.sha1(f"blob {len(raw)}\0".encode() + raw).hexdigest() != entry["oid"]:
                    return False
        check = subprocess.run([
            str(RUNTIME / ".venv/bin/python"), "-I", "-c",
            "import fastapi,uvicorn,pydantic,psutil,safetensors,transformers,mlx.core,mlx_vlm",
        ], capture_output=True, timeout=45)
        return check.returncode == 0
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
        return False


def setup():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("The bundled MLX service requires an Apple Silicon Mac.")
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open("http://127.0.0.1:8871/health", timeout=3) as response:
            health = json.load(response)
        if (health.get("model") == "embeddinggemma-2" and health.get("encoder_signature")
                and health.get("status") == "ok" and health.get("dimensions") == 768
                and health.get("revision") == REVISION):
            print("EmbeddingGemma 2 is already ready at http://127.0.0.1:8871. Reusing it.")
            return
        raise SystemExit("Port 8871 has an incompatible service. It was not changed.")
    except (OSError, ValueError):
        pass
    with socket.socket() as listener:
        if listener.connect_ex(("127.0.0.1", 8871)) == 0:
            raise SystemExit("Port 8871 is occupied. No process or model files were changed.")
    # A Python executable alone is not an installation completion marker.
    python = RUNTIME / ".venv/bin/python"
    if runtime_complete():
        subprocess.run([str(python), str(RUNTIME / "scripts/manage.py"), "start"], check=True)
        return
    uv = shutil.which("uv")
    if uv is None:
        raise SystemExit("Install uv (https://docs.astral.sh/uv/getting-started/installation/), then run this script again.")
    config_path = RUNTIME / "config.json"
    if config_path.exists():
        previous = json.loads(config_path.read_text())
        if previous.get("revision") != REVISION or previous.get("repository") != "google/embeddinggemma-2":
            raise SystemExit("A different runtime is installed; preserve it before upgrading.")
        # This checked-in manager uses only the standard library and checks both
        # the disk and loaded job identity before stopping a partial installation.
        subprocess.run([sys.executable, str(SOURCE / "scripts/manage.py"), "stop"], check=True)
    dev_python = SOURCE / ".venv/bin/python"
    if not dev_python.exists():
        subprocess.run([uv, "venv", "--clear", "--python", "3.12", str(SOURCE / ".venv")], check=True)
    subprocess.run([uv, "pip", "install", "--python", str(dev_python),
                    "-r", str(SOURCE / "requirements.lock.txt")], check=True)
    for script in ("download_model.py", "install_runtime.py", "manage.py"):
        command = [str(dev_python), str(SOURCE / "scripts" / script)]
        if script == "manage.py":
            command = [str(python), str(RUNTIME / "scripts/manage.py"), "start"]
        subprocess.run(command, cwd=SOURCE, check=True)


def main():
    RUNTIME.parent.mkdir(parents=True, exist_ok=True)
    with (RUNTIME.parent / "embeddinggemma2-setup.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Another model setup is in progress; let it finish before retrying.")
        setup()


if __name__ == "__main__":
    main()
