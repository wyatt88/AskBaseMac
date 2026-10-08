# Changelog

## 0.2.0 — 2026-10-09

- Remove fixed import file-size, extracted-text, PDF-page, batch-count, directory-entry,
  and directory-depth limits.
- Replace the extension allowlist with content-based extraction; accept readable text
  with custom extensions or no extension, including explicitly selected hidden files.
- Add RTF, DOCX, XLSX, PPTX, ODT, EPUB, and UTF-32 text extraction.
- Stream original-file snapshots, hashing, and managed copies; chunk large text without
  allocating a Character array for the full document.
- Preserve cancellation, original-byte consistency, per-file error reporting, and atomic
  index commits. Model services, encoder identity, and existing libraries stay compatible.
- Reject incomplete declared Office/EPUB content, clean uncommitted original copies,
  and validate managed paths by filesystem bytes, including combining-character filenames.

## 0.1.1 — 2026-10-08

- Adopt Apache License 2.0 for the project's original code, documentation, and assets.
- Include `LICENSE`, `NOTICE`, and third-party notices in application packages.
- Keep the build copy in a `.noindex` directory to avoid duplicate application search entries.
- Clarify the separate licenses of models, inference runtimes, and system frameworks.

This release changes licensing and packaging; the knowledge-base and model behavior is unchanged.

## 0.1.0 — 2026-10-07

- Initial native macOS knowledge base with EmbeddingGemma 2 retrieval, local Ollama answers,
  source citations, document management, and notes.
