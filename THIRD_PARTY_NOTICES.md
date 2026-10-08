# Third-party components

AskBase Local's original source code, documentation, and application assets are
licensed under [Apache License 2.0](LICENSE). This does not change the licenses of
third-party components or separately downloaded models.

| Component | Use | License and source |
| --- | --- | --- |
| EmbeddingGemma 2, Google DeepMind | Separately downloaded embedding model | The [official model card](https://huggingface.co/google/embeddinggemma-2/tree/914f7f89142e33e77833254d9c9b90c3cef7303b) at revision `914f7f89142e33e77833254d9c9b90c3cef7303b` declares Apache-2.0. |
| MLX 0.32.3, Apple | Separately installed Apple Silicon inference library | [MIT](https://github.com/ml-explore/mlx/blob/v0.32.3/LICENSE). |
| MLX-VLM, Prince Canuma and contributors | Separately installed embedding-model loader | [MIT](https://github.com/Blaizzy/mlx-vlm/blob/4f4634bb813c0298cb1467bed2e957526c71d0b4/LICENSE), pinned to commit `4f4634bb813c0298cb1467bed2e957526c71d0b4`. |
| Ollama | Optional, separately installed answer-model runtime | [MIT](https://github.com/ollama/ollama/blob/main/LICENSE). The runtime's license does not determine a selected model's license. |
| SQLite | macOS system library | [Public domain](https://www.sqlite.org/copyright.html). |
| SwiftUI, AppKit, Foundation, PDFKit, Accelerate | Apple system frameworks | Provided by macOS under Apple's applicable terms; not relicensed by this project. |
| `/usr/bin/unzip` | macOS-provided archive utility | Invoked to read selected ZIP members; not bundled or relicensed by this project. Its existing system distribution terms apply. |

The repository and macOS application package do not include model weights,
Ollama, or Python dependency distributions. The embedding setup downloads
official model files, verifies their published hashes, and installs the versions
in [requirements.lock.txt](services/embeddinggemma2/requirements.lock.txt).
Those distributions retain their own license and copyright files.

Answer models are selected and installed separately by the user. Check the
chosen model's upstream terms before using or redistributing its weights.
