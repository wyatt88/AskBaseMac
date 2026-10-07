import CSQLite
import Darwin
import Foundation
import XCTest
@testable import AskBaseCore

final class StorageTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AskBaseStorageTests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }

    func testNewNestedTemporaryRootsResolveVarAndTmpAliasesBeforeSQLiteOpen() throws {
        let tmpParent = URL(fileURLWithPath: "/tmp/AskBaseRootTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpParent) }
        for input in [root.appendingPathComponent("not-yet-created/library"),
                      tmpParent.appendingPathComponent("not-yet-created/library")] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
            var store: LibraryStore? = try LibraryStore(root: input)
            let base = try store!.createKnowledgeBase(name: "新目录可写")
            let resolved = try XCTUnwrap(realpath(input.path, nil))
            let canonical = String(cString: resolved)
            free(resolved)
            XCTAssertEqual(store!.root.path, canonical)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store!.root.appendingPathComponent("library.sqlite").path))
            store = nil
            let reopened = try LibraryStore(root: input)
            XCTAssertEqual(try reopened.snapshot().knowledgeBases, [base])
        }
    }

    func testDatabaseSymlinkIsStillRejectedAfterCanonicalizingRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = temporary.appendingPathComponent("external.sqlite")
        let sentinel = Data("不得通过数据库符号链接覆盖".utf8)
        try sentinel.write(to: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("library.sqlite"),
                                                   withDestinationURL: external)
        XCTAssertThrowsError(try LibraryStore(root: root))
        XCTAssertEqual(try Data(contentsOf: external), sentinel)
    }

    func testRecordsMetadataNotesAndSettingsSurviveReopen() throws {
        var store: LibraryStore? = try LibraryStore(root: root)
        let base = try store!.createKnowledgeBase(name: " 中文研究 ")
        try store!.renameKnowledgeBase(id: base.id, name: "技术资料")
        let prepared = try addDocument(to: store!, base: base)
        let indexed = try readyChunks(prepared, store: store!)
        var document = try XCTUnwrap(store!.document(id: prepared.document.id))
        document.title = "重命名后的资料"
        document.isFavorite = true
        document.tags = ["Swift", "中文检索"]
        document.chunkCount = 999 // The database, not a stale UI value, owns this count.
        try store!.upsertDocument(document)
        let expectedDocument = try XCTUnwrap(store!.document(id: document.id))
        var note = LibraryNote(knowledgeBaseID: base.id, title: "独立笔记", body: "不自动生成索引")
        try store!.saveNote(note)
        note.body += "\n第二次编辑"
        try store!.saveNote(note)
        let conversation = try store!.createConversation(knowledgeBaseID: base.id, title: "测试会话")
        let message = ChatMessage(conversationID: conversation.id, role: "assistant",
                                  content: "中文事实 [1]", sources: [source(indexed[0], title: document.title)])
        try store!.saveMessage(message)
        let settings = AppSettings(chatModel: "offline-fixture", topK: 3)
        try store!.saveSettings(settings)
        store = nil

        let reopened = try LibraryStore(root: root)
        let snapshot = try reopened.snapshot()
        XCTAssertEqual(snapshot.knowledgeBases.map(\.name), ["技术资料"])
        XCTAssertEqual(snapshot.documents, [expectedDocument])
        XCTAssertEqual(expectedDocument.chunkCount, indexed.count)
        XCTAssertEqual(snapshot.notes, [note])
        XCTAssertEqual(snapshot.conversations, [conversation])
        XCTAssertEqual(try reopened.messages(conversationID: conversation.id), [message])
        XCTAssertEqual(try reopened.chunks(knowledgeBaseID: base.id), indexed)
        XCTAssertEqual(try reopened.settings(), settings)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(document.relativePath)),
                       Data("中文资料与 English evidence。".utf8))
    }

    func testDuplicateIdentityIsEnforcedWithinEachKnowledgeBase() throws {
        let store = try LibraryStore(root: root)
        let firstBase = try store.createKnowledgeBase(name: "甲")
        let secondBase = try store.createKnowledgeBase(name: "乙")
        let first = try addDocument(to: store, base: firstBase, text: "相同的原文")
        let duplicate = try prepared(base: firstBase, text: "相同的原文")
        XCTAssertNotEqual(first.document.id, duplicate.document.id)
        XCTAssertEqual(first.document.contentHash, duplicate.document.contentHash)
        XCTAssertEqual(try store.duplicate(contentHash: duplicate.document.contentHash,
                                            knowledgeBaseID: firstBase.id)?.id, first.document.id)
        XCTAssertNil(try store.duplicate(contentHash: first.document.contentHash, knowledgeBaseID: secondBase.id))
        XCTAssertThrowsError(try store.upsertDocument(duplicate.document))
        let separate = try addDocument(to: store, base: secondBase, text: "相同的原文")
        XCTAssertEqual(separate.document.contentHash, first.document.contentHash)
        XCTAssertEqual(try store.snapshot().documents.count, 2)
    }

    func testEmptyOrForgedReadyDocumentCannotBecomeSearchable() throws {
        let store = try LibraryStore(root: root)
        let base = try store.createKnowledgeBase(name: "状态验证")
        var prepared = try prepared(base: base)
        prepared.document.status = .ready
        XCTAssertThrowsError(try store.upsertDocument(prepared.document))
        XCTAssertNil(try store.document(id: prepared.document.id))
        prepared.document.status = .indexing
        try store.upsertDocument(prepared.document)
        XCTAssertThrowsError(try store.replaceChunks(documentID: prepared.document.id, chunks: []))
        XCTAssertEqual(try store.document(id: prepared.document.id)?.status, .indexing)
        XCTAssertTrue(try store.chunks(knowledgeBaseID: base.id).isEmpty)
    }

    func testInvalidReplacementsPreserveCommittedDocumentAndIndex() throws {
        let store = try LibraryStore(root: root)
        let base = try store.createKnowledgeBase(name: "原子性")
        let prepared = try addDocument(to: store, base: base)
        let existing = try readyChunks(prepared, store: store)
        let document = try XCTUnwrap(store.document(id: prepared.document.id))
        var candidates: [(String, DocumentChunk)] = []
        func candidate(_ label: String, change: (inout DocumentChunk) -> Void) {
            var value = existing[0]
            change(&value)
            candidates.append((label, value))
        }
        candidate("wrong dimension") { $0.dimensions = 256 }
        candidate("wrong vector count") { $0.embedding.removeLast() }
        candidate("NaN") { $0.embedding[0] = .nan }
        candidate("infinite") { $0.embedding[0] = .infinity }
        candidate("zero norm") { $0.embedding = Array(repeating: 0, count: 768) }
        candidate("unnormalized") { $0.embedding[0] = 2 }
        candidate("finite but overflowing Float similarity") { $0.embedding[0] = 1e20 }
        candidate("empty signature") { $0.encoderSignature = " \n" }
        candidate("foreign document") { $0.documentID = UUID().uuidString }
        candidate("foreign knowledge base") { $0.knowledgeBaseID = UUID().uuidString }
        candidate("empty text") { $0.text = " \n\t" }
        candidate("invalid ordinal") { $0.ordinal = -1 }
        candidate("invalid page") { $0.page = 0 }
        for (label, value) in candidates {
            XCTAssertThrowsError(try store.replaceChunks(documentID: document.id, chunks: [value]), label)
            XCTAssertEqual(try store.documentChunks(documentID: document.id), existing, label)
            XCTAssertEqual(try store.document(id: document.id), document, label)
        }
        var second = existing[0]
        second.id = UUID().uuidString
        second.ordinal = 1
        second.encoderSignature = "another-signature"
        XCTAssertThrowsError(try store.replaceChunks(documentID: document.id, chunks: [existing[0], second]))
        second.encoderSignature = existing[0].encoderSignature
        second.id = existing[0].id
        XCTAssertThrowsError(try store.replaceChunks(documentID: document.id, chunks: [existing[0], second]))
        XCTAssertEqual(try store.documentChunks(documentID: document.id), existing)
    }

    func testLateSQLiteFailureRollsBackChunksStatusAndSourceInvalidation() throws {
        let store = try LibraryStore(root: root)
        let base = try store.createKnowledgeBase(name: "事务中途失败")
        let first = try addDocument(to: store, base: base, text: "必须保留的旧资料")
        let second = try addDocument(to: store, base: base, text: "另一份资料")
        let old = try readyChunks(first, store: store)
        let other = try readyChunks(second, store: store)
        let previousDocument = try XCTUnwrap(store.document(id: first.document.id))
        let conversation = try store.createConversation(knowledgeBaseID: base.id, title: "旧引用")
        let message = ChatMessage(conversationID: conversation.id, role: "assistant",
                                  content: "原索引事实 [1]", sources: [source(old[0])])
        try store.saveMessage(message)
        var a = old[0]
        a.id = UUID().uuidString
        a.text = "本不应提交的第一块"
        var b = a
        b.id = other[0].id // Fails only after old rows are deleted and a is inserted.
        b.ordinal = 1
        XCTAssertThrowsError(try store.replaceChunks(documentID: first.document.id, chunks: [a, b]))
        XCTAssertEqual(try store.documentChunks(documentID: first.document.id), old)
        XCTAssertEqual(try store.documentChunks(documentID: second.document.id), other)
        XCTAssertEqual(try store.document(id: first.document.id), previousDocument)
        XCTAssertEqual(try store.messages(conversationID: conversation.id), [message])
        XCTAssertEqual(try count("message_sources"), 1)
    }

    func testTwoDocumentsCanUpgradeSignaturesOneAtATime() throws {
        let store = try LibraryStore(root: root)
        let base = try store.createKnowledgeBase(name: "版本一")
        let otherBase = try store.createKnowledgeBase(name: "版本二")
        let first = try addDocument(to: store, base: base, text: "资料一")
        let second = try addDocument(to: store, base: base, text: "资料二")
        _ = try readyChunks(first, store: store, signature: "encoder-a")
        _ = try readyChunks(second, store: store, signature: "encoder-a")
        _ = try readyChunks(first, store: store, signature: "encoder-b")
        XCTAssertEqual(Set(try store.chunks(knowledgeBaseID: base.id).map(\.encoderSignature)), ["encoder-a", "encoder-b"])
        // Search must reject this intermediate state in KnowledgeEngine; storage
        // must still allow metadata edits and the second document's migration.
        var metadata = try XCTUnwrap(store.document(id: second.document.id))
        metadata.isFavorite = true
        try store.upsertDocument(metadata)
        _ = try readyChunks(second, store: store, signature: "encoder-b")
        XCTAssertEqual(Set(try store.chunks(knowledgeBaseID: base.id).map(\.encoderSignature)), ["encoder-b"])
        XCTAssertTrue(try XCTUnwrap(store.document(id: second.document.id)).isFavorite)
        let separate = try addDocument(to: store, base: otherBase, text: "资料三")
        _ = try readyChunks(separate, store: store, signature: "encoder-b")
    }

    func testEngineRejectsMixedSpaceUntilBothDocumentsFinishUpgrade() async throws {
        let original = try KnowledgeEngine(root: root,
                                           embeddingClient: StorageMigrationEmbedder(signature: "space-v1"),
                                           chatClient: StorageRejectingChat())
        let initial = try await original.snapshot()
        let base = try XCTUnwrap(initial.knowledgeBases.first)
        let first = temporary.appendingPathComponent("first.txt")
        let second = temporary.appendingPathComponent("second.txt")
        try Data("第一份中文资料".utf8).write(to: first)
        try Data("第二份中文资料".utf8).write(to: second)
        let report = try await original.importDocuments(urls: [first, second], knowledgeBaseID: base.id)
        XCTAssertEqual(report.imported.count, 2, report.failures.joined(separator: "\n"))
        guard report.imported.count == 2 else { return }
        let before = try await original.search(query: "中文资料", knowledgeBaseID: base.id)
        XCTAssertEqual(before.count, 2)

        let upgraded = try KnowledgeEngine(root: root,
                                           embeddingClient: StorageMigrationEmbedder(signature: "space-v2"),
                                           chatClient: StorageRejectingChat())
        // Refuse both the entirely old space and the transient mixed space.
        for step in 0..<2 {
            do {
                _ = try await upgraded.search(query: "中文资料", knowledgeBaseID: base.id)
                XCTFail("Step \(step) must reject an index containing the old signature")
            } catch let error as AskBaseError {
                guard case .incompatibleIndex = error else { throw error }
            }
            try await upgraded.reindex(documentID: report.imported[step].id)
        }
        let after = try await upgraded.search(query: "中文资料", knowledgeBaseID: base.id)
        XCTAssertEqual(Set(after.map(\.documentID)), Set(report.imported.map(\.id)))
        let finalSnapshot = try await upgraded.snapshot()
        XCTAssertEqual(finalSnapshot.documents.filter { $0.status == .ready }.count, 2)
    }

    func testDocumentDeletionRevokesAnswerSourcesWithoutRenumberingAndCascadeIsIsolated() throws {
        let store = try LibraryStore(root: root)
        let base = try store.createKnowledgeBase(name: "将删除")
        let otherBase = try store.createKnowledgeBase(name: "保留")
        let a = try addDocument(to: store, base: base, text: "第一份")
        let b = try addDocument(to: store, base: base, text: "第二份")
        let c = try addDocument(to: store, base: otherBase, text: "保留的资料")
        let ac = try readyChunks(a, store: store)
        let bc = try readyChunks(b, store: store)
        let cc = try readyChunks(c, store: store)
        let aNote = LibraryNote(knowledgeBaseID: base.id, title: "笔记甲", body: "会删除")
        let bNote = LibraryNote(knowledgeBaseID: otherBase.id, title: "笔记乙", body: "必须保留")
        try store.saveNote(aNote)
        try store.saveNote(bNote)
        let conversation = try store.createConversation(knowledgeBaseID: base.id, title: "两个引用")
        let otherConversation = try store.createConversation(knowledgeBaseID: otherBase.id, title: "保留会话")
        try store.saveMessage(ChatMessage(conversationID: conversation.id, role: "assistant",
                                         content: "甲[1]，乙[2]。", sources: [source(ac[0]), source(bc[0])]))
        let otherMessage = ChatMessage(conversationID: otherConversation.id, role: "assistant",
                                       content: "独立事实[1]", sources: [source(cc[0])])
        try store.saveMessage(otherMessage)

        try store.deleteDocument(id: a.document.id)
        XCTAssertNil(try store.document(id: a.document.id))
        XCTAssertTrue(try store.documentChunks(documentID: a.document.id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(a.document.relativePath).path))
        let updated = try XCTUnwrap(store.messages(conversationID: conversation.id).first)
        XCTAssertTrue(updated.sources.isEmpty)
        XCTAssertTrue(updated.content.hasPrefix("甲[1]，乙[2]。"))
        XCTAssertTrue(updated.content.contains("历史回答来源已撤销"))
        XCTAssertTrue(updated.content.contains("来源已删除"))
        try store.deleteKnowledgeBase(id: base.id)
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.knowledgeBases, [otherBase])
        XCTAssertEqual(snapshot.documents.map(\.id), [c.document.id])
        XCTAssertEqual(snapshot.notes, [bNote])
        XCTAssertEqual(snapshot.conversations, [otherConversation])
        XCTAssertTrue(try store.messages(conversationID: conversation.id).isEmpty)
        XCTAssertEqual(try store.messages(conversationID: otherConversation.id), [otherMessage])
        XCTAssertEqual(try store.chunks(knowledgeBaseID: otherBase.id), cc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(b.document.relativePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(c.document.relativePath).path))
        XCTAssertEqual(try count("message_sources"), 1)
        try store.deleteKnowledgeBase(id: base.id) // Idempotent retry.
    }

    func testReindexInvalidatesChangedSourcesButRetainedIDsRemainDeletable() throws {
        let store = try LibraryStore(root: root)
        let base = try store.createKnowledgeBase(name: "重建引用")
        let prepared = try addDocument(to: store, base: base)
        let chunks = try readyChunks(prepared, store: store)
        let conversation = try store.createConversation(knowledgeBaseID: base.id, title: "引用")
        let original = ChatMessage(conversationID: conversation.id, role: "assistant",
                                   content: "答案[1]", sources: [source(chunks[0])])
        try store.saveMessage(original)
        try store.replaceChunks(documentID: prepared.document.id, chunks: chunks)
        XCTAssertEqual(try store.messages(conversationID: conversation.id), [original])
        XCTAssertEqual(try count("message_sources"), 1)
        var changed = chunks[0]
        changed.text = "同标识的新文字"
        try store.replaceChunks(documentID: prepared.document.id, chunks: [changed])
        let updated = try XCTUnwrap(store.messages(conversationID: conversation.id).first)
        XCTAssertTrue(updated.sources.isEmpty)
        XCTAssertTrue(updated.content.hasPrefix("答案[1]"))
        XCTAssertTrue(updated.content.contains("历史回答来源已撤销"))
        XCTAssertTrue(updated.content.contains("来源已更新"))
        let later = ChatMessage(conversationID: conversation.id, role: "assistant",
                                content: "新答案[1]", sources: [source(changed)])
        try store.saveMessage(later)
        try store.replaceChunks(documentID: prepared.document.id, chunks: [changed])
        try store.deleteDocument(id: prepared.document.id)
        XCTAssertTrue(try store.messages(conversationID: conversation.id).allSatisfy(\.sources.isEmpty))
    }

    func testRecoveryFailsInterruptedImportsWithoutExposingRetainedChunks() throws {
        var store: LibraryStore? = try LibraryStore(root: root)
        let base = try store!.createKnowledgeBase(name: "重启")
        let interrupted = try addDocument(to: store!, base: base, text: "中断的重建")
        let old = try readyChunks(interrupted, store: store!)
        var indexing = try XCTUnwrap(store!.document(id: interrupted.document.id))
        indexing.status = .indexing
        try store!.upsertDocument(indexing)
        let ready = try addDocument(to: store!, base: base, text: "已完成")
        let readyIndex = try readyChunks(ready, store: store!)
        let failed = try addDocument(to: store!, base: base, text: "明确失败")
        var failedDocument = failed.document
        failedDocument.status = .failed
        failedDocument.errorMessage = "保留原失败原因"
        try store!.upsertDocument(failedDocument)
        store = nil

        let reopened = try LibraryStore(root: root)
        try reopened.recoverInterruptedImports()
        let recovered = try XCTUnwrap(reopened.document(id: indexing.id))
        XCTAssertEqual(recovered.status, .failed)
        XCTAssertTrue(recovered.errorMessage?.contains("重新索引") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(recovered.relativePath).path))
        XCTAssertEqual(try reopened.documentChunks(documentID: indexing.id), old)
        XCTAssertEqual(try reopened.chunks(knowledgeBaseID: base.id), readyIndex)
        XCTAssertEqual(try reopened.document(id: failedDocument.id)?.errorMessage, "保留原失败原因")
        try reopened.recoverInterruptedImports()
        XCTAssertEqual(try reopened.document(id: indexing.id), recovered)
    }

    func testFileDeletionOutboxSurvivesFailedUnlinkAndReopen() throws {
        var store: LibraryStore? = try LibraryStore(root: root)
        let base = try store!.createKnowledgeBase(name: "清理恢复")
        let prepared = try addDocument(to: store!, base: base)
        _ = try readyChunks(prepared, store: store!)
        let path = root.appendingPathComponent(prepared.document.relativePath)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store!.deleteDocument(id: prepared.document.id))
        XCTAssertNil(try store!.document(id: prepared.document.id))
        XCTAssertTrue(try store!.documentChunks(documentID: prepared.document.id).isEmpty)
        XCTAssertEqual(try count("pending_file_deletions"), 1)
        store = nil

        try FileManager.default.removeItem(at: path)
        try Data("待清理副本".utf8).write(to: path)
        var reopened: LibraryStore? = try LibraryStore(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try count("pending_file_deletions"), 0)
        XCTAssertTrue(try reopened!.snapshot().documents.isEmpty)
        reopened = nil
        let again = try LibraryStore(root: root)
        XCTAssertTrue(try again.snapshot().documents.isEmpty)
    }

    func testForeignKeysAndSourceValidationRejectMissingOrCrossBaseRecords() throws {
        let store = try LibraryStore(root: root)
        let a = try store.createKnowledgeBase(name: "甲")
        let b = try store.createKnowledgeBase(name: "乙")
        let prepared = try addDocument(to: store, base: a)
        let chunks = try readyChunks(prepared, store: store)
        let conversation = try store.createConversation(knowledgeBaseID: b.id, title: "不允许外库引用")
        XCTAssertThrowsError(try store.saveMessage(ChatMessage(conversationID: conversation.id, role: "assistant",
                                                               content: "[1]", sources: [source(chunks[0])])))
        XCTAssertThrowsError(try store.saveNote(LibraryNote(knowledgeBaseID: "missing", title: "孤儿", body: "拒绝")))
        XCTAssertThrowsError(try store.createConversation(knowledgeBaseID: "missing", title: "孤儿"))
        var moved = try XCTUnwrap(store.document(id: prepared.document.id))
        moved.knowledgeBaseID = b.id
        XCTAssertThrowsError(try store.upsertDocument(moved))
        var unsafe = try self.prepared(base: a, text: "不可越界").document
        unsafe.relativePath = "../outside.txt"
        XCTAssertThrowsError(try store.upsertDocument(unsafe))
        XCTAssertTrue(try store.messages(conversationID: conversation.id).isEmpty)
        XCTAssertTrue(try store.snapshot().notes.isEmpty)
    }

    func testNotesAreNotIndexedAndConversationDeletionCascades() throws {
        let store = try LibraryStore(root: root)
        let base = try store.createKnowledgeBase(name: "私人笔记")
        let note = LibraryNote(knowledgeBaseID: base.id, title: "草稿", body: "这是一份没有索引的笔记")
        try store.saveNote(note)
        XCTAssertTrue(try store.snapshot().documents.isEmpty)
        XCTAssertTrue(try store.chunks(knowledgeBaseID: base.id).isEmpty)
        let conversation = try store.createConversation(knowledgeBaseID: base.id, title: "保存历史")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let user = ChatMessage(conversationID: conversation.id, role: "user", content: "先发言", createdAt: timestamp)
        let assistant = ChatMessage(conversationID: conversation.id, role: "assistant",
                                    content: "再回复", createdAt: timestamp)
        try store.saveMessage(user)
        try store.saveMessage(assistant)
        XCTAssertEqual(try store.messages(conversationID: conversation.id), [user, assistant])
        try store.deleteConversation(id: conversation.id)
        XCTAssertEqual(try count("messages"), 0)
        XCTAssertTrue(try store.snapshot().conversations.isEmpty)
        XCTAssertEqual(try store.snapshot().notes, [note])
        try store.deleteNote(id: note.id)
        XCTAssertTrue(try store.snapshot().notes.isEmpty)
    }

    func testSaveExchangeIsAtomicWhenAssistantSourcesAreInvalid() throws {
        let store = try LibraryStore(root: root)
        let base = try store.createKnowledgeBase(name: "整轮保存")
        let document = try addDocument(to: store, base: base)
        let chunks = try readyChunks(document, store: store)
        let conversation = try store.createConversation(knowledgeBaseID: base.id, title: "问答")
        let user = ChatMessage(conversationID: conversation.id, role: "user", content: "问题")
        var assistant = ChatMessage(conversationID: conversation.id, role: "assistant",
                                    content: "回答[1]", sources: [source(chunks[0])])
        assistant.sources[0].id = "missing-chunk"
        XCTAssertThrowsError(try store.saveExchange(user: user, assistant: assistant))
        XCTAssertTrue(try store.messages(conversationID: conversation.id).isEmpty)
        XCTAssertEqual(try count("message_sources"), 0)
        assistant.sources = [source(chunks[0])]
        try store.saveExchange(user: user, assistant: assistant)
        XCTAssertEqual(try store.messages(conversationID: conversation.id), [user, assistant])
        try store.saveExchange(user: user, assistant: assistant) // Idempotent retry.
        XCTAssertEqual(try store.messages(conversationID: conversation.id).count, 2)
        var foreign = assistant
        foreign.conversationID = "another-conversation"
        XCTAssertThrowsError(try store.saveExchange(user: user, assistant: foreign))
        XCTAssertEqual(try store.messages(conversationID: conversation.id), [user, assistant])
    }

    func testSaveExchangeRollsBackUserOnLateSQLiteInsertFailure() throws {
        let store = try LibraryStore(root: root)
        let base = try store.createKnowledgeBase(name: "写入故障")
        let conversation = try store.createConversation(knowledgeBaseID: base.id, title: "问答")
        let user = ChatMessage(conversationID: conversation.id, role: "user", content: "问题")
        let assistant = ChatMessage(id: "fixture-assistant", conversationID: conversation.id,
                                    role: "assistant", content: "回答")
        try rawSQL("""
            CREATE TRIGGER fail_assistant BEFORE INSERT ON messages
            WHEN NEW.id = 'fixture-assistant' BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END
            """)
        XCTAssertThrowsError(try store.saveExchange(user: user, assistant: assistant))
        XCTAssertTrue(try store.messages(conversationID: conversation.id).isEmpty)
        try rawSQL("DROP TRIGGER fail_assistant")
        try store.saveExchange(user: user, assistant: assistant)
        XCTAssertEqual(try store.messages(conversationID: conversation.id), [user, assistant])
    }

    func testDeletingManagedSymlinkDoesNotDeleteItsTarget() throws {
        let store = try LibraryStore(root: root)
        let base = try store.createKnowledgeBase(name: "安全删除")
        let document = try addDocument(to: store, base: base).document
        let target = temporary.appendingPathComponent("outside.txt")
        try Data("外部文件必须保留".utf8).write(to: target)
        let managed = root.appendingPathComponent(document.relativePath)
        try FileManager.default.removeItem(at: managed)
        try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: target)
        try store.deleteDocument(id: document.id)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "外部文件必须保留")
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.path))
    }

    func testFutureDatabaseVersionIsRejectedWithoutModifyingRecords() throws {
        var store: LibraryStore? = try LibraryStore(root: root)
        let base = try store!.createKnowledgeBase(name: "未来版本")
        store = nil
        try rawSQL("PRAGMA user_version = 99")
        XCTAssertThrowsError(try LibraryStore(root: root))
        XCTAssertEqual(try count("knowledge_bases"), 1)
        try rawSQL("PRAGMA user_version = 1")
        XCTAssertEqual(try LibraryStore(root: root).snapshot().knowledgeBases, [base])
    }

    func testConcurrentCallsKeepCompleteTransactions() throws {
        let store = try LibraryStore(root: root)
        let failures = StorageTestResults()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do {
                let base = try store.createKnowledgeBase(name: "并发\(index)")
                try store.saveNote(LibraryNote(knowledgeBaseID: base.id, title: "笔记", body: "\(index)"))
                _ = try store.snapshot()
            } catch { failures.record(error: error) }
        }
        XCTAssertTrue(failures.errors.isEmpty, failures.errors.joined(separator: "\n"))
        XCTAssertEqual(try store.snapshot().knowledgeBases.count, 24)
        XCTAssertEqual(try store.snapshot().notes.count, 24)
    }

    func testSeparateConnectionsSerializeWholeDocumentReplacements() throws {
        let first = try LibraryStore(root: root)
        let second = try LibraryStore(root: root)
        let base = try first.createKnowledgeBase(name: "跨连接事务")
        let a = try addDocument(to: first, base: base, text: "甲")
        let b = try addDocument(to: first, base: base, text: "乙")
        let ac = embedded(a.chunks, signature: "signature-a")
        let bc = embedded(b.chunks, signature: "signature-a")
        let results = StorageTestResults()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                if index == 0 { try first.replaceChunks(documentID: a.document.id, chunks: ac) }
                else { try second.replaceChunks(documentID: b.document.id, chunks: bc) }
                results.recordSuccess()
            } catch { results.record(error: error) }
        }
        XCTAssertEqual(results.successes, 2)
        XCTAssertEqual(results.errors.count, 0)
        XCTAssertEqual(Set(try first.chunks(knowledgeBaseID: base.id).map(\.encoderSignature)).count, 1)
        XCTAssertEqual(try first.snapshot().documents.filter { $0.status == .ready }.count, 2)
    }

    // All fixtures are local temporary files and synthetic unit vectors/providers.
    // These tests never contact either model endpoint.
    private func prepared(base: KnowledgeBase, text: String = "中文资料与 English evidence。") throws -> PreparedDocument {
        let input = temporary.appendingPathComponent("\(UUID()).txt")
        try Data(text.utf8).write(to: input)
        return try DocumentImporter.prepare(url: input, knowledgeBaseID: base.id,
                                             originalsRoot: root.appendingPathComponent("Originals"))
    }

    private func addDocument(to store: LibraryStore, base: KnowledgeBase,
                             text: String = "中文资料与 English evidence。") throws -> PreparedDocument {
        let value = try prepared(base: base, text: text)
        try store.upsertDocument(value.document)
        return value
    }

    private func embedded(_ chunks: [DocumentChunk], signature: String = "fixture-eg2-768-v1") -> [DocumentChunk] {
        chunks.map {
            var value = $0
            value.embedding = Array(repeating: 0, count: 768)
            value.embedding[value.ordinal % 768] = 1
            value.encoderSignature = signature
            return value
        }
    }

    private func readyChunks(_ prepared: PreparedDocument, store: LibraryStore,
                             signature: String = "fixture-eg2-768-v1") throws -> [DocumentChunk] {
        let chunks = embedded(prepared.chunks, signature: signature)
        try store.replaceChunks(documentID: prepared.document.id, chunks: chunks)
        return chunks
    }

    private func source(_ chunk: DocumentChunk, title: String = "资料") -> SearchResult {
        SearchResult(id: chunk.id, documentID: chunk.documentID, knowledgeBaseID: chunk.knowledgeBaseID,
                     title: title, text: chunk.text, page: chunk.page, score: 0.8)
    }

    private func rawSQL(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("library.sqlite").path, &database,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw AskBaseError.storage("测试数据库无法打开")
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AskBaseError.storage(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func count(_ table: String) throws -> Int {
        // Table names below are test-owned constants, never user input.
        var database: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("library.sqlite").path, &database,
                             SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw AskBaseError.storage("测试数据库无法打开")
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else {
            throw AskBaseError.storage("测试查询失败")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw AskBaseError.storage("测试计数失败") }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private struct StorageMigrationEmbedder: EmbeddingProviding {
    let signature: String
    func health() async throws -> EmbeddingHealth { EmbeddingHealth(encoderSignature: signature) }
    func embed(_ texts: [String], inputType: String) async throws -> EmbeddingBatch {
        var vector = Array(repeating: Float(0), count: 768)
        vector[0] = 1
        return EmbeddingBatch(vectors: texts.map { _ in vector }, signature: signature)
    }
}

private struct StorageRejectingChat: ChatProviding {
    func models() async throws -> [String] {
        throw AskBaseError.invalidInput("此离线测试禁止调用问答服务。")
    }
    func answer(model: String, question: String, sources: [SearchResult], history: [ChatMessage]) async throws -> String {
        throw AskBaseError.invalidInput("此离线测试禁止调用问答服务。")
    }
}

private final class StorageTestResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var errors: [String] = []
    private(set) var successes = 0
    func record(error: Error) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(error.localizedDescription)
    }
    func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }
        successes += 1
    }
}
