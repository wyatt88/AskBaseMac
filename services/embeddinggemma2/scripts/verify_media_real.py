#!/usr/bin/env python3
"""Bounded, synthetic native-media smoke test against an in-process ASGI app.

Explicit --execute-gpu is required. Reads the installed checkpoint and Python
environment, but writes only evidence under this source service directory.
Does not bind a port, copy runtime files, change launchd, or restart any service.
Budget: one TextEncoder + one full model load, six paired text-alignment rows,
ten media requests (no automatic retries). No user's media or library is read.
"""

import argparse
import asyncio
import base64
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path.home() / "Library/Application Support/AskBase/EmbeddingGemma2"
OUTPUT = ROOT / "evidence/media-real-validation.json"
MAX_MEDIA_INPUTS = 12


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def installed_files():
    return {
        name: file_hash(RUNTIME / name)
        for name in ("encoder.py", "server.py", "config.json", "requirements.lock.txt", "scripts/manage.py")
    }


def synthetic_fixtures():
    import numpy as np
    from PIL import Image, ImageDraw

    def picture(shape, x=56):
        image = Image.new("RGB", (256, 144), "white")
        draw = ImageDraw.Draw(image)
        if shape == "square":
            draw.rectangle((x, 42, x + 52, 94), fill=(230, 30, 30))
        else:
            draw.ellipse((95, 42, 147, 94), fill=(30, 60, 230))
        output = io.BytesIO()
        image.save(output, format="JPEG", quality=90)
        return base64.b64encode(output.getvalue()).decode("ascii")

    def tone(seconds, frequency):
        t = np.arange(int(seconds * 16000), dtype=np.float64) / 16000
        waveform = np.round(np.sin(2 * np.pi * frequency * t) * 8191).astype("<i2")
        output = io.BytesIO()
        with wave.open(output, "wb") as stream:
            stream.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            stream.writeframes(waveform.tobytes())
        return base64.b64encode(output.getvalue()).decode("ascii")

    square, circle = picture("square"), picture("circle")
    frames = [picture("square", 10 + index * 25) for index in range(8)]
    short, high, long = tone(1, 440), tone(1, 880), tone(10, 440)
    times = [0.0, 1.25, 2.5, 3.75, 5.0, 6.25, 7.5, 9.99]
    return [
        ("image_square_document", "document", {"kind": "image", "images": [square]}),
        ("image_square_query", "query", {"kind": "image", "images": [square]}),
        ("image_circle_document", "document", {"kind": "image", "images": [circle]}),
        ("audio_one_second", "document", {"kind": "audio", "audio": short}),
        ("audio_other_frequency_query", "query", {"kind": "audio", "audio": high}),
        ("audio_ten_seconds", "document", {"kind": "audio", "audio": long}),
        ("video_one_frame", "document", {"kind": "video", "images": [square], "timestamps": [0.0]}),
        ("video_eight_frames", "document", {"kind": "video", "images": frames, "timestamps": times}),
        ("video_eight_frames_audio", "document", {"kind": "video", "images": frames, "timestamps": times, "audio": long}),
        ("video_repeat_query", "query", {"kind": "video", "images": frames, "timestamps": times}),
    ]


