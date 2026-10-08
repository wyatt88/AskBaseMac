#!/usr/bin/env python3
"""Offline API/decoder/processor regressions; no model weights or GPU inference.

Run with the existing service Python: python -B scripts/test_media_api.py
All media are synthetic in-memory fixtures. Model calls are replaced with fakes;
the optional installed processor tests exercise real NumPy preprocessing on CPU.
"""

import asyncio
import base64
import copy
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import threading
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch
import wave

import httpx
import numpy as np
from PIL import Image
from pydantic import ValidationError

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from media_encoder import (
    MediaEncoder, MediaEmbeddingRequest, MediaInput, MediaInputError,
    decode_media, prepare_media,
)

CONFIG = json.loads((ROOT / "config.json").read_text())
LIMITS = CONFIG["media_limits"]
ORIGINAL_ENCODER_HASH = "4de848e661eb68dd4ca1953d3b6445e555157212eab37ee22d14707a5ab93f00"
VECTOR = [1.0] + [0.0] * 767


def jpeg(size=(48, 32), color="red", format="JPEG", orientation=None):
    image = Image.new("RGB", size, color)
    stream = io.BytesIO()
    if orientation is None:
        image.save(stream, format=format)
    else:
        exif = Image.Exif()
        exif[274] = orientation
        image.save(stream, format=format, exif=exif)
    return base64.b64encode(stream.getvalue()).decode("ascii")


def wav(samples=16000, channels=1, rate=16000, width=2, values=None):
    stream = io.BytesIO()
    with wave.open(stream, "wb") as audio:
        audio.setparams((channels, width, rate, 0, "NONE", "not compressed"))
        audio.writeframes(values if values is not None else b"\0" * (samples * channels * width))
    return base64.b64encode(stream.getvalue()).decode("ascii")


def request(kind="image", **kwargs):
    media = {"kind": kind}
    if kind in ("image", "video"):
        media["images"] = [jpeg()]
    else:
        media["audio"] = wav()
    media.update(kwargs)
    return {"model": "embeddinggemma-2", "input_type": "document", "dimensions": 768, "input": media}


class FakeTextEncoder:
    def __init__(self):
        self.ready = True
        self.signature = "original-text-space"
        self.startup = {}
        self.metrics = {}
        self.completed_requests = 0
        self.completed_inputs = 0

    def encode(self, texts, input_type, dimensions):
        return {"vectors": [VECTOR[:dimensions] for _ in texts], "total_tokens": len(texts)}


# Do not import encoder.py or load MLX weights while importing the real server.
fake_encoder_module = ModuleType("encoder")
fake_encoder_module.CONFIG = CONFIG
fake_encoder_module.ROOT = ROOT
fake_encoder_module.TextEncoder = FakeTextEncoder
with patch.dict(sys.modules, {"encoder": fake_encoder_module}):
    spec = importlib.util.spec_from_file_location("media_test_server", ROOT / "server.py")
    server = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(server)


class FakeMediaEncoder:
    def __init__(self):
        self.ready = True
        self.signature = "native-media-recipe"
        self.encoder_signature = "original-text-space"
        self.modalities = ["image", "audio", "video"]
        self.completed_requests = 0
        self.completed_inputs = 0
        self.startup = {}

    def encode(self, media, input_type, dimensions):
        decode_media(media, LIMITS)
        return {"vectors": [VECTOR], "total_tokens": 1}


