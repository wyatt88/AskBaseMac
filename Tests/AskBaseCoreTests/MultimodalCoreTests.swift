import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AskBaseCore

private actor MediaTestEmbedder: EmbeddingProviding {
    private var mediaSignature = "media-test-v1"
    private var mediaCalls = 0
    private var failAt: Int?
    private var textInputs: [String] = []
    func health() async throws -> EmbeddingHealth {
        EmbeddingHealth(encoderSignature: "unchanged-text-v1", modalities: ["text", "image", "audio", "video"],
                        mediaEncoderSignature: mediaSignature)
    }
    func embed(_ texts: [String], inputType: String) async throws -> EmbeddingBatch {
        textInputs += texts
        return EmbeddingBatch(vectors: texts.map { _ in Self.vector }, signature: "unchanged-text-v1")
    }
    func embedMedia(_ input: MediaEmbeddingInput, inputType: String) async throws -> EmbeddingBatch {
        guard input.isValid else { throw AskBaseError.invalidInput("Malformed fixture") }
        mediaCalls += 1
        if mediaCalls == failAt { throw AskBaseError.modelUnavailable("Synthetic media encoder failure") }
        return EmbeddingBatch(vectors: [Self.vector], signature: "unchanged-text-v1", mediaSignature: mediaSignature)
    }
    func changeSignature() { mediaSignature = "media-test-v2" }
    func failNextSegment() { failAt = mediaCalls + 2 }
    func inputs() -> [String] { textInputs }
    static var vector: [Float] { [1] + Array(repeating: 0, count: 767) }
}

private actor MediaTestChat: ChatProviding {
    private var calls = 0
    func models() async throws -> [String] { ["local-fixture"] }
    func answer(model: String, question: String, sources: [SearchResult], history: [ChatMessage]) async throws -> String {
        calls += 1
        guard sources.allSatisfy(\.hasReadableEvidence) else {
            throw AskBaseError.invalidInput("Opaque media leaked to text RAG")
        }
        return "测试文字资料。[1]"
    }
    func count() -> Int { calls }
}

