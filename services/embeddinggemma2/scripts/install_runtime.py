"""Install this deployment into the normal macOS user application-data directory."""

import hashlib
import json
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]
RUNTIME = Path.home() / "Library/Application Support/AskBase/EmbeddingGemma2"


def main():
    config = json.loads((SOURCE / "config.json").read_text())
    if (RUNTIME / "config.json").exists():
        previous = json.loads((RUNTIME / "config.json").read_text())
        if previous["revision"] != config["revision"]:
            raise RuntimeError("A different model revision is installed; preserve it before upgrading")
    for directory in ("logs", "evidence", "scripts", "models"):
        (RUNTIME / directory).mkdir(parents=True, exist_ok=True)
    # Runtime files are real files under Application Support: no symlinks back
    # into Documents, and no copying unrelated workspaces or private documents.
    copied = []
    for name in (
        "server.py", "encoder.py", "media_encoder.py", "config.json",
        "requirements.lock.txt", "scripts/manage.py",
    ):
        target = RUNTIME / name
        shutil.copy2(SOURCE / name, target)
        copied.append({"path": name, "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
    source_model = SOURCE / config["model_directory"]
    target_model = RUNTIME / config["model_directory"]
    if not target_model.exists():
        subprocess.run(["cp", "-cR", str(source_model), str(target_model)], check=True)
    manifest = json.loads((SOURCE / "evidence/model-download.json").read_text())
    for record in manifest["files"]:
        path = target_model / record["path"]
        actual = None
        if path.is_file():
            with path.open("rb") as stream:
                actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if actual != record["sha256"] or path.stat().st_size != record["bytes"]:
            source_file = source_model / record["path"]
            with source_file.open("rb") as stream:
                verified = hashlib.file_digest(stream, "sha256").hexdigest()
            if verified != record["sha256"] or source_file.stat().st_size != record["bytes"]:
                raise RuntimeError(f"Source model hash mismatch: {record['path']}")
            replacement = path.with_name(path.name + ".repair")
            shutil.copy2(source_file, replacement)
            replacement.replace(path)
    manifest["download_local_path"] = manifest["local_path"]
    manifest["local_path"] = str(target_model)
    (RUNTIME / "evidence/model-download.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    )
    uv = shutil.which("uv")
    if not uv:
        raise RuntimeError("uv is needed to install the independent runtime environment")
    if not (RUNTIME / ".venv/bin/python").exists():
        subprocess.run([uv, "venv", "--clear", "--python", "3.12", str(RUNTIME / ".venv")], check=True)
    subprocess.run([
        uv, "pip", "install",
        "--python", str(RUNTIME / ".venv/bin/python"),
        "-r", str(SOURCE / "requirements.lock.txt"),
    ], check=True)
    result = {
        "installed_utc": datetime.now(timezone.utc).isoformat(),
        "source": str(SOURCE),
        "runtime": str(RUNTIME),
        "model_revision": config["revision"],
        "verified_model_files": len(manifest["files"]),
        "application_files": copied,
        "launch_command": "env -i with explicit offline variables; no inherited cloud credentials",
    }
    (SOURCE / "evidence/runtime-installation.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    )
    marker = RUNTIME / "evidence/installation-complete.json"
    temporary = marker.with_suffix(".tmp")
    temporary.write_text(json.dumps({
        "revision": config["revision"],
        "requirements_sha256": hashlib.sha256((SOURCE / "requirements.lock.txt").read_bytes()).hexdigest(),
        "completed_utc": result["installed_utc"],
    }, indent=2) + "\n")
    temporary.replace(marker)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
