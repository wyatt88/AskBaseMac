"""Download a pinned, public checkpoint and verify the published file hashes."""

import hashlib
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

os.environ.setdefault("HF_HUB_DISABLE_IMPLICIT_TOKEN", "1")
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

from huggingface_hub import snapshot_download

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "google/embeddinggemma-2"
REVISION = "914f7f89142e33e77833254d9c9b90c3cef7303b"
DESTINATION = ROOT / "models" / REVISION


def main():
    started = time.monotonic()
    print(f"Downloading {REPOSITORY}@{REVISION}", flush=True)
    snapshot_download(
        REPOSITORY,
        revision=REVISION,
        local_dir=DESTINATION,
        token=False,
        max_workers=4,
        allow_patterns=[
            "*.json",
            "*.md",
            "*.jinja",
            "*.safetensors",
            "*.model",
        ],
    )
    published = json.loads((ROOT / "evidence/official-file-tree.json").read_text())
    checked = []
    for item in published:
        if item["type"] != "file" or item["path"] == ".gitattributes":
            continue
        path = DESTINATION / item["path"]
        size = path.stat().st_size
        with path.open("rb") as source:
            sha256 = hashlib.file_digest(source, "sha256").hexdigest()
        if "lfs" in item:
            expected = item["lfs"]["oid"]
            matched = sha256 == expected
        else:
            raw = path.read_bytes()
            expected = item["oid"]
            git_hash = hashlib.sha1(f"blob {size}\0".encode() + raw).hexdigest()
            matched = git_hash == expected
        if size != item["size"] or not matched:
            raise RuntimeError(f"Published hash/size mismatch: {item['path']}")
        checked.append(
            {"path": item["path"], "bytes": size, "sha256": sha256, "verified": True}
        )
    result = {
        "repository": REPOSITORY,
        "revision": REVISION,
        "local_path": str(DESTINATION),
        "completed_utc": datetime.now(timezone.utc).isoformat(),
        "download_and_verification_seconds": time.monotonic() - started,
        "total_bytes": sum(item["bytes"] for item in checked),
        "files": checked,
    }
    target = ROOT / "evidence/model-download.json"
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "files"}, indent=2))


if __name__ == "__main__":
    main()
