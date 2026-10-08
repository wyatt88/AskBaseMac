"""Native, offline EmbeddingGemma 2 media inference; no changes to TextEncoder.

Requests contain one already segmented clip, never a URL or a filesystem path.
Decoding and preprocessing stay in memory. Call load/encode only on the service's
single MLX worker, including the startup text-equivalence check.
"""

import base64
import binascii
import hashlib
import importlib.metadata
import io
import json
import math
import os
from pathlib import Path
import struct
import time
from typing import Literal
import warnings
import wave

import numpy as np
from PIL import Image, ImageOps, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict, Field, model_validator


class MediaInputError(ValueError):
    """Safe, fixed-message client error; never include payloads in diagnostics."""


class MediaInput(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)
    kind: Literal["image", "audio", "video"]
    images: list[str] | None = Field(default=None, min_length=1, max_length=8)
    audio: str | None = None
    timestamps: list[float] | None = Field(default=None, min_length=1, max_length=8)

    @model_validator(mode="after")
    def check_layout(self):
        if self.kind == "image":
            if self.images is None or len(self.images) != 1:
                raise ValueError("image requires exactly one base64 JPEG")
            if self.audio is not None or self.timestamps is not None:
                raise ValueError("image does not accept audio or timestamps")
        elif self.kind == "audio":
            if not self.audio or self.images is not None or self.timestamps is not None:
                raise ValueError("audio requires only a base64 PCM16 mono 16 kHz WAV")
        else:
            if not self.images:
                raise ValueError("video requires 1–8 base64 JPEG frames")
            if self.timestamps is not None:
                if len(self.timestamps) != len(self.images):
                    raise ValueError("timestamps must align one-to-one with video frames")
                if any(not math.isfinite(t) or t < 0 for t in self.timestamps):
                    raise ValueError("timestamps must be finite nonnegative seconds")
                if any(a >= b for a, b in zip(self.timestamps, self.timestamps[1:])):
                    raise ValueError("timestamps must be strictly increasing")
        return self


class MediaEmbeddingRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)
    model: Literal["embeddinggemma-2"] = "embeddinggemma-2"
    input_type: Literal["document", "query"] = "document"
    dimensions: Literal[768] = 768
    input: MediaInput


# Fixed, synthetic, nonprivate startup probes: three texts, both retrieval roles.
# They are also the complete six-row text-alignment budget of the real smoke test.
ALIGNMENT_TEXTS = (
    "A red square moves from left to right.",
    "一段清晰的音频和一张蓝色圆形图片。",
    "def add(a, b):\n    return a + b",
)

PREPROCESSING_RECIPE = {
    "version": "eg2-media-v1",
    "decode": "strict-base64; JPEG/Pillow EXIF-transpose then RGB; in-memory only",
    "audio": "RIFF PCM16 LE mono 16000Hz; int16/32768 to float32; no resampling",
    "media_prefix": "none (model card: prefixes apply to text only)",
    "processor": "pinned EmbeddingGemma2Processor with local checkpoint settings",
    "image_soft_token_budget": 280,
    "video_soft_token_budget_per_frame": 140,
    "video_sampling": "App-sampled ordered frames; do_sample_frames=False; no frame drops",
    "timestamps": "validate order and segment span; native add_timestamps=False",
    "audio_truncation": False,
    "text_truncation": False,
    "media_tensor_dtype": "bfloat16",
    "pooling": "model projected-mask-aware-mean, including all media tokens",
    "normalization": "model L2 then float32 L2, exactly as original TextEncoder",
    "dimensions": 768,
    "batch_size": 1,
    "text_alignment": "six exact float32 vector and tokenizer comparisons; fail closed",
}