final class MultimodalCoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskBase-MediaCore-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func image() throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let url = directory.appendingPathComponent("extensionless-image")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func audio(seconds: Double) throws -> URL {
        let frames = Int(seconds * 16_000), count = frames * 2
        var bytes = Data()
        func ascii(_ text: String) { bytes.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) { var le = value.littleEndian; withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var le = value.littleEndian; withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + count)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16); ascii("data"); u32(UInt32(count))
        for frame in 0..<frames {
            let value = Int16(sin(Double(frame) * 440 * 2 * .pi / 16_000) * 2_000)
            u16(UInt16(bitPattern: value))
        }
        let url = directory.appendingPathComponent("tone-without-extension")
        try bytes.write(to: url)
        return url
    }

    func testOldTextRecordsAndHealthDecodeWithoutMediaFields() throws {
        let base = KnowledgeBase(name: "Legacy")
        let id = UUID().uuidString
        let document = LibraryDocument(id: id, knowledgeBaseID: base.id, title: "Original",
                                       fileName: "original.txt", relativePath: "Originals/\(id).txt", contentHash: "hash")
        let chunk = DocumentChunk(documentID: id, knowledgeBaseID: base.id, ordinal: 0, text: "Legacy text")
        let source = SearchResult(id: chunk.id, documentID: id, knowledgeBaseID: base.id,
                                  title: "Original", text: chunk.text, score: 1)
        // Explicitly remove optional keys to model bytes written by 0.2.0.
        func legacy<T: Codable>(_ value: T) throws -> T {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            object.removeValue(forKey: "media")
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertNil(try legacy(document).media)
        XCTAssertNil(try legacy(chunk).media)
        XCTAssertTrue(try legacy(source).hasReadableEvidence)
        let health = try JSONDecoder().decode(EmbeddingHealth.self, from: Data(
            #"{"status":"ok","model":"embeddinggemma-2","dimensions":768,"encoder_signature":"old"}"#.utf8))
        XCTAssertNil(health.mediaEncoderSignature)
        XCTAssertFalse(health.supports(.image))
    }

    func testNativeImageImportSearchAndDeletePreserveMediaIdentity() async throws {
        let embedder = MediaTestEmbedder()
        let engine = try KnowledgeEngine(root: directory.appendingPathComponent("library"), embeddingClient: embedder)
        let base = try await engine.snapshot().knowledgeBases[0]
        let other = try await engine.createKnowledgeBase(name: "Other")
        let file = try image()
        let imported = try await engine.importDocuments(urls: [file], knowledgeBaseID: base.id)
        XCTAssertTrue(imported.failures.isEmpty, imported.failures.joined(separator: "\n"))
        let document = try XCTUnwrap(imported.imported.first)
        XCTAssertEqual(document.media?.kind, .image)
        let hits = try await engine.search(query: "red", knowledgeBaseID: base.id)
        XCTAssertEqual(hits.first?.media?.imageIndex, 0)
        XCTAssertEqual(hits.first?.media?.encoderSignature, "media-test-v1")
        XCTAssertFalse(try XCTUnwrap(hits.first).hasReadableEvidence)
        let mediaHits = try await engine.search(mediaURL: file, knowledgeBaseID: base.id)
        XCTAssertEqual(mediaHits.first?.id, hits.first?.id)
        let otherHits = try await engine.search(mediaURL: file, knowledgeBaseID: other.id)
        XCTAssertTrue(otherHits.isEmpty)
        let afterQuery = try await engine.snapshot()
        XCTAssertEqual(afterQuery.documents.count, 1, "Querying must not import the query file")
        let inputs = await embedder.inputs()
        XCTAssertEqual(inputs, AutoTagging.catalog.map(\.prompt) + ["red"],
                       "Only topic-label queries and the user query may reach the text encoder, never media placeholders")
        let original = try await engine.originalURL(documentID: document.id)
        try await engine.deleteDocument(id: document.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let afterDelete = try await engine.search(query: "red", knowledgeBaseID: base.id)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testAllAudioSegmentsAndTailCommitTogetherAndFailedReindexKeepsOldIndex() async throws {
        let embedder = MediaTestEmbedder()
        let engine = try KnowledgeEngine(root: directory.appendingPathComponent("library"), embeddingClient: embedder)
        let base = try await engine.snapshot().knowledgeBases[0]
        let imported = try await engine.importDocuments(urls: [audio(seconds: 20.25)], knowledgeBaseID: base.id)
        let document = try XCTUnwrap(imported.imported.first, imported.failures.joined(separator: "\n"))
        let chunks = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.compactMap { $0.media?.startSeconds }, [0, 10, 20])
        XCTAssertEqual(chunks.last?.media?.endSeconds ?? 0, 20.25, accuracy: 0.001)
        XCTAssertTrue(chunks.allSatisfy { $0.media?.textSource == nil && $0.embedding.count == 768 })
        await embedder.failNextSegment()
        do { try await engine.reindex(documentID: document.id); XCTFail("Partial reindex must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Synthetic")) }
        let after = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(after, chunks)
        let snapshot = try await engine.snapshot()
        XCTAssertEqual(snapshot.documents.first?.status, .ready)
        let restored = try KnowledgeEngine(root: directory.appendingPathComponent("library"), embeddingClient: embedder)
        let restoredChunks = try await restored.documentChunks(documentID: document.id)
        XCTAssertEqual(restoredChunks, chunks)
    }

    func testMediaSignatureChangeRequiresReindexButExistingTextSpaceStillWorks() async throws {
        let embedder = MediaTestEmbedder()
        let engine = try KnowledgeEngine(root: directory.appendingPathComponent("library"), embeddingClient: embedder)
        let base = try await engine.snapshot().knowledgeBases[0]
        let textBase = try await engine.createKnowledgeBase(name: "Text")
        let text = directory.appendingPathComponent("original.txt")
        try "Existing text".write(to: text, atomically: true, encoding: .utf8)
        let mediaImport = try await engine.importDocuments(urls: [image()], knowledgeBaseID: base.id)
        _ = try await engine.importDocuments(urls: [text], knowledgeBaseID: textBase.id)
        await embedder.changeSignature()
        do { _ = try await engine.search(query: "red", knowledgeBaseID: base.id); XCTFail("Old media encoding must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("媒体使用了不同")) }
        let textHits = try await engine.search(query: "text", knowledgeBaseID: textBase.id)
        XCTAssertEqual(textHits.count, 1)
        try await engine.reindex(documentID: XCTUnwrap(mediaImport.imported.first?.id))
        let mediaHits = try await engine.search(query: "red", knowledgeBaseID: base.id)
        XCTAssertEqual(mediaHits.first?.media?.encoderSignature, "media-test-v2")
    }

    func testOpaqueMediaDoesNotReachTextRAGAndCannotCrowdOutReadableSources() async throws {
        let embedder = MediaTestEmbedder(), generator = MediaTestChat()
        let engine = try KnowledgeEngine(root: directory.appendingPathComponent("library"),
                                         embeddingClient: embedder, chatClient: generator)
        let base = try await engine.snapshot().knowledgeBases[0]
        var settings = try await engine.settings(); settings.chatModel = "local-fixture"; settings.topK = 1
        try await engine.saveSettings(settings)
        let imported = try await engine.importDocuments(urls: [audio(seconds: 0.25)], knowledgeBaseID: base.id)
        XCTAssertEqual(imported.imported.count, 1, imported.failures.joined(separator: "\n"))
        let conversation = try await engine.createConversation(knowledgeBaseID: base.id, title: "Audio question")
        do {
            _ = try await engine.ask(question: "what is said?", conversationID: conversation.id, knowledgeBaseID: base.id)
            XCTFail("Audio embedding is not a transcript")
        } catch { XCTAssertTrue(error.localizedDescription.contains("OCR")) }
        let callsBeforeText = await generator.count()
        let messagesBeforeText = try await engine.messages(conversationID: conversation.id)
        XCTAssertEqual(callsBeforeText, 0); XCTAssertTrue(messagesBeforeText.isEmpty)
        let text = directory.appendingPathComponent("reference.txt")
        try "测试文字资料。".write(to: text, atomically: true, encoding: .utf8)
        _ = try await engine.importDocuments(urls: [text], knowledgeBaseID: base.id)
        let answer = try await engine.ask(question: "资料", conversationID: conversation.id, knowledgeBaseID: base.id)
        XCTAssertEqual(answer.sources.count, 1)
        XCTAssertNil(answer.sources[0].media)
        let callsAfterText = await generator.count()
        XCTAssertEqual(callsAfterText, 1)
    }

    func testChangedManagedMediaCannotBeSilentlyReindexed() async throws {
        let embedder = MediaTestEmbedder()
        let engine = try KnowledgeEngine(root: directory.appendingPathComponent("library"), embeddingClient: embedder)
        let base = try await engine.snapshot().knowledgeBases[0]
        let imported = try await engine.importDocuments(urls: [image()], knowledgeBaseID: base.id)
        let document = try XCTUnwrap(imported.imported.first)
        let chunks = try await engine.documentChunks(documentID: document.id)
        let original = try await engine.originalURL(documentID: document.id)
        try Data("Externally replaced file".utf8).write(to: original)
        do { try await engine.reindex(documentID: document.id); XCTFail("The content hash must stay meaningful") }
        catch { XCTAssertTrue(error.localizedDescription.contains("内容已改变")) }
        let after = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(after, chunks)
    }

    func testStoreRejectsGapsTruncationAndForgedMediaSources() throws {
        let store = try LibraryStore(root: directory.appendingPathComponent("store"))
        let base = try store.createKnowledgeBase(name: "Media")
        let id = UUID().uuidString
        let document = LibraryDocument(id: id, knowledgeBaseID: base.id, title: "Audio", fileName: "audio.wav",
                                       relativePath: "Originals/\(id).wav", contentHash: "fixture",
                                       media: MediaReference(kind: .audio, startSeconds: 0, endSeconds: 20))
        try store.upsertDocument(document)
        func segment(_ ordinal: Int, _ start: Double, _ end: Double) -> DocumentChunk {
            DocumentChunk(documentID: id, knowledgeBaseID: base.id, ordinal: ordinal, text: "Audio",
                          embedding: MediaTestEmbedder.vector, encoderSignature: "text",
                          media: MediaReference(kind: .audio, startSeconds: start, endSeconds: end,
                                                encoderSignature: "media", recipe: MediaProcessor.recipe))
        }
        XCTAssertThrowsError(try store.replaceChunks(documentID: id, chunks: [segment(0, 0, 10)]))
        XCTAssertThrowsError(try store.replaceChunks(documentID: id, chunks: [segment(0, 0, 9), segment(1, 10, 20)]))
        let complete = [segment(0, 0, 10), segment(1, 10, 20)]
        try store.replaceChunks(documentID: id, chunks: complete)
        let hits = Retrieval.rank(query: "", vector: MediaTestEmbedder.vector, chunks: complete, documents: [document], limit: 6)
        XCTAssertEqual(hits.count, 2, "Equal labels must not hide different audio timestamps")
        let conversation = try store.createConversation(knowledgeBaseID: base.id, title: "Source integrity")
        let user = ChatMessage(conversationID: conversation.id, role: "user", content: "question")
        let answer = ChatMessage(conversationID: conversation.id, role: "assistant", content: "unsupported [1]", sources: hits)
        XCTAssertThrowsError(try store.saveExchange(user: user, assistant: answer), "Opaque media cannot be text answer evidence")
        XCTAssertTrue(try store.messages(conversationID: conversation.id).isEmpty)
    }
}