async def verify(report):
    import httpx
    import mlx.core as mx
    import numpy as np

    sys.path.insert(0, str(ROOT))
    import encoder as original_encoder
    import server
    from media_encoder import MediaEncoder

    # Only this module variable is redirected to READ the installed checkpoint.
    # server.ROOT remains the repository, so its startup evidence stays in scope.
    original_encoder.ROOT = RUNTIME
    server.media_encoder = MediaEncoder(server.encoder, server.CONFIG, RUNTIME)
    async with httpx.AsyncClient(trust_env=False, follow_redirects=False, timeout=3) as live:
        try:
            response = await live.get("http://127.0.0.1:8871/health")
            response.raise_for_status()
            before = response.json()
            report["installed_service_before"] = {
                key: before.get(key) for key in ("status", "model", "revision", "encoder_signature", "modalities")
            }
        except (httpx.HTTPError, ValueError) as exc:
            report["installed_service_before"] = {"read_error_type": type(exc).__name__}
    async with server.lifespan(server.app):
        if not server.media_encoder.ready:
            raise RuntimeError("Media startup/alignment failed; no media inference attempted")
        report["startup"] = server.media_encoder.startup
        if len(report["startup"]["text_alignment"]) != 6:
            raise RuntimeError("Unexpected text-alignment budget")
        report["encoder_signature"] = server.encoder.signature
        report["media_encoder_signature"] = server.media_encoder.signature
        prior_signature = report["installed_service_before"].get("encoder_signature")
        report["matches_installed_text_signature"] = (
            prior_signature == server.encoder.signature if prior_signature else None
        )
        if prior_signature and prior_signature != server.encoder.signature:
            raise RuntimeError("Original installed text signature changed")
        transport = httpx.ASGITransport(app=server.app)
        async with httpx.AsyncClient(transport=transport, base_url="http://127.0.0.1", timeout=None) as client:
            report["isolated_health"] = (await client.get("/health")).json()
            vectors = {}
            for name, input_type, media in synthetic_fixtures():
                if report["media_inputs_attempted"] >= MAX_MEDIA_INPUTS:
                    raise RuntimeError("Media verification budget exhausted")
                report["media_inputs_attempted"] += 1
                started = time.perf_counter()
                payload = {
                    "model": "embeddinggemma-2", "input_type": input_type,
                    "dimensions": 768, "input": media,
                }
                reply = await client.post("/v1/media/embeddings", json=payload)
                row = {
                    "fixture": name, "kind": media["kind"], "input_type": input_type,
                    "frames": len(media.get("images", [])),
                    "audio_present": "audio" in media,
                    "fixture_sha256": hashlib.sha256(
                        json.dumps(media, sort_keys=True).encode()
                    ).hexdigest(),
                    "http_status": reply.status_code,
                    "elapsed_seconds": time.perf_counter() - started,
                }
                report["media_results"].append(row)
                if reply.status_code != 200:
                    row["error"] = reply.json()
                    raise RuntimeError(f"Synthetic media fixture failed: {name}")
                body = reply.json()
                vector = np.asarray(body["data"][0]["embedding"], dtype=np.float32)
                norm = float(np.linalg.norm(vector))
                row.update({
                    "dimensions": len(vector),
                    "finite": bool(np.isfinite(vector).all()),
                    "norm": norm,
                    "prompt_tokens": body["usage"]["prompt_tokens"],
                    "vector_sha256": hashlib.sha256(vector.tobytes()).hexdigest(),
                    "shared_signature_matches": body["encoder_signature"] == server.encoder.signature,
                    "media_signature_matches": body["media_encoder_signature"] == server.media_encoder.signature,
                })
                if (
                    vector.shape != (768,) or not row["finite"] or abs(norm - 1) > 1e-4
                    or not row["shared_signature_matches"] or not row["media_signature_matches"]
                    or body["input_type"] != input_type or body["dimensions"] != 768
                ):
                    raise RuntimeError(f"Embedding contract failed: {name}")
                vectors[name] = vector
                print(json.dumps(row), flush=True)
            report["content_and_repeat_checks"] = {
                "image_query_document_equal": bool(np.array_equal(
                    vectors["image_square_document"], vectors["image_square_query"]
                )),
                "video_query_document_equal": bool(np.array_equal(
                    vectors["video_eight_frames"], vectors["video_repeat_query"]
                )),
                "different_images_change_embedding": bool(not np.array_equal(
                    vectors["image_square_document"], vectors["image_circle_document"]
                )),
                "different_audio_changes_embedding": bool(not np.array_equal(
                    vectors["audio_one_second"], vectors["audio_other_frequency_query"]
                )),
                "video_audio_changes_embedding": bool(not np.array_equal(
                    vectors["video_eight_frames"], vectors["video_eight_frames_audio"]
                )),
            }
            if not all(report["content_and_repeat_checks"].values()):
                raise RuntimeError("A content sensitivity or repeat check failed")
            report["mlx_memory"] = {
                "active_bytes": mx.get_active_memory(),
                "peak_bytes": mx.get_peak_memory(),
                "cache_bytes": mx.get_cache_memory(),
            }
    async with httpx.AsyncClient(trust_env=False, follow_redirects=False, timeout=3) as live:
        try:
            response = await live.get("http://127.0.0.1:8871/health")
            response.raise_for_status()
            after = response.json()
            report["installed_service_after"] = {
                key: after.get(key) for key in ("status", "model", "revision", "encoder_signature", "modalities")
            }
        except (httpx.HTTPError, ValueError) as exc:
            report["installed_service_after"] = {"read_error_type": type(exc).__name__}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute-gpu", action="store_true")
    args = parser.parse_args()
    if not args.execute_gpu:
        parser.error("Notify the coordinator, then pass --execute-gpu for the authorized bounded run")
    if OUTPUT.exists():
        raise SystemExit("A real-run report already exists. Review its consumed budget before another run.")
    for name in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_IMPLICIT_TOKEN"):
        os.environ[name] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    pressure = subprocess.run(
        ["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
        capture_output=True, text=True, check=True,
    )
    if pressure.stdout.strip() != "1":
        raise SystemExit("memory_pressure_not_normal; no GPU work submitted")
    report = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "status": "running",
        "scope": "synthetic engineering smoke and exact text parity; not corpus quality or E4",
        "model_loads_planned": {"text": 1, "full_multimodal": 1},
        "media_inputs_attempted": 0,
        "media_results": [],
        "source_sha256": {
            name: file_hash(ROOT / name)
            for name in ("encoder.py", "media_encoder.py", "server.py", "config.json")
        },
        "installed_files_before": installed_files(),
    }
    try:
        asyncio.run(verify(report))
        report["status"] = "passed"
    except Exception as exc:
        report["status"] = "failed"
        report["error_type"] = type(exc).__name__
        report["error"] = str(exc)  # This runner accepts only its own synthetic fixtures.
        raise
    finally:
        report["installed_files_after"] = installed_files()
        report["installed_files_unchanged"] = (
            report["installed_files_before"] == report["installed_files_after"]
        )
        report["completed_utc"] = datetime.now(timezone.utc).isoformat()
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(f"Evidence: {OUTPUT}", flush=True)


if __name__ == "__main__":
    main()
