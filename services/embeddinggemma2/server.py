"""Loopback-only, text embedding API. Run with this directory's Python."""

import asyncio
import json
import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Literal

# All production requests use already downloaded files and cannot access the Hub.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, RedirectResponse
from pydantic import BaseModel, ConfigDict, Field
from starlette.middleware.trustedhost import TrustedHostMiddleware

from encoder import CONFIG, ROOT, TextEncoder

LOG = logging.getLogger("embeddinggemma2")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
encoder = TextEncoder()
worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="embedding-metal")
inflight = 0
created = int(time.time())


@asynccontextmanager
async def lifespan(app):
    result = await asyncio.get_running_loop().run_in_executor(worker, encoder.load)
    evidence = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "pid": os.getpid(),
        "model": CONFIG["model_id"],
        "revision": CONFIG["revision"],
        **result,
    }
    (ROOT / "evidence/latest-startup.json").write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2) + "\n"
    )
    LOG.info(
        "Ready: %s, BF16, %s, loaded %.3fs, warmup %.3fs",
        CONFIG["model_id"],
        result["device"]["device_name"],
        result["loaded_seconds"],
        result["warmup_seconds"],
    )
    yield
    encoder.ready = False
    worker.shutdown(wait=True, cancel_futures=True)


app = FastAPI(
    title="EmbeddingGemma 2 · 本地向量服务",
    version="1.0.0",
    description=(
        "Apple GPU / MLX / BF16。input_type=query 用于问题，"
        "input_type=document 用于资料；服务自动添加官方检索前缀。"
        "默认 768 维，支持 512/256/128 维并重新归一化。"
        "仅处理文本，不生成聊天回答；不自动截断过长输入。"
    ),
    lifespan=lifespan,
)
app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost"])


@app.middleware("http")
async def limit_request(request: Request, call_next):
    allowed_origins = {
        f"http://127.0.0.1:{CONFIG['port']}",
        f"http://localhost:{CONFIG['port']}",
    }
    if request.headers.get("origin") not in (None, *allowed_origins):
        return JSONResponse({"detail": "Only the local service origin is allowed"}, 403)
    limit = CONFIG["max_request_bytes"]
    content_length = request.headers.get("content-length")
    if content_length is not None:
        try:
            length = int(content_length)
        except ValueError:
            return JSONResponse({"detail": "Invalid Content-Length"}, 400)
        if length < 0 or length > limit:
            return JSONResponse({"detail": "Request body exceeds 1 MiB"}, 413)
    if request.method in ("POST", "PUT", "PATCH"):
        body = bytearray()
        async for chunk in request.stream():
            body.extend(chunk)
            if len(body) > limit:
                return JSONResponse({"detail": "Request body exceeds 1 MiB"}, 413)
        request._body = bytes(body)
    return await call_next(request)


class EmbeddingRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    model: Literal["embeddinggemma-2"] = "embeddinggemma-2"
    input: str | list[str]
    input_type: Literal["query", "document"] = "document"
    dimensions: Literal[128, 256, 512, 768] = 768
    encoding_format: Literal["float"] = "float"
    user: str | None = Field(default=None, max_length=256)


@app.get("/", include_in_schema=False)
async def home():
    return RedirectResponse("/docs")


@app.get("/health")
async def health():
    return {
        "status": "ok" if encoder.ready else "loading",
        "model": CONFIG["model_id"],
        "revision": CONFIG["revision"],
        "backend": "mlx",
        "dtype": "bfloat16",
        "device": encoder.startup.get("device", {}).get("device_name"),
        "modalities": ["text"],
        "dimensions": 768,
        "supported_dimensions": CONFIG["supported_dimensions"],
        "max_tokens_per_input": CONFIG["max_tokens_per_input"],
        "max_batch_size": CONFIG["max_batch_size"],
        "encoder_signature": getattr(encoder, "signature", None),
        "inflight_requests": inflight,
        "completed_requests": encoder.completed_requests,
        "completed_inputs": encoder.completed_inputs,
        "metrics": encoder.metrics,
    }


@app.get("/v1/models")
async def models():
    return {
        "object": "list",
        "data": [{
            "id": CONFIG["model_id"],
            "object": "model",
            "created": created,
            "owned_by": "google",
            "revision": CONFIG["revision"],
            "dimensions": CONFIG["supported_dimensions"],
        }],
    }


@app.post("/v1/embeddings")
async def embeddings(request: EmbeddingRequest):
    global inflight
    if not encoder.ready:
        raise HTTPException(503, "Model is not ready")
    texts = [request.input] if isinstance(request.input, str) else request.input
    if not 1 <= len(texts) <= CONFIG["max_batch_size"]:
        raise HTTPException(400, f"Supply 1–{CONFIG['max_batch_size']} inputs")
    if any(not text.strip() for text in texts):
        raise HTTPException(400, "Inputs must contain non-empty text")
    if inflight >= CONFIG["max_pending_requests"]:
        raise HTTPException(429, "Local inference queue is full; retry later")
    inflight += 1
    loop = asyncio.get_running_loop()
    future = worker.submit(encoder.encode, texts, request.input_type, request.dimensions)

    def release():
        global inflight
        inflight -= 1

    # Track the actual worker even when a client disconnects or cancels its wait.
    future.add_done_callback(lambda _: loop.call_soon_threadsafe(release))
    try:
        result = await asyncio.shield(asyncio.wrap_future(future))
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    except Exception as exc:
        LOG.exception("Embedding inference failed")
        raise HTTPException(500, "Embedding inference failed; inspect the service log") from exc
    return {
        "object": "list",
        "data": [
            {"object": "embedding", "index": index, "embedding": vector}
            for index, vector in enumerate(result["vectors"])
        ],
        "model": CONFIG["model_id"],
        "usage": {
            "prompt_tokens": result["total_tokens"],
            "total_tokens": result["total_tokens"],
        },
        "input_type": request.input_type,
        "dimensions": request.dimensions,
        "encoder_signature": encoder.signature,
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=CONFIG["host"],
        port=CONFIG["port"],
        workers=1,
        access_log=False,
        timeout_keep_alive=5,
    )