class DecoderTests(unittest.TestCase):
    def decode(self, kind="image", limits=None, **kwargs):
        return decode_media(MediaInput.model_validate(request(kind, **kwargs)["input"]), limits or LIMITS)

    def test_original_text_encoder_bytes_are_unchanged(self):
        self.assertEqual(hashlib.sha256((ROOT / "encoder.py").read_bytes()).hexdigest(), ORIGINAL_ENCODER_HASH)

    def test_base64_jpeg_decodes_without_files(self):
        images, audio = self.decode()
        self.assertEqual(images[0].size, (48, 32))
        self.assertEqual(images[0].mode, "RGB")
        self.assertIsNone(audio)

    def test_exif_orientation_is_applied_before_video_dimensions(self):
        images, _ = self.decode(images=[jpeg(size=(48, 32), orientation=6)])
        self.assertEqual(images[0].size, (32, 48))

    def test_rejects_urls_paths_data_uris_and_bad_base64(self):
        for value in ("https://example.org/a.jpg", "/private/a.jpg", "file:///a.jpg",
                      "data:image/jpeg;base64,abcd", "!!!!", "a", ""):
            with self.subTest(value=value), self.assertRaises(MediaInputError):
                self.decode(images=[value])

    def test_rejects_wrong_format_and_truncated_jpeg(self):
        raw = base64.b64decode(jpeg())
        for value in (jpeg(format="PNG"), base64.b64encode(raw[:-20]).decode()):
            with self.assertRaises(MediaInputError):
                self.decode(images=[value])

    def test_rejects_compressed_byte_and_decoded_pixel_overflows(self):
        for key, value in (("max_image_bytes", 20), ("max_image_pixels", 100), ("max_image_edge", 20)):
            limits = {**LIMITS, key: value}
            with self.subTest(key=key), self.assertRaises(MediaInputError):
                self.decode(limits=limits)

    def test_total_frame_pixel_budget(self):
        with self.assertRaises(MediaInputError):
            self.decode("video", limits={**LIMITS, "max_total_frame_pixels": 2000},
                        images=[jpeg(), jpeg()])

    def test_video_preserves_eight_frames(self):
        images, _ = self.decode("video", images=[jpeg(color="blue")] * 8,
                                timestamps=[float(t) for t in range(8)])
        self.assertEqual(len(images), 8)

    def test_video_rejects_inconsistent_frame_sizes(self):
        with self.assertRaises(MediaInputError):
            self.decode("video", images=[jpeg(), jpeg(size=(32, 32))])

    def test_video_span_and_nonzero_time_origin(self):
        self.decode("video", images=[jpeg(), jpeg()], timestamps=[100.0, 110.0])
        with self.assertRaises(MediaInputError):
            self.decode("video", images=[jpeg(), jpeg()], timestamps=[0.0, 10.01])

    def test_wav_exact_pcm_scaling(self):
        values = np.resize(np.array([-32768, 0, 32767], dtype="<i2"), 321)
        images, audio = self.decode("audio", audio=wav(samples=321, values=values.tobytes()))
        self.assertEqual(images, [])
        self.assertEqual(audio.dtype, np.float32)
        np.testing.assert_array_equal(audio[:3], [-1.0, 0.0, 32767 / 32768])
        self.assertEqual(len(audio), 321)

    def test_wav_ten_seconds_preserves_all_samples(self):
        _, audio = self.decode("audio", audio=wav(samples=160000))
        self.assertEqual(len(audio), 160000)

    def test_wav_rejects_one_sample_over_budget(self):
        with self.assertRaises(MediaInputError):
            self.decode("audio", audio=wav(samples=160001))

    def test_wav_rejects_empty_short_stereo_other_rate_and_width(self):
        for kwargs in ({"samples": 0}, {"samples": 319}, {"channels": 2},
                       {"rate": 8000}, {"width": 1}, {"width": 4}):
            with self.subTest(kwargs=kwargs), self.assertRaises(MediaInputError):
                self.decode("audio", audio=wav(**kwargs))

    def test_wav_rejects_truncated_extra_and_corrupt_containers(self):
        raw = base64.b64decode(wav())
        variants = [raw[:-1], raw + b"extra", raw[:20]]
        malformed = bytearray(raw)
        struct.pack_into("<I", malformed, 40, 32002)  # data extends beyond RIFF
        variants.append(malformed)
        for value in variants:
            with self.assertRaises(MediaInputError):
                self.decode("audio", audio=base64.b64encode(value).decode())

    def test_wav_rejects_second_data_chunk(self):
        raw = bytearray(base64.b64decode(wav()))
        raw.extend(struct.pack("<4sI", b"data", 2) + b"\0\0")
        struct.pack_into("<I", raw, 4, len(raw) - 8)
        with self.assertRaises(MediaInputError):
            self.decode("audio", audio=base64.b64encode(raw).decode())

    def test_video_accepts_optional_same_segment_audio(self):
        images, audio = self.decode("video", images=[jpeg()] * 2, audio=wav(),
                                    timestamps=[0.0, 0.5])
        self.assertEqual(len(images), 2)
        self.assertEqual(len(audio), 16000)

    def test_schema_rejects_bad_combinations_and_timestamps(self):
        bad = [
            {"kind": "image"}, {"kind": "image", "images": []},
            {"kind": "image", "images": [jpeg()] * 2},
            {"kind": "image", "images": [jpeg()], "audio": wav()},
            {"kind": "audio", "audio": wav(), "images": [jpeg()]},
            {"kind": "video", "images": [jpeg()] * 9},
            {"kind": "video", "images": [jpeg()] * 2, "timestamps": [0.0]},
            {"kind": "video", "images": [jpeg()] * 2, "timestamps": [1.0, 1.0]},
            {"kind": "video", "images": [jpeg()] * 2, "timestamps": [1.0, 0.0]},
            {"kind": "video", "images": [jpeg()], "timestamps": [float("nan")]},
            {"kind": "video", "images": [jpeg()], "timestamps": [float("inf")]},
            {"kind": "video", "images": [jpeg()], "timestamps": [-1.0]},
            {"kind": "video", "images": [jpeg()], "timestamps": ["0"]},
            {"kind": "image", "images": [jpeg()], "url": "https://example.org"},
        ]
        for media in bad:
            with self.subTest(keys=list(media)), self.assertRaises(ValidationError):
                MediaInput.model_validate(media)


class InterfaceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        server.encoder = FakeTextEncoder()
        server.media_encoder = FakeMediaEncoder()
        server.inflight = 0
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=server.app), base_url="http://127.0.0.1"
        )

    async def asyncTearDown(self):
        await self.client.aclose()

    async def test_all_media_shapes_return_shared_space_and_separate_recipe(self):
        for payload in (request(), request("audio"),
                        request("video", images=[jpeg()] * 8, audio=wav())):
            result = await self.client.post("/v1/media/embeddings", json=payload)
            self.assertEqual(result.status_code, 200, result.text)
            data = result.json()
            self.assertEqual(len(data["data"]), 1)
            self.assertEqual(len(data["data"][0]["embedding"]), 768)
            self.assertEqual(data["encoder_signature"], "original-text-space")
            self.assertEqual(data["media_encoder_signature"], "native-media-recipe")
            self.assertEqual(data["dimensions"], 768)
            self.assertEqual(data["input_type"], "document")

    async def test_media_query_role_is_returned(self):
        payload = request()
        payload["input_type"] = "query"
        result = await self.client.post("/v1/media/embeddings", json=payload)
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.json()["input_type"], "query")

    async def test_text_contract_unchanged(self):
        for dimensions in (128, 256, 512, 768):
            result = await self.client.post("/v1/embeddings", json={
                "input": ["text one", "text two"], "input_type": "query", "dimensions": dimensions
            })
            self.assertEqual(result.status_code, 200)
            data = result.json()
            self.assertEqual(set(data), {
                "object", "data", "model", "usage", "input_type", "dimensions", "encoder_signature"
            })
            self.assertEqual(data["encoder_signature"], "original-text-space")
            self.assertEqual(len(data["data"]), 2)
            self.assertEqual(len(data["data"][1]["embedding"]), dimensions)

    async def test_text_blank_batch_model_and_dimensions_guards_remain(self):
        for payload, status in (({"input": ""}, 400), ({"input": []}, 400),
                                ({"input": ["x"] * 9}, 400),
                                ({"input": "x", "model": "other"}, 422),
                                ({"input": "x", "dimensions": 3}, 422)):
            result = await self.client.post("/v1/embeddings", json=payload)
            self.assertEqual(result.status_code, status)

    async def test_media_validation_does_not_echo_payload(self):
        sentinel = "SYNTHETIC_PRIVATE_MEDIA_VALUE"
        payload = request(images=[sentinel] * 2)
        response = await self.client.post("/v1/media/embeddings", json=payload)
        self.assertEqual(response.status_code, 422)
        self.assertNotIn(sentinel, response.text)
        self.assertNotIn('"input":', response.text)

    async def test_media_rejects_other_model_dimensions_and_extra_keys(self):
        for key, value in (("model", "other"), ("dimensions", 512), ("input_type", "other"),
                           ("encoding_format", "base64")):
            payload = request()
            payload[key] = value
            result = await self.client.post("/v1/media/embeddings", json=payload)
            self.assertEqual(result.status_code, 422)

    async def test_malformed_json_is_redacted(self):
        result = await self.client.post("/v1/media/embeddings", content='{"input":"PRIVATE" invalid',
                                        headers={"content-type": "application/json"})
        self.assertEqual(result.status_code, 422)
        self.assertNotIn("PRIVATE", result.text)

    async def test_decode_error_is_clear_and_queue_is_released(self):
        result = await self.client.post("/v1/media/embeddings", json=request(images=["https://example.org/a"]))
        self.assertEqual(result.status_code, 400)
        self.assertIn("base64", result.json()["detail"])
        self.assertNotIn("https://", result.text)
        await asyncio.sleep(0)
        self.assertEqual(server.inflight, 0)

    async def test_unknown_inference_error_is_redacted_in_logs_and_response(self):
        with patch.object(server.media_encoder, "encode", side_effect=RuntimeError("PRIVATE_CONTENT")):
            with self.assertLogs("embeddinggemma2", level="ERROR") as logs:
                result = await self.client.post("/v1/media/embeddings", json=request())
        self.assertEqual(result.status_code, 500)
        self.assertNotIn("PRIVATE_CONTENT", result.text + "".join(logs.output))
        self.assertEqual(server.inflight, 0)

    async def test_fail_closed_before_alignment(self):
        server.media_encoder.ready = False
        server.media_encoder.modalities = []
        result = await self.client.post("/v1/media/embeddings", json=request())
        self.assertEqual(result.status_code, 503)
        health = (await self.client.get("/health")).json()
        self.assertEqual(health["modalities"], ["text"])
        self.assertIsNone(health["media_encoder_signature"])
        text = await self.client.post("/v1/embeddings", json={"input": "still works"})
        self.assertEqual(text.status_code, 200)

    async def test_health_advertises_ready_native_modalities(self):
        health = (await self.client.get("/health")).json()
        self.assertEqual(health["modalities"], ["text", "image", "audio", "video"])
        self.assertEqual(health["media_encoder_signature"], "native-media-recipe")
        self.assertEqual(health["encoder_signature"], "original-text-space")

    async def test_shared_queue_rejects_when_full(self):
        server.inflight = CONFIG["max_pending_requests"]
        for path, payload in (("/v1/media/embeddings", request()),
                              ("/v1/embeddings", {"input": "text"})):
            result = await self.client.post(path, json=payload)
            self.assertEqual(result.status_code, 429)
        server.inflight = 0

    async def test_origin_and_host_guards_apply_to_media(self):
        result = await self.client.post("/v1/media/embeddings", json=request(),
                                        headers={"origin": "https://example.org"})
        self.assertEqual(result.status_code, 403)
        result = await self.client.post("/v1/media/embeddings", json=request(),
                                        headers={"host": "foreign.test"})
        self.assertEqual(result.status_code, 400)

    async def test_route_specific_request_limits_and_bad_content_length(self):
        for path, length, expected in (
            ("/v1/embeddings", CONFIG["max_request_bytes"] + 1, 413),
            ("/v1/media/embeddings", LIMITS["max_request_bytes"] + 1, 413),
            ("/v1/media/embeddings", -1, 413),
            ("/v1/media/embeddings", "invalid", 400),
        ):
            result = await self.client.post(path, content=b"{}",
                                            headers={"content-length": str(length)})
            self.assertEqual(result.status_code, expected)

    async def test_stream_limit_without_content_length(self):
        async def chunks():
            yield b"a" * 60
            yield b"b" * 60

        with patch.dict(CONFIG["media_limits"], {"max_request_bytes": 100}):
            result = await self.client.post("/v1/media/embeddings", content=chunks())
        self.assertEqual(result.status_code, 413)

    async def test_media_payload_larger_than_text_request_limit_is_accepted(self):
        pixels = np.random.default_rng(42).integers(0, 256, (1024, 1024, 3), dtype=np.uint8)
        output = io.BytesIO()
        Image.fromarray(pixels).save(output, format="JPEG", quality=95)
        payload = request(images=[base64.b64encode(output.getvalue()).decode()])
        self.assertGreater(len(json.dumps(payload)), CONFIG["max_request_bytes"])
        result = await self.client.post("/v1/media/embeddings", json=payload)
        self.assertEqual(result.status_code, 200, result.text)

    async def test_text_and_media_share_one_worker(self):
        entered, release = threading.Event(), threading.Event()
        order, thread_ids = [], []

        def text_work(*args):
            thread_ids.append(threading.get_ident())
            order.append("text_start")
            entered.set()
            release.wait(5)
            order.append("text_end")
            return {"vectors": [VECTOR], "total_tokens": 1}

        def media_work(*args):
            thread_ids.append(threading.get_ident())
            order.append("media")
            return {"vectors": [VECTOR], "total_tokens": 1}

        with patch.object(server.encoder, "encode", text_work), patch.object(server.media_encoder, "encode", media_work):
            text_task = asyncio.create_task(self.client.post("/v1/embeddings", json={"input": "x"}))
            self.assertTrue(await asyncio.to_thread(entered.wait, 2))
            media_task = asyncio.create_task(self.client.post("/v1/media/embeddings", json=request()))
            try:
                for _ in range(100):
                    if server.inflight == 2:
                        break
                    await asyncio.sleep(0.01)
                self.assertEqual(server.inflight, 2)
                self.assertEqual(order, ["text_start"])
            finally:
                release.set()
                results = await asyncio.gather(text_task, media_task)
        self.assertEqual([r.status_code for r in results], [200, 200])
        self.assertEqual(order, ["text_start", "text_end", "media"])
        self.assertEqual(len(set(thread_ids)), 1)
        self.assertEqual(server.inflight, 0)

    async def test_cancelled_media_wait_keeps_actual_worker_counted(self):
        entered, release = threading.Event(), threading.Event()

        def blocked(*args):
            entered.set()
            release.wait(5)
            return {"vectors": [VECTOR], "total_tokens": 1}

        with patch.object(server.media_encoder, "encode", blocked):
            task = asyncio.create_task(server.media_embeddings(MediaEmbeddingRequest.model_validate(request())))
            self.assertTrue(await asyncio.to_thread(entered.wait, 2))
            try:
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task
                self.assertEqual(server.inflight, 1)
            finally:
                release.set()
                for _ in range(100):
                    if server.inflight == 0:
                        break
                    await asyncio.sleep(0.01)
        self.assertEqual(server.inflight, 0)

    async def test_startup_media_failure_keeps_text_and_shutdown_always_cleans_up(self):
        startup = {
            "device": {"device_name": "synthetic"}, "loaded_seconds": 0, "warmup_seconds": 0,
        }
        isolated_worker = ThreadPoolExecutor(max_workers=1)
        fake_root = MagicMock()
        with (
            patch.object(server, "worker", isolated_worker),
            patch.object(server, "ROOT", fake_root),
            patch.object(server.encoder, "load", return_value=startup, create=True),
            patch.object(server.media_encoder, "load", side_effect=RuntimeError("PRIVATE"), create=True),
            self.assertLogs("embeddinggemma2", level="INFO") as logs,
        ):
            with self.assertRaisesRegex(RuntimeError, "synthetic app exit"):
                async with server.lifespan(server.app):
                    self.assertTrue(server.encoder.ready)
                    self.assertFalse(server.media_encoder.ready)
                    raise RuntimeError("synthetic app exit")
        self.assertFalse(server.encoder.ready)
        self.assertFalse(server.media_encoder.ready)
        self.assertNotIn("PRIVATE", "".join(logs.output))
        with self.assertRaises(RuntimeError):
            isolated_worker.submit(lambda: None)


class NativeProcessorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # No weights loaded. Explicit CPU device even if preprocessing utilities
        # import MLX, and all processor return_tensors calls below use NumPy.
        try:
            import mlx.core as mx
            mx.set_default_device(mx.cpu)
            from mlx_vlm.models.embedding_gemma2.processing_embedding_gemma2 import EmbeddingGemma2Processor
        except ImportError:
            raise unittest.SkipTest("Pinned local processor dependencies are not installed")
        model = Path.home() / "Library/Application Support/AskBase/EmbeddingGemma2" / CONFIG["model_directory"]
        if not model.is_dir():
            raise unittest.SkipTest("Pinned local checkpoint metadata is not installed")
        cls.processor = EmbeddingGemma2Processor.from_pretrained(
            model, local_files_only=True, trust_remote_code=False
        )

    def prepare(self, payload):
        return prepare_media(self.processor, MediaInput.model_validate(payload["input"]), LIMITS)[0]

    def test_image_uses_native_image_positions_and_no_text_prefix(self):
        batch = self.prepare(request())
        self.assertIn("pixel_values", batch)
        self.assertNotIn("pixel_values_videos", batch)
        ids = batch["input_ids"][0]
        allowed = {
            self.processor.tokenizer.bos_token_id, self.processor.tokenizer.eos_token_id,
            self.processor.tokenizer.boi_token_id, self.processor.tokenizer.eoi_token_id,
            self.processor.image_token_id,
        }
        self.assertTrue(set(ids).issubset(allowed))
        self.assertEqual(batch["pixel_values"].shape[0], 1)

    def test_eight_frames_use_video_tokens_without_resampling(self):
        batch = self.prepare(request("video", images=[jpeg(color="blue")] * 8,
                                     timestamps=[0.0, 0.1, 0.4, 1.0, 3.0, 4.0, 7.0, 9.99]))
        self.assertEqual(batch["num_frames_per_video"].tolist(), [8])
        self.assertEqual(batch["pixel_values_videos"].shape[0], 8)
        self.assertNotIn("pixel_values", batch)
        ids = batch["input_ids"]
        self.assertEqual(np.count_nonzero(ids == self.processor.image_token_id), 0)
        self.assertGreater(np.count_nonzero(ids == self.processor.video_token_id), 0)
        self.assertEqual(self.processor.video_processor.do_sample_frames, True)

    def test_audio_boundary_no_sample_truncation(self):
        for samples in (320, 321, 16000, 16001, 160000):
            batch = self.prepare(request("audio", audio=wav(samples=samples)))
            expected_mel = (samples - 161) // 160 + 1
            self.assertEqual(int(batch["input_features_mask"].sum()), expected_mel)
            self.assertEqual(
                np.count_nonzero(batch["input_ids"] == self.processor.audio_token_id),
                (expected_mel + 3) // 4,
            )

    def test_video_and_audio_reach_one_native_batch(self):
        batch = self.prepare(request("video", images=[jpeg()] * 2, audio=wav()))
        self.assertEqual(batch["input_ids"].shape[0], 1)
        self.assertIn("input_features", batch)
        self.assertIn("pixel_values_videos", batch)
        self.assertGreater(np.count_nonzero(batch["input_ids"] == self.processor.video_token_id), 0)
        self.assertGreater(np.count_nonzero(batch["input_ids"] == self.processor.audio_token_id), 0)

    def test_token_budget_rejects_instead_of_truncating(self):
        with self.assertRaises(MediaInputError):
            prepare_media(self.processor, MediaInput.model_validate(request()["input"]),
                          {**LIMITS, "max_tokens": 10})

    def test_media_signature_changes_when_recipe_limits_change(self):
        instance = MediaEncoder(FakeTextEncoder(), copy.deepcopy(CONFIG), ROOT)
        instance.encoder_signature = "original-text-space"
        first = instance._signature()
        instance.config["media_limits"]["max_video_frames"] = 7
        self.assertNotEqual(first, instance._signature())
        self.assertEqual(instance.encoder_signature, "original-text-space")

    def test_full_model_alignment_failure_refuses_shared_signature(self):
        import media_encoder

        reference = FakeTextEncoder()
        reference.tokenizer = self.processor.tokenizer
        reference.encode = lambda *args, **kwargs: {"vectors": [VECTOR]}
        instance = MediaEncoder(reference, CONFIG, ROOT)
        instance.processor = self.processor
        instance.model = object()
        different = np.asarray(VECTOR, dtype=np.float32)
        different[1] = 1e-6
        with patch.object(media_encoder, "_normalized_vector", return_value=different):
            with self.assertRaisesRegex(RuntimeError, "alignment failed"):
                instance._verify_text_alignment()
        self.assertIsNone(instance.signature)
        self.assertFalse(instance.ready)

    def test_bad_model_outputs_are_rejected_on_cpu(self):
        import mlx.core as mx
        from media_encoder import _normalized_vector

        batch = {"input_ids": np.array([[1, 2]]), "attention_mask": np.array([[1, 1]])}
        for output in (np.zeros((1, 768)), np.ones((1, 767)),
                       np.full((1, 768), np.nan), np.full((1, 768), np.inf)):
            model = lambda **kwargs: SimpleNamespace(text_embeds=mx.array(output, dtype=mx.float32))
            with self.assertRaises(RuntimeError):
                _normalized_vector(model, batch)


if __name__ == "__main__":
    unittest.main(verbosity=2)
