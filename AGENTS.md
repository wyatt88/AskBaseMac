# AskBase Local engineering guide

This is a native macOS knowledge-base app, written in SwiftUI with a Foundation / SQLite
core. Its embedding model is EmbeddingGemma 2. Do not replace it with a different model
merely because another embedding API uses the same vector dimension.

## Structure

- `Sources/AskBaseCore`: persistence, import, chunking, retrieval, local model clients.
- `Sources/AskBaseMac`: native interface and application state.
- `Sources/AskBaseCLI`: isolated integration checks and useful CLI operations.
- `services/embeddinggemma2`: pinned, independently installed MLX model service.
- `scripts`: model setup and signed app bundle construction.

## Checks

Run `swift test` after meaningful core changes. The default tests must remain offline and
use temporary libraries. `swift run askbase smoke` uses the real local embedding model;
add `--model <installed-local-model>` to exercise generation. Never run tests on a user's
real library. Build the app with `python3 scripts/build_app.py`.

## Data and correctness

- Model URLs must remain loopback-only, redirects disabled, no cloud fallbacks.
- Query and document prefixes are different and supplied by the embedding service.
- Bind embeddings to the actual encoder signature plus dimensions. Querying across
  incompatible spaces must fail clearly; support deliberate document reindexing.
- Ready means useful nonempty text and a complete committed vector set. Preserve the
  previous usable index if reindexing fails.
- Deletion and updates must invalidate corresponding search entries and saved citations.
- No auto-importing user folders, no automatic promotion of generated answers to sources.
- Keep model weights, Python environments, logs, credentials and user data out of Git.
- Model/host checks, synthetic integration checks, real-corpus quality and Apple
  notarization are distinct evidence. Document what was actually run.