def _decode_base64(value, maximum, label):
    if not isinstance(value, str) or not value:
        raise MediaInputError(f"{label} must be nonempty base64 bytes")
    if len(value) > 4 * ((maximum + 2) // 3):
        raise MediaInputError(f"{label} exceeds the per-segment byte budget")
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise MediaInputError(f"{label} must be base64 bytes, not a URL or path") from None
    if not raw or len(raw) > maximum:
        raise MediaInputError(f"{label} exceeds the per-segment byte budget or is empty")
    return raw


def _decode_jpeg(raw, limits):
    if not raw.startswith(b"\xff\xd8") or not raw.endswith(b"\xff\xd9"):
        raise MediaInputError("Each frame must be a complete JPEG")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(raw)) as image:
                if image.format != "JPEG":
                    raise MediaInputError("Only JPEG frames are accepted")
                width, height = image.size
                if (
                    width < 1 or height < 1
                    or max(width, height) > limits["max_image_edge"]
                    or width * height > limits["max_image_pixels"]
                ):
                    raise MediaInputError("Frame dimensions exceed the per-segment budget")
                image.load()  # Fail on truncated pixel data, not just a valid header.
                return ImageOps.exif_transpose(image).convert("RGB")
    except MediaInputError:
        raise
    except (OSError, ValueError, UnidentifiedImageError,
            Image.DecompressionBombWarning, Image.DecompressionBombError):
        raise MediaInputError("Invalid or incomplete JPEG frame") from None


def _decode_wav(raw, limits):
    # wave alone can read only the first data chunk or accept an incomplete RIFF.
    # Check the entire container first so no audio can be silently discarded.
    if len(raw) < 44 or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise MediaInputError("audio must be a PCM16 mono 16 kHz RIFF WAV")
    if struct.unpack_from("<I", raw, 4)[0] + 8 != len(raw):
        raise MediaInputError("WAV length is inconsistent or truncated")
    chunks = {}
    offset = 12
    while offset < len(raw):
        if offset + 8 > len(raw):
            raise MediaInputError("Incomplete WAV chunk header")
        tag, length = struct.unpack_from("<4sI", raw, offset)
        start, end = offset + 8, offset + 8 + length
        if end + (length % 2) > len(raw):
            raise MediaInputError("Incomplete WAV chunk")
        if tag in (b"fmt ", b"data"):
            if tag in chunks:
                raise MediaInputError("WAV must contain exactly one format and data chunk")
            chunks[tag] = raw[start:end]
        offset = end + (length % 2)
    fmt, data = chunks.get(b"fmt ", b""), chunks.get(b"data", b"")
    if len(fmt) < 16:
        raise MediaInputError("Missing WAV PCM format")
    encoding, channels, rate, byte_rate, alignment, bits = struct.unpack_from("<HHIIHH", fmt)
    if (encoding, channels, rate, byte_rate, alignment, bits) != (1, 1, 16000, 32000, 2, 16):
        raise MediaInputError("WAV must be uncompressed PCM16 little-endian, mono, 16000 Hz")
    samples = len(data) // 2
    # The pinned feature extractor needs at least one 20ms STFT window. Very
    # short audio is explicitly rejected, never converted to an empty embedding.
    if len(data) % 2 or samples < 320:
        raise MediaInputError("WAV must contain at least 20 ms of complete PCM16 samples")
    if samples > int(limits["max_duration_seconds"] * 16000):
        raise MediaInputError("Audio segment exceeds 10 seconds; split it in the app")
    try:
        with wave.open(io.BytesIO(raw), "rb") as stream:
            pcm = stream.readframes(stream.getnframes())
            if stream.getnframes() != samples or pcm != data:
                raise MediaInputError("WAV data is inconsistent or incomplete")
    except (wave.Error, EOFError, OSError):
        raise MediaInputError("Invalid or incomplete WAV") from None
    return np.frombuffer(pcm, dtype="<i2").astype(np.float32) / np.float32(32768)


