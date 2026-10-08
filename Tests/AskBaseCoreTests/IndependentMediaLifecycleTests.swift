import Foundation
import XCTest
@testable import AskBaseCore

private actor ReviewMediaEncoder: EmbeddingProviding {
    static let vector: [Float] = [1] + Array(repeating: 0, count: 767)
    private var pauseNext = false
    private var paused: CheckedContinuation<Void, Never>?
    private var calls = 0
    func health() async throws -> EmbeddingHealth {
        return EmbeddingHealth(encoderSignature: "review-text", modalities: ["text", "image", "audio", "video"],
                               mediaEncoderSignature: "review-media")
    }
    func embed(_ texts: [String], inputType: String) async throws -> EmbeddingBatch {
        return EmbeddingBatch(vectors: texts.map { _ in Self.vector }, signature: "review-text")
    }
    func embedMedia(_ input: MediaEmbeddingInput, inputType: String) async throws -> EmbeddingBatch {
        guard input.isValid else { throw AskBaseError.invalidInput("Invalid prepared segment") }
        calls += 1
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { paused = $0 }
        }
        return EmbeddingBatch(vectors: [Self.vector], signature: "review-text", mediaSignature: "review-media")
    }
    func arm() { pauseNext = true }
    func resume() { let saved = paused; paused = nil; saved?.resume() }
    func isPaused() -> Bool { paused != nil }
    func callCount() -> Int { calls }
}

private struct ReviewChat: ChatProviding {
    func models() async throws -> [String] { ["offline"] }
    func answer(model: String, question: String, sources: [SearchResult], history: [ChatMessage]) async throws -> String {
        XCTAssertTrue(sources.allSatisfy(\.hasReadableEvidence))
        return "Evidence [1]"
    }
}

final class IndependentMediaLifecycleTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskBase-IndependentMediaLifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }
    private func audio() throws -> URL {
        let frames = 324_000, count = frames * 2
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func u16(_ number: UInt16) { var little = number.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ number: UInt32) { var little = number.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + count)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16); ascii("data"); u32(UInt32(count))
        data.append(Data(repeating: 0, count: count))
        let url = directory.appendingPathComponent("source.wav")
        try data.write(to: url)
        return url
    }
    private func waitUntilPaused(_ encoder: ReviewMediaEncoder) async throws {
        for _ in 0..<400 {
            if await encoder.isPaused() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AskBaseError.invalidInput("Timed out waiting for offline gate")
    }
    private func engine(_ encoder: ReviewMediaEncoder) throws -> KnowledgeEngine {
        try KnowledgeEngine(root: directory.appendingPathComponent("library"), embeddingClient: encoder, chatClient: ReviewChat())
    }

    func testCancelImportKeepsOnlyFailedOwnedCopyAndCanRetry() async throws {
        let encoder = ReviewMediaEncoder()
        let gated = try KnowledgeEngine(root: directory.appendingPathComponent("gated"), embeddingClient: encoder)
        let base = try await gated.snapshot().knowledgeBases[0]
        let file = try audio()
        await encoder.arm()
        let task = Task { try await gated.importDocuments(urls: [file], knowledgeBaseID: base.id) }
        try await waitUntilPaused(encoder)
        let snapshot = try await gated.snapshot()
        let document = try XCTUnwrap(snapshot.documents.first)
        task.cancel()
        await encoder.resume()
        do { _ = try await task.value; XCTFail("Cancelled import committed") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        let after = try await gated.snapshot()
        XCTAssertEqual(after.documents.first?.status, .failed)
        let noChunks = try await gated.documentChunks(documentID: document.id)
        XCTAssertTrue(noChunks.isEmpty)
        let original = try await gated.originalURL(documentID: document.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        try await gated.reindex(documentID: document.id)
        let restored = try await gated.documentChunks(documentID: document.id)
        XCTAssertEqual(restored.count, 3)
    }

    func testCancelReindexKeepsCommittedChunksAndConcurrentMetadata() async throws {
        let encoder = ReviewMediaEncoder()
        let engine = try engine(encoder)
        let base = try await engine.snapshot().knowledgeBases[0]
        let imported = try await engine.importDocuments(urls: [audio()], knowledgeBaseID: base.id)
        var document = try XCTUnwrap(imported.imported.first, imported.failures.joined(separator: ","))
        let original = try await engine.documentChunks(documentID: document.id)
        await encoder.arm()
        let task = Task { try await engine.reindex(documentID: document.id) }
        try await waitUntilPaused(encoder)
        document.title = "Edited during reindex"; document.isFavorite = true; document.tags = ["retained"]
        try await engine.updateDocument(document)
        task.cancel()
        await encoder.resume()
        do { try await task.value; XCTFail("Cancelled reindex committed") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        let after = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(after, original)
        let state = try await engine.snapshot()
        XCTAssertEqual(state.documents.first?.status, .ready)
        XCTAssertEqual(state.documents.first?.title, "Edited during reindex")
        XCTAssertEqual(state.documents.first?.isFavorite, true)
        XCTAssertEqual(state.documents.first?.tags, ["retained"])
    }

    func testDeletionDuringImportDoesNotResurrectRecordsOrFiles() async throws {
        let encoder = ReviewMediaEncoder(), file = try audio()
        let engine = try engine(encoder)
        let base = try await engine.snapshot().knowledgeBases[0]
        await encoder.arm()
        let task = Task { try await engine.importDocuments(urls: [file], knowledgeBaseID: base.id) }
        try await waitUntilPaused(encoder)
        let state = try await engine.snapshot()
        let document = try XCTUnwrap(state.documents.first)
        let original = try await engine.originalURL(documentID: document.id)
        let callsBeforeDeletion = await encoder.callCount()
        XCTAssertEqual(callsBeforeDeletion, 1, "Delete while the first segment response is paused")
        try await engine.deleteDocument(id: document.id)
        await encoder.resume()
        let report = try await task.value
        XCTAssertTrue(report.imported.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        let after = try await engine.snapshot()
        XCTAssertTrue(after.documents.isEmpty)
        let chunks = try await engine.documentChunks(documentID: document.id)
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let encodedSegments = await encoder.callCount()
        XCTAssertEqual(encodedSegments, 1, "Deleting during the first response must prevent encoding subsequent segments")
        print("REVIEW deletion-during-import media calls:", encodedSegments)
    }

    func testDeletionDuringReindexDoesNotResurrectRecords() async throws {
        let encoder = ReviewMediaEncoder()
        let engine = try engine(encoder)
        let base = try await engine.snapshot().knowledgeBases[0]
        let imported = try await engine.importDocuments(urls: [audio()], knowledgeBaseID: base.id)
        let document = try XCTUnwrap(imported.imported.first)
        await encoder.arm()
        let task = Task { try await engine.reindex(documentID: document.id) }
        try await waitUntilPaused(encoder)
        try await engine.deleteDocument(id: document.id)
        await encoder.resume()
        do { try await task.value; XCTFail("Deleted document was reindexed") } catch {}
        let after = try await engine.snapshot()
        XCTAssertTrue(after.documents.isEmpty)
        let chunks = try await engine.documentChunks(documentID: document.id)
        XCTAssertTrue(chunks.isEmpty)
    }

    func testMediaQueryRefreshesDeletionAndRemainsIsolatedAcrossDuplicateFiles() async throws {
        let encoder = ReviewMediaEncoder(), file = try audio()
        let engine = try engine(encoder)
        let base = try await engine.snapshot().knowledgeBases[0]
        let other = try await engine.createKnowledgeBase(name: "Other")
        let first = try await engine.importDocuments(urls: [file], knowledgeBaseID: base.id)
        let second = try await engine.importDocuments(urls: [file], knowledgeBaseID: other.id)
        let removed = try XCTUnwrap(first.imported.first)
        let retained = try XCTUnwrap(second.imported.first)
        await encoder.arm()
        let task = Task { try await engine.search(mediaURL: file, knowledgeBaseID: base.id) }
        try await waitUntilPaused(encoder)
        try await engine.deleteDocument(id: removed.id)
        await encoder.resume()
        let results = try await task.value
        XCTAssertTrue(results.isEmpty)
        let otherResults = try await engine.search(query: "anything", knowledgeBaseID: other.id)
        XCTAssertEqual(otherResults.count, 3)
        XCTAssertTrue(otherResults.allSatisfy { $0.knowledgeBaseID == other.id && $0.documentID == retained.id })
        let snapshot = try await engine.snapshot()
        XCTAssertEqual(snapshot.documents.map(\.id), [retained.id])
    }

    func testDeletedBaseDuringMediaQueryCannotReturnResults() async throws {
        let encoder = ReviewMediaEncoder(), file = try audio()
        let engine = try engine(encoder)
        let base = try await engine.snapshot().knowledgeBases[0]
        _ = try await engine.importDocuments(urls: [file], knowledgeBaseID: base.id)
        await encoder.arm()
        let task = Task { try await engine.search(mediaURL: file, knowledgeBaseID: base.id) }
        try await waitUntilPaused(encoder)
        try await engine.deleteKnowledgeBase(id: base.id)
        await encoder.resume()
        do { _ = try await task.value; XCTFail("Deleted base query returned") } catch {}
        let snapshot = try await engine.snapshot()
        XCTAssertTrue(snapshot.documents.isEmpty)
        XCTAssertTrue(snapshot.knowledgeBases.isEmpty)
    }

    func testMediaCitationMustRetainExactPositionAndBeRevokedOnChange() throws {
        let store = try LibraryStore(root: directory.appendingPathComponent("store"))
        let base = try store.createKnowledgeBase(name: "Video")
        let other = try store.createKnowledgeBase(name: "Other")
        let id = UUID().uuidString
        let document = LibraryDocument(id: id, knowledgeBaseID: base.id, title: "OCR video", fileName: "clip.mov",
                                       relativePath: "Originals/\(id).mov", contentHash: "offline-fixture",
                                       media: MediaReference(kind: .video, startSeconds: 0, endSeconds: 10))
        try store.upsertDocument(document)
        var chunk = DocumentChunk(documentID: id, knowledgeBaseID: base.id, ordinal: 0, text: "Visible text",
                                  embedding: ReviewMediaEncoder.vector, encoderSignature: "review-text",
                                  media: MediaReference(kind: .video, startSeconds: 0, endSeconds: 10, frameTimes: [1, 5, 9],
                                                        audioIncluded: false, textSource: .ocr,
                                                        encoderSignature: "review-media", recipe: MediaProcessor.recipe))
        try store.replaceChunks(documentID: id, chunks: [chunk])
        let hit = try XCTUnwrap(Retrieval.rank(query: "Visible", vector: ReviewMediaEncoder.vector,
                                              chunks: [chunk], documents: [document], limit: 1).first)
        let conversation = try store.createConversation(knowledgeBaseID: base.id, title: "Evidence")
        let otherConversation = try store.createConversation(knowledgeBaseID: other.id, title: "Other")
        var forged = hit; forged.media?.frameTimes = [2, 5, 9]
        XCTAssertThrowsError(try store.saveMessage(ChatMessage(conversationID: conversation.id, role: "assistant", content: "Forged [1]", sources: [forged])))
        XCTAssertThrowsError(try store.saveMessage(ChatMessage(conversationID: otherConversation.id, role: "assistant", content: "Cross base [1]", sources: [hit])))
        try store.saveMessage(ChatMessage(conversationID: conversation.id, role: "assistant", content: "Valid [1]", sources: [hit]))
        chunk.media?.frameTimes = [2, 5, 9]
        try store.replaceChunks(documentID: id, chunks: [chunk])
        let messages = try store.messages(conversationID: conversation.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].sources.isEmpty)
        XCTAssertTrue(messages[0].content.contains("来源已更新"))
    }
}
