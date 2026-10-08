import XCTest
@testable import AskBaseCore

private struct FakeEmbedder: EmbeddingProviding {
    var signature: String = "test-space-v1"
    var badVectors = false
    func health() async throws -> EmbeddingHealth { EmbeddingHealth(encoderSignature: signature) }
    func embed(_ texts: [String], inputType: String) async throws -> EmbeddingBatch {
        let vectors = texts.map { text -> [Float] in
            if badVectors { return [Float.nan] }
            var vector = Array(repeating: Float(0), count: 768)
            vector[text.contains("火星") ? 0 : 1] = 1
            return vector
        }
        return EmbeddingBatch(vectors: vectors, signature: signature)
    }
}

private struct FakeChat: ChatProviding {
    func models() async throws -> [String] { ["test-local-model"] }
    func answer(model: String, question: String, sources: [SearchResult], history: [ChatMessage]) async throws -> String {
        "火星任务由林舟负责。[1]"
    }
}

private actor PausedEmbedder: EmbeddingProviding {
    private var pending: CheckedContinuation<EmbeddingBatch, Error>?
    func health() async throws -> EmbeddingHealth { EmbeddingHealth(encoderSignature: "paused-v1") }
    func embed(_ texts: [String], inputType: String) async throws -> EmbeddingBatch {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    var isWaiting: Bool { pending != nil }
    func fail() {
        pending?.resume(throwing: AskBaseError.modelUnavailable("Synthetic model failure"))
        pending = nil
    }
}

final class EngineTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskBaseEngineTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func fixture(_ name: String, _ text: String) throws -> URL {
        let path = directory.appendingPathComponent(name)
        try text.write(to: path, atomically: true, encoding: .utf8)
        return path
    }
    private func engine(_ embedder: FakeEmbedder = FakeEmbedder()) throws -> KnowledgeEngine {
        try KnowledgeEngine(root: directory.appendingPathComponent("library"), embeddingClient: embedder, chatClient: FakeChat())
    }

    func testLocalEndpointRejectsExfiltrationAndAmbiguousAddresses() throws {
        for url in ["http://127.0.0.1:8871", "http://localhost:11434/", "http://[::1]:8871"] {
            XCTAssertNoThrow(try LocalEndpoint.validate(url))
        }
        for url in ["https://example.com", "http://127.0.0.1.example.com", "http://127.0.0.1@evil.test",
                    "http://user:pass@localhost:8871", "file:///tmp/x", "http://localhost/v1",
                    "http://localhost?redirect=evil", "http://127.1:8871", "http://0.0.0.0:8871",
                    "http://2130706433:8871", "http://localhost#fragment"] {
            XCTAssertThrowsError(try LocalEndpoint.validate(url), url)
        }
    }

    func testSearchAndChatUseSameKnowledgeBaseWithProvenance() async throws {
        let engine = try engine()
        let kb = try await engine.snapshot().knowledgeBases[0]
        let other = try await engine.createKnowledgeBase(name: "另一个知识库")
        let file = try fixture("火星.md", "火星任务由林舟负责。\n任务期限是十月。")
        let report = try await engine.importDocuments(urls: [file], knowledgeBaseID: kb.id)
        XCTAssertEqual(report.imported.count, 1, report.failures.joined(separator: "\n"))
        let hits = try await engine.search(query: "火星负责人", knowledgeBaseID: kb.id)
        XCTAssertEqual(hits.first?.documentID, report.imported.first?.id)
        let isolated = try await engine.search(query: "火星负责人", knowledgeBaseID: other.id)
        XCTAssertTrue(isolated.isEmpty)
        var settings = try await engine.settings(); settings.chatModel = "test-local-model"
        try await engine.saveSettings(settings)
        let conversation = try await engine.createConversation(knowledgeBaseID: kb.id, title: "火星")
        let answer = try await engine.ask(question: "火星负责人", conversationID: conversation.id, knowledgeBaseID: kb.id)
        XCTAssertEqual(answer.sources.first?.id, hits.first?.id)
        let messages = try await engine.messages(conversationID: conversation.id)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        do {
            _ = try await engine.ask(question: "火星负责人", conversationID: conversation.id, knowledgeBaseID: other.id)
            XCTFail("Cross-knowledge-base conversation must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不一致")) }
    }

    func testModelChangeRequiresReindexRatherThanMixingSpaces() async throws {
        let original = try engine()
        let kb = try await original.snapshot().knowledgeBases[0]
        let file = try fixture("火星.md", "火星任务由林舟负责。")
        let report = try await original.importDocuments(urls: [file], knowledgeBaseID: kb.id)
        let changed = try engine(FakeEmbedder(signature: "test-space-v2"))
        do {
            _ = try await changed.search(query: "火星", knowledgeBaseID: kb.id)
            XCTFail("Different embedding space must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("另一编码版本")) }
        try await changed.reindex(documentID: XCTUnwrap(report.imported.first?.id))
        let hits = try await changed.search(query: "火星", knowledgeBaseID: kb.id)
        XCTAssertEqual(hits.count, 1)
    }

    func testUnlistedAndExtensionlessTextImportReindexAndDeleteWithIsolatedFailures() async throws {
        let engine = try engine()
        let kb = try await engine.snapshot().knowledgeBases[0]
        let custom = try fixture("mission.unlisted-format", "火星任务由林舟负责。")
        let extensionless = try fixture("README", "知识库完整保存无扩展名的文字资料。")
        let binary = directory.appendingPathComponent("image.bin")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: binary)
        let report = try await engine.importDocuments(urls: [custom, binary, extensionless], knowledgeBaseID: kb.id)
        XCTAssertEqual(Set(report.imported.map(\.fileName)), ["mission.unlisted-format", "README"])
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].contains("image.bin"))
        for document in report.imported {
            XCTAssertEqual(document.status, .ready)
            let original = try await engine.originalURL(documentID: document.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            try await engine.reindex(documentID: document.id)
            let chunks = try await engine.documentChunks(documentID: document.id)
            XCTAssertFalse(chunks.isEmpty)
            XCTAssertTrue(chunks.allSatisfy { $0.embedding.count == 768 && $0.encoderSignature == "test-space-v1" })
            try await engine.deleteDocument(id: document.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: custom.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extensionless.path))
        let snapshot = try await engine.snapshot()
        XCTAssertTrue(snapshot.documents.isEmpty)
    }

    func testBadEmbeddingsNeverMarkAFileReady() async throws {
        let engine = try engine(FakeEmbedder(badVectors: true))
        let kb = try await engine.snapshot().knowledgeBases[0]
        let file = try fixture("火星.md", "火星任务由林舟负责。")
        let report = try await engine.importDocuments(urls: [file], knowledgeBaseID: kb.id)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.imported.isEmpty)
        let snapshot = try await engine.snapshot()
        XCTAssertEqual(snapshot.documents.first?.status, .failed)
        if let document = snapshot.documents.first {
            let chunks = try await engine.documentChunks(documentID: document.id)
            XCTAssertTrue(chunks.isEmpty)
        }
    }

    func testSettingsRejectRemoteModelBeforeAnyRequest() async throws {
        let engine = try engine()
        do {
            try await engine.saveSettings(AppSettings(embeddingBaseURL: "https://example.com"))
            XCTFail("Remote model URL must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("本机")) }
        let settings = try await engine.settings()
        XCTAssertEqual(settings.embeddingBaseURL, "http://127.0.0.1:8871")
    }

    func testEmptyQuestionDoesNotCreateMessages() async throws {
        let engine = try engine()
        let kb = try await engine.snapshot().knowledgeBases[0]
        var settings = try await engine.settings(); settings.chatModel = "test-local-model"
        try await engine.saveSettings(settings)
        let conversation = try await engine.createConversation(knowledgeBaseID: kb.id, title: "测试")
        do {
            _ = try await engine.ask(question: "", conversationID: conversation.id, knowledgeBaseID: kb.id)
            XCTFail("Empty input must fail")
        } catch {}
        let messages = try await engine.messages(conversationID: conversation.id)
        XCTAssertTrue(messages.isEmpty)
    }

    func testCancellingImportPreservesMetadataEditedDuringEmbedding() async throws {
        let paused = PausedEmbedder()
        let engine = try KnowledgeEngine(root: directory.appendingPathComponent("library"),
                                         embeddingClient: paused, chatClient: FakeChat())
        let kb = try await engine.snapshot().knowledgeBases[0]
        let file = try fixture("火星.md", "火星任务由林舟负责。")
        let task = Task { try await engine.importDocuments(urls: [file], knowledgeBaseID: kb.id) }
        for _ in 0..<100 {
            if await paused.isWaiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await paused.isWaiting
        XCTAssertTrue(waiting)
        let pendingSnapshot = try await engine.snapshot()
        var document = try XCTUnwrap(pendingSnapshot.documents.first)
        document.title = "用户刚修改的标题"
        document.isFavorite = true
        document.tags = ["保留"]
        try await engine.updateDocument(document)
        do {
            try await engine.reindex(documentID: document.id)
            XCTFail("Reindex must not race an initial import")
        } catch { XCTAssertTrue(error.localizedDescription.contains("仍在导入")) }
        task.cancel()
        await paused.fail()
        do { _ = try await task.value; XCTFail("Cancelled import must cancel") } catch {}
        let snapshot = try await engine.snapshot()
        let saved = try XCTUnwrap(snapshot.documents.first)
        XCTAssertEqual(saved.title, "用户刚修改的标题")
        XCTAssertTrue(saved.isFavorite)
        XCTAssertEqual(saved.tags, ["保留"])
        XCTAssertEqual(saved.status, .failed)
    }
}
