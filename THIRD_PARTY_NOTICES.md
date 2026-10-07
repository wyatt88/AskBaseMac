# Third-party components

- **EmbeddingGemma 2** is developed by Google DeepMind. The model card at the pinned revision declares **Apache 2.0**. We download official weights and verify their published hashes; weights are not included in this repository. See [model card](https://huggingface.co/google/embeddinggemma-2/tree/914f7f89142e33e77833254d9c9b90c3cef7303b).
- **MLX / MLX-VLM** provide local Apple Silicon inference. MLX-VLM is pinned to commit `4f4634bb813c0298cb1467bed2e957526c71d0b4`. Python dependency distributions retain their respective licenses.
- **Ollama** is an external optional runtime for the answer model. Each selected model has its own license; answer model weights are not distributed here.
- **SQLite** is used through the macOS system library. SwiftUI, AppKit, PDFKit and Accelerate are Apple system frameworks.

This private application repository does not grant an open-source license for its own code. The repository owner can choose a license before public distribution.
