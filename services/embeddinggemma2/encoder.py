"""Pinned EmbeddingGemma 2 text inference on Apple Metal via MLX."""

import hashlib
import importlib.metadata
import json
import time
from collections import Counter
from pathlib import Path

import mlx.core as mx
import numpy as np
import psutil
from mlx.utils import tree_flatten
from mlx_vlm.embedding_loader import load_embedding_model
from mlx_vlm.utils import load_config
from transformers import AutoTokenizer

ROOT = Path(__file__).resolve().parent
CONFIG = json.loads((ROOT / "config.json").read_text())


def verify_model_files(path, manifest):
    """Recheck file content at startup, including equal-size modifications."""
    hashes = {}
    for item in manifest["files"]:
        target = path / item["path"]
        if not item["verified"] or target.stat().st_size != item["bytes"]:
            raise RuntimeError(f"Model file missing or changed: {item['path']}")
        with target.open("rb") as source:
            actual = hashlib.file_digest(source, "sha256").hexdigest()
        if actual != item["sha256"]:
            raise RuntimeError(f"Model file hash mismatch: {item['path']}")
        hashes[item["path"]] = actual
    return hashes


class TextEncoder:
    def __init__(self):
        self.ready = False
        self.startup = {}
        self.metrics = {}
        self.completed_requests = 0
        self.completed_inputs = 0

    def load(self):
        started = time.perf_counter()
        if not mx.metal.is_available():
            raise RuntimeError("Apple Metal is unavailable; refusing an implicit CPU fallback")
        mx.set_default_device(mx.gpu)
        mx.set_cache_limit(256 * 1024 * 1024)
        mx.set_memory_limit(8 * 1024 * 1024 * 1024)
        path = ROOT / CONFIG["model_directory"]
        manifest = json.loads((ROOT / "evidence/model-download.json").read_text())
        if manifest["revision"] != CONFIG["revision"]:
            raise RuntimeError("Downloaded model revision does not match service configuration")
        integrity_started = time.perf_counter()
        artifact_hashes = verify_model_files(path, manifest)
        integrity_seconds = time.perf_counter() - integrity_started
        config = load_config(path)
        config["audio_config"] = None
        config["vision_config"] = None
        self.model = load_embedding_model(path, config=config)
        parameters = tree_flatten(self.model.parameters())
        dtypes = Counter(str(value.dtype) for _, value in parameters)
        if any(value.dtype != mx.bfloat16 for _, value in parameters):
            raise RuntimeError(f"Expected BF16 checkpoint parameters, got {dict(dtypes)}")
        self.tokenizer = AutoTokenizer.from_pretrained(
            path, local_files_only=True, trust_remote_code=False
        )
        loaded_seconds = time.perf_counter() - started
        packages = {
            name: importlib.metadata.version(name)
            for name in ("mlx", "mlx-metal", "mlx-vlm", "transformers", "tokenizers", "numpy")
        }
        identity = {
            "repository": CONFIG["repository"],
            "revision": CONFIG["revision"],
            "backend_commit": CONFIG["backend_commit"],
            "dtype": CONFIG["dtype"],
            "query_prefix": CONFIG["query_prefix"],
            "document_prefix": CONFIG["document_prefix"],
            "pooling": "projected-mask-aware-mean",
            "normalization": "l2-after-dimension-selection",
            "recipe_version": "eg2-text-v1",
            "packages": packages,
            "artifact_sha256": artifact_hashes,
            "encoder_code_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        }
        self.signature = hashlib.sha256(
            json.dumps(identity, sort_keys=True).encode()
        ).hexdigest()
        self.startup = {
            "loaded_seconds": loaded_seconds,
            "device": mx.device_info(),
            "loaded_parameters": sum(value.size for _, value in parameters),
            "parameter_dtypes": dict(dtypes),
            "packages": packages,
            "integrity_verified_files": len(artifact_hashes),
            "integrity_seconds": integrity_seconds,
        }
        warmup_started = time.perf_counter()
        self.encode(["本地向量服务启动检查。"], "document", 768, record=False)
        self.startup["warmup_seconds"] = time.perf_counter() - warmup_started
        self.ready = True
        return {**self.startup, "encoder_signature": self.signature, **self.metrics}

    def encode(self, texts, input_type="document", dimensions=768, record=True):
        started = time.perf_counter()
        if input_type not in ("document", "query"):
            raise ValueError("input_type must be document or query")
        if dimensions not in CONFIG["supported_dimensions"]:
            raise ValueError("dimensions must be 128, 256, 512, or 768")
        if not 1 <= len(texts) <= CONFIG["max_batch_size"]:
            raise ValueError(f"Supply 1–{CONFIG['max_batch_size']} inputs per request")
        if any(not isinstance(text, str) or not text.strip() for text in texts):
            raise ValueError("Every input must be non-empty text")
        prefix = CONFIG[f"{input_type}_prefix"]
        formatted = [prefix + text for text in texts]
        encoded = self.tokenizer(
            formatted, padding=False, truncation=False, add_special_tokens=True
        )
        lengths = [len(ids) for ids in encoded["input_ids"]]
        for index, length in enumerate(lengths):
            if length > CONFIG["max_tokens_per_input"]:
                raise ValueError(
                    f"input[{index}] has {length} tokens including prefix; "
                    f"maximum is {CONFIG['max_tokens_per_input']}. Split it into smaller chunks."
                )
        vectors = []
        # Fixed microbatch=1 bounds memory for mixed-length requests and keeps each
        # result independent of the lengths of neighboring inputs.
        for index, ids in enumerate(encoded["input_ids"]):
            mask = encoded["attention_mask"][index]
            output = self.model(
                input_ids=mx.array([ids], dtype=mx.int32),
                attention_mask=mx.array([mask], dtype=mx.int32),
            ).text_embeds.astype(mx.float32)
            output = output[:, :dimensions]
            output = output / mx.linalg.norm(output, axis=-1, keepdims=True)
            mx.eval(output)
            vector = np.asarray(output)[0]
            if vector.shape != (dimensions,) or not np.isfinite(vector).all():
                raise RuntimeError("Model returned a non-finite or malformed embedding")
            norm = float(np.linalg.norm(vector))
            if abs(norm - 1.0) > 1e-4:
                raise RuntimeError("Model returned an invalid normalized embedding")
            vectors.append(vector.tolist())
        if record:
            self.completed_requests += 1
            self.completed_inputs += len(texts)
        self.metrics = {
            "process_rss_bytes": psutil.Process().memory_info().rss,
            "mlx_active_bytes": mx.get_active_memory(),
            "mlx_peak_bytes": mx.get_peak_memory(),
            "mlx_cache_bytes": mx.get_cache_memory(),
            "last_request_seconds": time.perf_counter() - started,
        }
        return {
            "vectors": vectors,
            "token_counts": lengths,
            "total_tokens": sum(lengths),
            "elapsed_seconds": time.perf_counter() - started,
        }