def decode_media(media: MediaInput, limits):
    """Decode a validated single clip on the worker; return no paths or URLs."""
    if media.kind == "video":
        if len(media.images) > limits["max_video_frames"]:
            raise MediaInputError("Video segment exceeds the frame budget; split it in the app")
        if (
            media.timestamps is not None
            and media.timestamps[-1] - media.timestamps[0] > limits["max_duration_seconds"]
        ):
            raise MediaInputError("Video frame span exceeds 10 seconds; split it in the app")
    images = []
    total_pixels = 0
    for value in media.images or []:
        raw = _decode_base64(value, limits["max_image_bytes"], "JPEG")
        image = _decode_jpeg(raw, limits)
        total_pixels += image.width * image.height
        if total_pixels > limits["max_total_frame_pixels"]:
            raise MediaInputError("Decoded frames exceed the per-segment pixel budget")
        if media.kind == "video" and images and image.size != images[0].size:
            raise MediaInputError("All video frames must have the same oriented dimensions")
        images.append(image)
    audio = None
    if media.audio is not None:
        raw = _decode_base64(media.audio, limits["max_audio_bytes"], "WAV")
        audio = _decode_wav(raw, limits)
    return images, audio


def prepare_media(processor, media: MediaInput, limits):
    """Run the pinned native processor, preserving every provided frame/sample."""
    images, audio = decode_media(media, limits)
    inputs = {}
    if media.kind == "image":
        inputs["images"] = images
    elif media.kind == "video":
        # A 4-D video tensor goes through the native video processor, whose
        # patches/positions and <|video|> tokens differ from image preprocessing.
        inputs["videos"] = [np.stack([np.asarray(frame) for frame in images])]
        inputs["videos_kwargs"] = {
            "do_sample_frames": False,
            "add_timestamps": False,  # Fixed checkpoint default; order is preserved.
            "input_data_format": "channels_last",
        }
    if audio is not None:
        inputs["audio"] = audio
    batch = processor(
        **inputs,
        return_tensors="np",
        text_kwargs={"truncation": False, "padding": False, "add_special_tokens": True},
        audio_kwargs={
            "sampling_rate": 16000,
            "truncation": False,
            "max_length": None,
            "padding": "longest",
            "pad_to_multiple_of": 128,
        },
    )
    ids = np.asarray(batch["input_ids"])
    mask = np.asarray(batch["attention_mask"])
    if ids.ndim != 2 or ids.shape[0] != 1 or mask.shape != ids.shape:
        raise RuntimeError("Media processor returned an invalid batch")
    if ids.shape[1] > limits["max_tokens"]:
        raise MediaInputError("Media segment exceeds the token budget; split it in the app")
    tokenizer = processor.tokenizer
    if media.kind == "video":
        if (
            np.asarray(batch["num_frames_per_video"]).tolist() != [len(images)]
            or batch["pixel_values_videos"].shape[0] != len(images)
            or np.count_nonzero(ids == processor.video_token_id) == 0
            or np.count_nonzero(ids == tokenizer.image_token_id) != 0
        ):
            raise RuntimeError("Video preprocessing lost frames or used image tokens")
    elif media.kind == "image" and np.count_nonzero(ids == tokenizer.image_token_id) == 0:
        raise RuntimeError("Image preprocessing returned no image tokens")
    if audio is not None:
        # This matches the reference's semicausal STFT and two stride-2
        # subsampling layers. Checking it catches an accidental truncation.
        extractor = processor.feature_extractor
        expected_mel = (
            len(audio) + extractor.frame_length // 2 - (extractor.frame_length + 1)
        ) // extractor.hop_length + 1
        audio_mask = np.asarray(batch["input_features_mask"])
        if audio_mask.shape[0] != 1 or int(audio_mask.sum()) != expected_mel:
            raise RuntimeError("Audio preprocessing did not preserve the complete sample span")
        expected_tokens = (expected_mel + 3) // 4
        if np.count_nonzero(ids == tokenizer.audio_token_id) != expected_tokens:
            raise RuntimeError("Audio token count differs from the reference subsampling")
    return dict(batch), int(mask.sum())


