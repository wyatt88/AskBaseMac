# Implementation contract

Owner: main agent (networking, engine, integration, delivery). Worker A owns storage/import.
Worker B owns native app UI. Shared Models.swift is owned by main. Use Swift 5 language
mode with Swift 6 toolchain, macOS 14+. No external Swift packages.

## Storage / importer API (worker A)

`public final class LibraryStore: @unchecked Sendable`, synchronous methods; all calls
normally serialized by `KnowledgeEngine` actor. Use SQLite serialized/thread-safe access.

```
init(root: URL) throws              // root/library.sqlite, root/Originals
var root: URL { get }
func snapshot() throws -> LibrarySnapshot
func createKnowledgeBase(name: String) throws -> KnowledgeBase
func renameKnowledgeBase(id: String, name: String) throws
func deleteKnowledgeBase(id: String) throws
func upsertDocument(_ document: LibraryDocument) throws
func document(id: String) throws -> LibraryDocument?
func duplicate(contentHash: String, knowledgeBaseID: String) throws -> LibraryDocument?
func replaceChunks(documentID: String, chunks: [DocumentChunk]) throws
func chunks(knowledgeBaseID: String) throws -> [DocumentChunk] // ready documents only
func documentChunks(documentID: String) throws -> [DocumentChunk]
func deleteDocument(id: String) throws  // chunks + copied original; invalidate sources in saved chats
func saveNote(_ note: LibraryNote) throws
func deleteNote(id: String) throws
func createConversation(knowledgeBaseID: String, title: String) throws -> Conversation
func messages(conversationID: String) throws -> [ChatMessage]
func saveMessage(_ message: ChatMessage) throws
func saveExchange(user: ChatMessage, assistant: ChatMessage) throws // atomic successful turn
func deleteConversation(id: String) throws
func settings() throws -> AppSettings
func saveSettings(_ settings: AppSettings) throws
func recoverInterruptedImports() throws  // indexing -> failed with retry explanation
```

`public enum DocumentImporter`:
```
static func expand(_ urls: [URL]) throws -> [URL]   // no quotas or extension filter; skip hidden descendants/packages/symlinks
static func prepare(url: URL, knowledgeBaseID: String, originalsRoot: URL) throws -> PreparedDocument
static func parse(url: URL, originalFilename: String? = nil) throws -> [ParsedPage]
```

`public enum TextChunker`:
```
static func chunks(pages: [ParsedPage], documentID: String, knowledgeBaseID: String,
                   maxCharacters: Int = 1200, overlap: Int = 160) -> [DocumentChunk]
// Internal import/reindex entrypoint throws on cancellation, never returns a partial result.
static func cancellableChunks(pages: [ParsedPage], documentID: String, knowledgeBaseID: String,
                              maxCharacters: Int = 1200, overlap: Int = 160) throws -> [DocumentChunk]
```

There are no fixed file byte, extracted text, PDF page, batch count, traversal count,
directory depth, or extension quotas. Explicitly selected hidden files are accepted;
folder imports skip hidden descendants, file packages, and symlinks.
Use a private disk snapshot, incremental SHA256, and streamed managed-original copy so
the parser, digest, and stored original refer to exactly the same bytes. Reject changed
inputs, pipes, devices, unreadable content, and formats without usable text explicitly.
Text chunking uses grapheme-safe String indices without a whole-document Character array.
Reject scanned PDFs with a clear OCR message; no OCR promise.
SHA256 whole file duplicate identity within KB. Store copies under UUID filenames,
with an optional original extension. Reindex passes the original filename as a type hint.
Cancellation must propagate instead of producing partial ready documents.
SQLite transactionally replaces chunks and marks ready only on nonempty finite, L2-normalized 768d
matching-signature embeddings. JSON encode records acceptable; keys/FKs ensure deletion.
Tests: chunk bounds and multilingual coverage/overlap, duplicate identity, atomic failed
replacement, cascade isolation, crash recovery, source invalidation, note persistence.

## Engine API (main agent)

`public actor KnowledgeEngine`:
```
static var defaultRoot: URL { get }
init(root: URL = KnowledgeEngine.defaultRoot) throws
var root: URL { get } // nonisolated
func snapshot() throws -> LibrarySnapshot
func settings() throws -> AppSettings
func saveSettings(_ settings: AppSettings) throws
func modelStatus() async -> ModelStatus
func createKnowledgeBase(name: String) throws -> KnowledgeBase
func renameKnowledgeBase(id: String, name: String) throws
func deleteKnowledgeBase(id: String) throws
func importDocuments(urls: [URL], knowledgeBaseID: String) async throws -> ImportReport
func reindex(documentID: String) async throws
func search(query: String, knowledgeBaseID: String) async throws -> [SearchResult]
func deleteDocument(id: String) throws
func updateDocument(_ document: LibraryDocument) throws // favorite/tags/title only
func originalURL(documentID: String) throws -> URL
func documentChunks(documentID: String) throws -> [DocumentChunk]
func saveNote(_ note: LibraryNote) throws
func deleteNote(id: String) throws
func createConversation(knowledgeBaseID: String, title: String) throws -> Conversation
func messages(conversationID: String) throws -> [ChatMessage]
func ask(question: String, conversationID: String, knowledgeBaseID: String) async throws -> ChatMessage
func deleteConversation(id: String) throws
```

Engine will seed one empty KB ("我的知识库"). Conversation history persisted.
Search requires EG2, compares 768d signature, modest hybrid lexical boost + cosine.
Ask retrieves first and invokes local Ollama only if a local model is configured; error
retains source search availability. No fabricated AI responses. Read-only text sources
are delimited untrusted input in generation prompt; stable [1] citations exposed in UI.
Notes are personal editable scratchpad, *not indexed automatically*.

## Native UI (worker B)

Own all `Sources/AskBaseMac/**`. Native SwiftUI `@main` app and `@MainActor` state.
Use above API via `await`; implement views and orchestration. Sidebar: KB selector/list,
资料库 / 语义搜索 / 知识问答 / 笔记 / 设置. Chinese labels, refined warm neutral + teal
accent, good dark mode and minimum window size ~1100x720. No stock web-like dashboard.
Useful empty state and real zero data, explicit model connectivity states. Open panel
imports supported files and folders; drag/drop URLs; per-file failure reports; favorites
and tags; document/source detail with snippets and page info + open stored original.
Search results and chat source cards open provenance; data removal confirmation only
for irreversible library deletes. Chat draft, progress/cancel, history, sources. Settings
test endpoints and select actual available Ollama model; localhost-only engine enforcement.
Note create/edit/delete/export via native panel. Export chat markdown with source list.
Do not claim a model is connected until modelStatus succeeds. Do not auto-import user files.
Keep UI responsive during indexing. Include startup error screen if DB fails.

## Local verification

Offline core tests use temporary directories and deterministic fixtures. Main provides
CLI import/search/ask/smoke for live integration into isolated temporary library. Core
tests must not contact live models or operate on user's real library.