def _normalized_vector(model, batch):
    import mlx.core as mx

    tensor_inputs = {}
    for name in (
        "input_ids", "attention_mask", "pixel_values", "image_position_ids",
        "pixel_values_videos", "video_position_ids", "input_features", "input_features_mask",
    ):
        if name not in batch:
            continue
        value = np.asarray(batch[name])
        if np.issubdtype(value.dtype, np.floating):
            if not np.isfinite(value).all():
                raise RuntimeError("Processor returned non-finite media features")
            tensor_inputs[name] = mx.array(value, dtype=mx.bfloat16)
        elif value.dtype == np.bool_:
            tensor_inputs[name] = mx.array(value, dtype=mx.bool_)
        else:
            tensor_inputs[name] = mx.array(value, dtype=mx.int32)
    output = model(**tensor_inputs).text_embeds.astype(mx.float32)
    output = output / mx.linalg.norm(output, axis=-1, keepdims=True)
    mx.eval(output)
    result = np.asarray(output)
    if result.shape != (1, 768) or not np.isfinite(result).all():
        raise RuntimeError("Model returned a non-finite or malformed media embedding")
    vector = result[0]
    if abs(float(np.linalg.norm(vector)) - 1.0) > 1e-4:
        raise RuntimeError("Model returned an invalid normalized media embedding")
    return vector


class MediaEncoder:
    def __init__(self, text_encoder, config, root):
        self.text_encoder = text_encoder
        self.config = config
        self.root = Path(root)
        self.ready = False
        self.signature = None
        self.startup = {}
        self.metrics = {}
        self.completed_requests = 0
        self.completed_inputs = 0

    @property
    def modalities(self):
        return [
            kind for kind in ("image", "audio", "video")
            if kind in self.config.get("modalities_enabled", [])
        ] if self.ready else []

    def load(self):
        import mlx.core as mx
        from mlx.utils import tree_flatten
        from mlx_vlm.embedding_loader import load_embedding_model
        from mlx_vlm.models.embedding_gemma2.processing_embedding_gemma2 import (
            EmbeddingGemma2Processor,
        )

        started = time.perf_counter()
        self.ready = False
        self.signature = None
        if not self.text_encoder.ready or not mx.metal.is_available():
            raise RuntimeError("The original Metal TextEncoder must be ready first")
        for name in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_IMPLICIT_TOKEN"):
            os.environ[name] = "1"
        path = (self.root / self.config["model_directory"]).resolve(strict=True)
        if path != Path(self.text_encoder.model.model_path).resolve(strict=True):
            raise RuntimeError("Media and text models must use the same verified checkpoint")
        installed = json.loads(importlib.metadata.distribution("mlx-vlm").read_text("direct_url.json"))
        if installed.get("vcs_info", {}).get("commit_id") != self.config["backend_commit"]:
            raise RuntimeError("Media backend does not match the pinned MLX-VLM commit")
        self.processor = EmbeddingGemma2Processor.from_pretrained(
            path, local_files_only=True, trust_remote_code=False
        )
        if (
            self.processor.image_processor.max_soft_tokens != 280
            or self.processor.video_processor.max_soft_tokens != 140
            or self.processor.feature_extractor.sampling_rate != 16000
        ):
            raise RuntimeError("Media preprocessing differs from the pinned recipe")
        # The original TextEncoder has already checked every checkpoint byte.
        # Do not disable either modality tower, quantize, or download anything.
        self.model = load_embedding_model(path)
        parameters = tree_flatten(self.model.parameters())
        if any(value.dtype != mx.bfloat16 for _, value in parameters):
            raise RuntimeError("Media checkpoint parameters must all be bfloat16")
        alignment = self._verify_text_alignment()
        self.encoder_signature = self.text_encoder.signature
        self.signature = self._signature()
        self.startup = {
            "loaded_seconds": time.perf_counter() - started,
            "loaded_parameters": sum(value.size for _, value in parameters),
            "text_alignment": alignment,
            "media_encoder_signature": self.signature,
            "encoder_signature": self.encoder_signature,
        }
        self.ready = True
        return self.startup

    def _verify_text_alignment(self):
        rows = []
        for input_type in ("document", "query"):
            for index, text in enumerate(ALIGNMENT_TEXTS):
                formatted = self.config[f"{input_type}_prefix"] + text
                batch = self.processor(
                    text=[formatted], return_tensors="np",
                    text_kwargs={"padding": False, "truncation": False, "add_special_tokens": True},
                )
                original_tokens = self.text_encoder.tokenizer(
                    [formatted], padding=False, truncation=False, add_special_tokens=True
                )
                for key in ("input_ids", "attention_mask"):
                    if not np.array_equal(batch[key], original_tokens[key]):
                        raise RuntimeError("Full-model tokenizer differs from the original TextEncoder")
                original = np.asarray(
                    self.text_encoder.encode([text], input_type, 768, record=False)["vectors"][0],
                    dtype=np.float32,
                )
                full = _normalized_vector(self.model, batch)
                exact = bool(np.array_equal(original, full))
                rows.append({
                    "probe": index, "input_type": input_type, "exact_float32_match": exact,
                    "max_absolute_error": float(np.max(np.abs(original - full))),
                    "cosine": float(
                        np.dot(original.astype(np.float64), full.astype(np.float64))
                        / (np.linalg.norm(original.astype(np.float64))
                           * np.linalg.norm(full.astype(np.float64)))
                    ),
                })
                if not exact:
                    raise RuntimeError("Full-model text alignment failed; shared signature is unsafe")
        return rows

    def _signature(self):
        import mlx_vlm
        import transformers

        sources = {"media_encoder.py": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
        for package, names in (
            (mlx_vlm, (
                "models/embedding_gemma2/processing_embedding_gemma2.py",
                "models/embedding_gemma2/image_processing_embedding_gemma2.py",
                "models/embedding_gemma2/video_processing_embedding_gemma2.py",
                "models/embedding_gemma2/embedding_gemma2.py",
                "models/embedding_gemma2/language.py",
                "models/gemma4/processing_gemma4.py", "models/gemma4/audio.py",
                "models/gemma4/vision.py", "models/pooling.py",
            )),
            (transformers, (
                "processing_utils.py", "video_utils.py", "audio_utils.py",
                "models/gemma4/feature_extraction_gemma4.py",
            )),
        ):
            for name in names:
                source = Path(package.__file__).parent / name
                sources[f"{package.__name__}/{name}"] = hashlib.sha256(source.read_bytes()).hexdigest()
        identity = {
            "text_encoder_signature": self.encoder_signature,
            "recipe": PREPROCESSING_RECIPE,
            "limits": self.config["media_limits"],
            "sources_sha256": sources,
            "packages": {
                name: importlib.metadata.version(name)
                for name in ("mlx", "mlx-metal", "mlx-vlm", "transformers", "tokenizers", "numpy", "pillow")
            },
        }
        return hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()

    def encode(self, media: MediaInput, input_type="document", dimensions=768):
        if not self.ready:
            raise RuntimeError("Media encoder is not ready")
        if media.kind not in self.modalities:
            raise MediaInputError("Requested media modality is not enabled")
        if input_type not in ("query", "document") or dimensions != 768:
            raise MediaInputError("Media requires query/document input_type and 768 dimensions")
        started = time.perf_counter()
        batch, tokens = prepare_media(self.processor, media, self.config["media_limits"])
        vector = _normalized_vector(self.model, batch)
        self.completed_requests += 1
        self.completed_inputs += 1
        self.metrics = {"last_request_seconds": time.perf_counter() - started}
        return {"vectors": [vector.tolist()], "total_tokens": tokens}
