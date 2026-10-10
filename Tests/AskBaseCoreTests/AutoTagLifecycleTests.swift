import Foundation
import XCTest
@testable import AskBaseCore

/// Independent lifecycle checks. All libraries, files and model responses are
/// synthetic; the positive control proves the race fixtures would otherwise tag.
final class AutoTagLifecycleTests: XCTestCase {
    private var directory: URL!
    private var chats: [AutoTagForbiddenChat] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskBase-AutoTagLifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        AutoTagHTTPProtocol.reset()
    }

    override func tearDownWithError() throws {
        for chat in chats {
            XCTAssertEqual(chat.callCount, 0, "Auto-tagging must not even list chat models")
        }
        chats = []
        try FileManager.default.removeItem(at: directory)
    }

    func testLegacySettingsDecodeEnablesAutoTagWithoutLosingExistingSettings() throws {
        let legacy = Data("""
            {"embeddingBaseURL":"http://localhost:8872","ollamaBaseURL":"http://localhost:11435",
             "chatModel":"existing-local-model","topK":9}
            """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertTrue(AppSettings().autoTagOnImport)
        XCTAssertTrue(decoded.autoTagOnImport)
        XCTAssertEqual(decoded.embeddingBaseURL, "http://localhost:8872")
        XCTAssertEqual(decoded.ollamaBaseURL, "http://localhost:11435")
        XCTAssertEqual(decoded.chatModel, "existing-local-model")
        XCTAssertEqual(decoded.topK, 9)
        var disabled = decoded
        disabled.autoTagOnImport = false
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(disabled)), disabled)
        XCTAssertTrue(ImportReport().taggingWarnings.isEmpty)
    }

    func testDisabledImportPersistsSettingAndMakesNoCandidateRequests() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        try await setAutomaticImport(false, engine: engine)
        let document = try await importOne(engine)
        let calls = await encoder.calls()
        XCTAssertEqual(calls.queries.count, 0)
        XCTAssertFalse(calls.documents.isEmpty)
        XCTAssertTrue(document.tags.isEmpty)
        XCTAssertEqual(document.status, .ready)
        let reopened = try makeEngine(encoder, root: engine.root)
        let settings = try await reopened.settings()
        XCTAssertFalse(settings.autoTagOnImport)
    }

    func testDefaultImportAppliesTagsAfterIndexCommitUsingBoundedQueryBatches() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        await encoder.pauseNext(.query)
        let base = try await engine.snapshot().knowledgeBases[0]
        let source = try fixture()
        let task = Task { try await engine.importDocuments(urls: [source], knowledgeBaseID: base.id) }
        do {
            try await waitForPause(encoder)
            let snapshot = try await engine.snapshot()
            let ready = try XCTUnwrap(snapshot.documents.first)
            XCTAssertEqual(ready.status, .ready, "Candidate requests begin only after committing the index")
            XCTAssertTrue(ready.tags.isEmpty)
            let before = try await engine.documentChunks(documentID: ready.id)
            XCTAssertFalse(before.isEmpty)
            await encoder.resume()
            let report = try await task.value
            XCTAssertTrue(report.failures.isEmpty)
            XCTAssertTrue(report.taggingWarnings.isEmpty)
            let tagged = try XCTUnwrap(report.imported.first)
            XCTAssertFalse(tagged.tags.isEmpty, "Positive control must produce a reliable synthetic match")
            try await assertSaved(ready.id, in: engine, equals: tagged)
            let after = try await engine.documentChunks(documentID: ready.id)
            XCTAssertEqual(after, before, "Tagging may not alter IDs, text, vectors or provenance")
            let calls = await encoder.calls()
            XCTAssertFalse(calls.queries.isEmpty)
            XCTAssertTrue(calls.queries.allSatisfy { (1...8).contains($0.count) })
            XCTAssertEqual(calls.documents.flatMap { $0 }, before.map(\.text))
        } catch {
            task.cancel()
            await encoder.resume()
            _ = await task.result
            throw error
        }
    }

    func testTagServiceFailureIsAWarningAndIndexRemainsSearchable() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        await encoder.setQueryFault(.unavailable)
        let base = try await engine.snapshot().knowledgeBases[0]
        let source = try fixture()
        let report = try await engine.importDocuments(urls: [source], knowledgeBaseID: base.id)
        let document = try XCTUnwrap(report.imported.first)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.taggingWarnings.count, 1)
        XCTAssertTrue(report.taggingWarnings[0].contains(source.lastPathComponent))
        XCTAssertEqual(document.status, .ready)
        XCTAssertNil(document.errorMessage)
        XCTAssertTrue(document.tags.isEmpty)
        let chunks = try await engine.documentChunks(documentID: document.id)
        XCTAssertFalse(chunks.isEmpty)
        await encoder.setQueryFault(.none)
        let results = try await engine.search(query: "Kubernetes: fixture", knowledgeBaseID: base.id)
        XCTAssertEqual(results.first?.documentID, document.id)
        let after = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(after, chunks)
    }

    func testExistingManualTagsSkipHealthAndAllEmbeddingCalls() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        var document = try await importUntagged(engine)
        document.tags = ["手动保留"]
        try await engine.updateDocument(document)
        let before = try await saved(document.id, in: engine)
        let calls = await encoder.calls()
        let result = try await engine.autoTag(documentID: document.id)
        XCTAssertTrue(result.isEmpty)
        try await assertSaved(document.id, in: engine, equals: before)
        let after = await encoder.calls()
        XCTAssertEqual(after, calls, "A manually tagged document needs no model request, including health")
    }

    func testSuccessfulRetryDoesNotOverwriteOrReencodeAnAlreadyTaggedDocument() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await importUntagged(engine)
        let chunks = try await engine.documentChunks(documentID: document.id)
        await encoder.setQueryFault(.unavailable)
        await assertThrows { _ = try await engine.autoTag(documentID: document.id) }
        await encoder.setQueryFault(.none)
        let first = try await engine.autoTag(documentID: document.id)
        XCTAssertFalse(first.isEmpty, "A failed attempt must release the per-document guard")
        let tagged = try await saved(document.id, in: engine)
        XCTAssertEqual(tagged.tags, first)
        let calls = await encoder.calls()
        let second = try await engine.autoTag(documentID: document.id)
        XCTAssertTrue(second.isEmpty)
        try await assertSaved(document.id, in: engine, equals: tagged)
        let afterCalls = await encoder.calls()
        XCTAssertEqual(afterCalls, calls)
        let afterChunks = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(afterChunks, chunks)
    }

    func testNoReliableSemanticMatchLeavesDocumentAndChunksUnchanged() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        await encoder.setDocumentAxis(2)
        let document = try await importUntagged(engine)
        let chunks = try await engine.documentChunks(documentID: document.id)
        let tags = try await engine.autoTag(documentID: document.id)
        XCTAssertTrue(tags.isEmpty)
        try await assertSaved(document.id, in: engine, equals: document)
        let after = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(after, chunks)
        let calls = await encoder.calls()
        XCTAssertFalse(calls.queries.isEmpty, "Abstention must exercise candidate matching")
    }

    func testUniformCandidatesAbstainEvenWithLexicalEvidence() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await importUntagged(engine)
        await encoder.setQueryFault(.uniform)
        let tags = try await engine.autoTag(documentID: document.id)
        XCTAssertTrue(tags.isEmpty)
        try await assertSaved(document.id, in: engine, equals: document)
    }

    func testInvalidCandidateBatchesCannotWriteTagsOrDamageChunks() async throws {
        for fault in [AutoTagTestEmbedder.QueryFault.shortVector, .zeroVector, .nonFinite,
                      .notNormalized, .missingVector, .signature] {
            let encoder = AutoTagTestEmbedder()
            let engine = try makeEngine(encoder)
            let document = try await importUntagged(engine)
            let chunks = try await engine.documentChunks(documentID: document.id)
            await encoder.setQueryFault(fault)
            await assertThrows { _ = try await engine.autoTag(documentID: document.id) }
            try await assertSaved(document.id, in: engine, equals: document)
            let after = try await engine.documentChunks(documentID: document.id)
            XCTAssertEqual(after, chunks, "\(fault)")
        }
    }

    func testHealthSignatureChangeRejectsBeforeSendingCandidates() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await importUntagged(engine)
        await encoder.setSignature("auto-tag-space-v2")
        await assertThrows { _ = try await engine.autoTag(documentID: document.id) }
        let calls = await encoder.calls()
        XCTAssertTrue(calls.queries.isEmpty)
        try await assertSaved(document.id, in: engine, equals: document)
    }

    func testSignatureChangeDuringCandidateResponseRejectsAndAllowsCleanRetry() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await importUntagged(engine)
        let chunks = try await engine.documentChunks(documentID: document.id)
        let result = try await whilePaused(engine, encoder, document.id) {
            await encoder.setSignature("auto-tag-space-v2")
        }
        if case .success = result { XCTFail("A changed response signature must be rejected") }
        try await assertSaved(document.id, in: engine, equals: document)
        let after = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(after, chunks)
        await encoder.setSignature(AutoTagTestEmbedder.originalSignature)
        let retry = try await engine.autoTag(documentID: document.id)
        XCTAssertFalse(retry.isEmpty, "Rejected vectors must not poison the candidate cache")
    }

    func testManualTagsWrittenDuringCandidateRequestArePreserved() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await importUntagged(engine)
        var edited: LibraryDocument?
        let result = try await whilePaused(engine, encoder, document.id) {
            var current = try await self.saved(document.id, in: engine)
            current.tags = ["用户标签"]
            try await engine.updateDocument(current)
            edited = try await self.saved(document.id, in: engine)
        }
        assertNoTagsReturned(result)
        try await assertSaved(document.id, in: engine, equals: edited)
        let calls = await encoder.calls()
        XCTAssertEqual(calls.queries.count, 1, "Stop further candidate work after a user edit")
    }

    func testClearingTagsDuringLastCandidateResponseInvalidatesTheOldAttempt() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await prepareLastCandidateRace(engine)
        let chunks = try await engine.documentChunks(documentID: document.id)
        var cleared: LibraryDocument?
        let result = try await whilePaused(engine, encoder, document.id) {
            var current = try await self.saved(document.id, in: engine)
            current.tags = ["暂存手动标签"]
            try await engine.updateDocument(current)
            current = try await self.saved(document.id, in: engine)
            current.tags = []
            try await engine.updateDocument(current)
            cleared = try await self.saved(document.id, in: engine)
        }
        assertNoTagsReturned(result)
        XCTAssertNotEqual(cleared?.updatedAt, document.updatedAt)
        try await assertSaved(document.id, in: engine, equals: cleared)
        let after = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(after, chunks)
        let calls = await encoder.calls()
        XCTAssertEqual(calls.queries.last?.count, 1, "Exercise final CAS, not the next-batch guard")
    }

    func testOtherEngineTitleEditDuringLastCandidateResponseWinsCAS() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await prepareLastCandidateRace(engine)
        let other = try makeEngine(encoder, root: engine.root)
        var edited: LibraryDocument?
        let result = try await whilePaused(engine, encoder, document.id) {
            var current = try await self.saved(document.id, in: other)
            current.title = "来自另一连接的新标题"
            try await other.updateDocument(current)
            edited = try await self.saved(document.id, in: other)
        }
        assertNoTagsReturned(result)
        try await assertSaved(document.id, in: engine, equals: edited)
    }

    func testOtherEngineDeletionDuringLastCandidateResponseCannotResurrectAnything() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await prepareLastCandidateRace(engine)
        let other = try makeEngine(encoder, root: engine.root)
        let original = try await engine.originalURL(documentID: document.id)
        let result = try await whilePaused(engine, encoder, document.id) {
            try await other.deleteDocument(id: document.id)
        }
        assertNoTagsReturned(result)
        let snapshot = try await engine.snapshot()
        XCTAssertFalse(snapshot.documents.contains { $0.id == document.id })
        let chunks = try await engine.documentChunks(documentID: document.id)
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    func testOtherEngineCompletedReindexDuringLastCandidateResponseInvalidatesOldVectors() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await prepareLastCandidateRace(engine)
        let other = try makeEngine(encoder, root: engine.root)
        let originalChunks = try await engine.documentChunks(documentID: document.id)
        var reindexed: LibraryDocument?
        var replacement: [DocumentChunk] = []
        let result = try await whilePaused(engine, encoder, document.id) {
            await encoder.setDocumentAxis(2)
            try await other.reindex(documentID: document.id)
            reindexed = try await self.saved(document.id, in: other)
            replacement = try await other.documentChunks(documentID: document.id)
        }
        assertNoTagsReturned(result)
        XCTAssertNotEqual(replacement, originalChunks, "The reindex must actually commit a new vector set")
        try await assertSaved(document.id, in: engine, equals: reindexed)
        let after = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(after, replacement)
    }

    func testCachedCandidatesStillRespectAnEditDuringHealthAwait() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let warm = try await importUntagged(engine)
        let positive = try await engine.autoTag(documentID: warm.id)
        XCTAssertFalse(positive.isEmpty)
        let target = try await importOne(engine)
        let before = await encoder.calls()
        var edited: LibraryDocument?
        let result = try await whilePaused(engine, encoder, target.id, point: .health) {
            var current = try await self.saved(target.id, in: engine)
            current.title = "缓存命中期间用户改名"
            try await engine.updateDocument(current)
            edited = try await self.saved(target.id, in: engine)
        }
        assertNoTagsReturned(result)
        try await assertSaved(target.id, in: engine, equals: edited)
        let after = await encoder.calls()
        XCTAssertEqual(after.queries, before.queries, "This fixture must take the cached-vector path")
    }

    func testCancelledAutoTagCannotWriteAndCanBeRetried() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await prepareLastCandidateRace(engine)
        let chunks = try await engine.documentChunks(documentID: document.id)
        let result = try await whilePaused(engine, encoder, document.id, cancel: true) {}
        assertCancellation(result)
        try await assertSaved(document.id, in: engine, equals: document)
        let after = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(after, chunks)
        let retry = try await engine.autoTag(documentID: document.id)
        XCTAssertFalse(retry.isEmpty, "Cancellation must release the per-document guard")
    }

    func testCancellationDuringImportTaggingKeepsAlreadyCommittedReadyIndex() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let base = try await engine.snapshot().knowledgeBases[0]
        let source = try fixture()
        await encoder.pauseNext(.query)
        let task = Task { try await engine.importDocuments(urls: [source], knowledgeBaseID: base.id) }
        do {
            try await waitForPause(encoder)
            let snapshot = try await engine.snapshot()
            let document = try XCTUnwrap(snapshot.documents.first)
            let chunks = try await engine.documentChunks(documentID: document.id)
            XCTAssertEqual(document.status, .ready)
            XCTAssertFalse(chunks.isEmpty)
            task.cancel()
            await encoder.resume()
            assertCancellation(await task.result)
            try await assertSaved(document.id, in: engine, equals: document)
            let after = try await engine.documentChunks(documentID: document.id)
            XCTAssertEqual(after, chunks)
            let tags = try await engine.autoTag(documentID: document.id)
            XCTAssertFalse(tags.isEmpty)
        } catch {
            task.cancel()
            await encoder.resume()
            _ = await task.result
            throw error
        }
    }

    func testSameDocumentReentryMakesNoExtraRequests() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await importUntagged(engine)
        let result = try await whilePaused(engine, encoder, document.id) {
            let before = await encoder.calls()
            let second = try await engine.autoTag(documentID: document.id)
            XCTAssertTrue(second.isEmpty)
            let after = await encoder.calls()
            XCTAssertEqual(after, before)
        }
        let tags = try result.get()
        XCTAssertFalse(tags.isEmpty)
        let stored = try await saved(document.id, in: engine)
        XCTAssertEqual(stored.tags, tags)
    }

    func testNotReadyDocumentsAreRejectedWithoutModelRequests() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let base = try await engine.snapshot().knowledgeBases[0]
        let store = try LibraryStore(root: engine.root)
        for status in [DocumentStatus.indexing, .failed] {
            let document = LibraryDocument(
                knowledgeBaseID: base.id, title: "Unready", fileName: "unready.txt",
                relativePath: "Originals/\(UUID()).txt", contentHash: UUID().uuidString, status: status
            )
            try store.upsertDocument(document)
            await assertThrows { _ = try await engine.autoTag(documentID: document.id) }
            try await assertSaved(document.id, in: engine, equals: document)
        }
        let calls = await encoder.calls()
        XCTAssertEqual(calls, AutoTagTestEmbedder.Calls())
    }

    func testCandidateCacheReusesSameEndpointButSeparatesChangedEndpoint() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let first = try await importUntagged(engine)
        try await assertMatches(first.id, in: engine)
        let warmCalls = await encoder.calls()
        let second = try await importOne(engine)
        try await assertMatches(second.id, in: engine)
        let reused = await encoder.calls()
        XCTAssertEqual(reused.queries, warmCalls.queries)
        var settings = try await engine.settings()
        settings.embeddingBaseURL = "http://127.0.0.1:18871"
        try await engine.saveSettings(settings)
        let third = try await importOne(engine)
        try await assertMatches(third.id, in: engine)
        let changed = await encoder.calls()
        XCTAssertGreaterThan(changed.queries.count, reused.queries.count)
    }

    func testCandidateCacheSeparatesEncoderSignaturesAndNewCandidatePrompts() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        var first = try await importUntagged(engine)
        try await assertMatches(first.id, in: engine)
        let warm = await encoder.calls()
        first = try await saved(first.id, in: engine)
        first.tags = ["回归专用新主题"]
        try await engine.updateDocument(first)
        let second = try await importOne(engine)
        try await assertMatches(second.id, in: engine)
        let extended = await encoder.calls()
        let newPrompts = extended.queries.dropFirst(warm.queries.count).flatMap { $0 }
        XCTAssertEqual(newPrompts.count, 1, "Only the newly introduced candidate should miss cache")
        XCTAssertTrue(try XCTUnwrap(newPrompts.first).contains("回归专用新主题"))
        await encoder.setSignature("auto-tag-space-v2")
        let third = try await importOne(engine)
        try await assertMatches(third.id, in: engine)
        let changed = await encoder.calls()
        XCTAssertGreaterThan(changed.queries.count - extended.queries.count, 1)
    }

    func testSameBaseReusesExistingLabelButCachedLabelCannotLeakAcrossBases() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let customLabel = "离线回归私有主题"
        await encoder.setAdditionalMatch(customLabel)
        var seed = try await importUntagged(engine)
        seed.tags = [customLabel]
        try await engine.updateDocument(seed)
        let target = try await importOne(engine, text: "\(customLabel)：Kubernetes fixture.")
        let sameBaseTags = try await engine.autoTag(documentID: target.id)
        XCTAssertTrue(sameBaseTags.contains(customLabel), "The synthetic custom candidate has an exact vector match")
        let sameBase = try await saved(target.id, in: engine)
        XCTAssertEqual(sameBase.tags, sameBaseTags)
        let warmed = await encoder.calls()
        XCTAssertTrue(warmed.queries.flatMap { $0 }.contains { $0.contains(customLabel) })

        let otherBase = try await engine.createKnowledgeBase(name: "隔离知识库")
        let report = try await engine.importDocuments(
            urls: [fixture(text: "\(customLabel)：Kubernetes fixture.")], knowledgeBaseID: otherBase.id
        )
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.taggingWarnings.isEmpty)
        let other = try XCTUnwrap(report.imported.first)
        let otherTags = try await engine.autoTag(documentID: other.id)
        XCTAssertFalse(otherTags.isEmpty, "The other base still has a positive catalog candidate")
        XCTAssertFalse(otherTags.contains(customLabel), "Cached vectors must not expand another base's candidate vocabulary")
        let storedOther = try await saved(other.id, in: engine)
        XCTAssertEqual(storedOther.tags, otherTags)
        let after = await encoder.calls()
        XCTAssertEqual(after.queries, warmed.queries, "Exercise the already warm cache across knowledge bases")
    }

    func testSignatureChangeAfterWarmingCacheStillRejectsOldDocumentWithoutQueries() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let first = try await importUntagged(engine)
        try await assertMatches(first.id, in: engine)
        let target = try await importOne(engine)
        let before = await encoder.calls()
        await encoder.setSignature("auto-tag-space-v2")
        await assertThrows { _ = try await engine.autoTag(documentID: target.id) }
        try await assertSaved(target.id, in: engine, equals: target)
        let rejected = await encoder.calls()
        XCTAssertEqual(rejected.queries, before.queries)

        // Once deliberately reindexed, the new signature needs its own query
        // vectors; a previously warm cache may not hide that work.
        try await engine.reindex(documentID: target.id)
        let reindexed = try await engine.documentChunks(documentID: target.id)
        XCTAssertTrue(reindexed.allSatisfy { $0.encoderSignature == "auto-tag-space-v2" })
        try await assertMatches(target.id, in: engine)
        let refreshed = await encoder.calls()
        XCTAssertGreaterThan(refreshed.queries.count, rejected.queries.count)
        let after = try await engine.documentChunks(documentID: target.id)
        XCTAssertEqual(after, reindexed)
    }

    func testAutoTagDuringAnActiveReindexRejectsWithoutModelWork() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await importUntagged(engine)
        await encoder.pauseNext(.document)
        let task = Task { try await engine.reindex(documentID: document.id) }
        do {
            try await waitForPause(encoder)
            let before = await encoder.calls()
            await assertThrows { _ = try await engine.autoTag(documentID: document.id) }
            let after = await encoder.calls()
            XCTAssertEqual(after, before)
            try await assertSaved(document.id, in: engine, equals: document)
            await encoder.resume()
            try await task.value
            try await assertMatches(document.id, in: engine)
        } catch {
            task.cancel()
            await encoder.resume()
            _ = await task.result
            throw error
        }
    }

    func testReindexStartedDuringLastCandidateResponsePreventsTagCommitUntilRetry() async throws {
        let encoder = AutoTagTestEmbedder()
        let engine = try makeEngine(encoder)
        let document = try await prepareLastCandidateRace(engine)
        let chunks = try await engine.documentChunks(documentID: document.id)
        await encoder.pauseNext(.query)
        let tagging = Task { try await engine.autoTag(documentID: document.id) }
        var reindexing: Task<Void, Error>?
        do {
            try await waitForPause(encoder, at: .query)
            await encoder.pauseNext(.document)
            let reindex = Task { try await engine.reindex(documentID: document.id) }
            reindexing = reindex
            try await waitForPause(encoder, at: .document)
            // Return the final candidate while reindexing still has not
            // committed. updatedAt is unchanged, so the in-flight guard matters.
            await encoder.resume(.query)
            assertNoTagsReturned(await tagging.result)
            try await assertSaved(document.id, in: engine, equals: document)
            let whileIndexing = try await engine.documentChunks(documentID: document.id)
            XCTAssertEqual(whileIndexing, chunks)
            await encoder.resume(.document)
            try await reindex.value
            try await assertMatches(document.id, in: engine)
        } catch {
            tagging.cancel()
            reindexing?.cancel()
            await encoder.resume()
            _ = await tagging.result
            if let reindexing { _ = await reindexing.result }
            throw error
        }
    }

    func testHTTPClientsUseOnlyHealthAndEmbeddingsEvenWithoutReliableMatch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutoTagHTTPProtocol.self]
        let http = LocalHTTPClient(configuration: configuration)
        let engine = try KnowledgeEngine(
            root: directory.appendingPathComponent("http-library"),
            embeddingClient: EmbeddingClient(http: http), chatClient: OllamaClient(http: http)
        )
        var settings = try await engine.settings()
        settings.chatModel = "must-not-be-called"
        try await engine.saveSettings(settings)
        let tagged = try await importOne(engine)
        XCTAssertFalse(tagged.tags.isEmpty)
        let unrelated = try await importOne(engine, text: "UNRELATED_OFFLINE_FIXTURE")
        XCTAssertTrue(unrelated.tags.isEmpty)
        let requests = AutoTagHTTPProtocol.recordedRequests()
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { ["/health", "/v1/embeddings"].contains($0.url?.path ?? "") })
        XCTAssertFalse(requests.contains { $0.url?.path.hasPrefix("/api/") == true })
    }

    // MARK: - Fixtures and deterministic suspension points

    private func makeEngine(_ encoder: AutoTagTestEmbedder, root: URL? = nil) throws -> KnowledgeEngine {
        let chat = AutoTagForbiddenChat()
        chats.append(chat)
        return try KnowledgeEngine(root: root ?? directory.appendingPathComponent("library-\(UUID())"),
                                   embeddingClient: encoder, chatClient: chat)
    }

    private func fixture(text: String = "Kubernetes: pods and deployments, offline regression.") throws -> URL {
        let source = directory.appendingPathComponent("fixture-\(UUID()).txt")
        try (text + "\nFixture ID: \(UUID())").write(to: source, atomically: true, encoding: .utf8)
        return source
    }

    private func setAutomaticImport(_ value: Bool, engine: KnowledgeEngine) async throws {
        var settings = try await engine.settings()
        settings.autoTagOnImport = value
        try await engine.saveSettings(settings)
    }

    private func importOne(_ engine: KnowledgeEngine, text: String = "Kubernetes: offline fixture.") async throws -> LibraryDocument {
        let base = try await engine.snapshot().knowledgeBases[0]
        let report = try await engine.importDocuments(urls: [fixture(text: text)], knowledgeBaseID: base.id)
        XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: "\n"))
        XCTAssertTrue(report.taggingWarnings.isEmpty, report.taggingWarnings.joined(separator: "\n"))
        return try XCTUnwrap(report.imported.first)
    }

    private func importUntagged(_ engine: KnowledgeEngine) async throws -> LibraryDocument {
        try await setAutomaticImport(false, engine: engine)
        return try await importOne(engine)
    }

    private func saved(_ id: String, in engine: KnowledgeEngine) async throws -> LibraryDocument {
        let snapshot = try await engine.snapshot()
        return try XCTUnwrap(snapshot.documents.first { $0.id == id })
    }

    /// Warm all ordinary prompts, then introduce one new prompt. The paused
    /// response is therefore the *last* batch, bypassing next-iteration guards.
    private func prepareLastCandidateRace(_ engine: KnowledgeEngine) async throws -> LibraryDocument {
        var seed = try await importUntagged(engine)
        let positive = try await engine.autoTag(documentID: seed.id)
        XCTAssertFalse(positive.isEmpty, "Positive control for all final-response races")
        seed = try await saved(seed.id, in: engine)
        seed.tags = ["最后批次回归主题"]
        try await engine.updateDocument(seed)
        return try await importOne(engine)
    }

    private func waitForPause(_ encoder: AutoTagTestEmbedder, at point: AutoTagTestEmbedder.PausePoint? = nil) async throws {
        for _ in 0..<400 {
            if await encoder.isPaused(at: point) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AskBaseError.invalidInput("Timed out waiting for the synthetic auto-tag suspension")
    }

    private func whilePaused(
        _ engine: KnowledgeEngine, _ encoder: AutoTagTestEmbedder, _ documentID: String,
        point: AutoTagTestEmbedder.PausePoint = .query, cancel: Bool = false,
        mutation: () async throws -> Void
    ) async throws -> Result<[String], Error> {
        await encoder.pauseNext(point)
        let task = Task { try await engine.autoTag(documentID: documentID) }
        do {
            try await waitForPause(encoder)
            try await mutation()
            if cancel { task.cancel() }
            await encoder.resume()
            return await task.result
        } catch {
            task.cancel()
            await encoder.resume()
            _ = await task.result
            throw error
        }
    }

    private func assertSaved(
        _ id: String, in engine: KnowledgeEngine, equals expected: LibraryDocument?,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let actual = try await saved(id, in: engine)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertMatches(
        _ id: String, in engine: KnowledgeEngine, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let tags = try await engine.autoTag(documentID: id)
        XCTAssertFalse(tags.isEmpty, "Synthetic positive control must match", file: file, line: line)
    }

    private func assertThrows(
        file: StaticString = #filePath, line: UInt = #line, _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected rejection", file: file, line: line)
        } catch {}
    }

    private func assertNoTagsReturned(
        _ result: Result<[String], Error>, file: StaticString = #filePath, line: UInt = #line
    ) {
        // Missing/stale targets may be rejected or explicitly skipped; neither
        // path may report successful tags or mutate the committed state.
        if case .success(let tags) = result { XCTAssertTrue(tags.isEmpty, file: file, line: line) }
    }

    private func assertCancellation<T>(
        _ result: Result<T, Error>, file: StaticString = #filePath, line: UInt = #line
    ) {
        switch result {
        case .success: XCTFail("Cancellation must propagate", file: file, line: line)
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }
}

private actor AutoTagTestEmbedder: EmbeddingProviding {
    static let originalSignature = "auto-tag-space-v1"
    enum PausePoint: Hashable { case health, query, document }
    enum QueryFault { case none, unavailable, uniform, shortVector, zeroVector, nonFinite, notNormalized, missingVector, signature }
    struct Calls: Equatable {
        var health = 0
        var queries: [[String]] = []
        var documents: [[String]] = []
    }
    private var recorded = Calls()
    private var signature = originalSignature
    private var documentAxis = 0
    private var additionalMatch: String?
    private var queryFault = QueryFault.none
    private var pause: PausePoint?
    private var pending: [PausePoint: CheckedContinuation<Void, Never>] = [:]

    static func vector(_ axis: Int) -> [Float] {
        var vector = Array(repeating: Float(0), count: 768)
        vector[axis] = 1
        return vector
    }

    func health() async throws -> EmbeddingHealth {
        recorded.health += 1
        await suspendIfArmed(.health)
        return EmbeddingHealth(encoderSignature: signature)
    }

    func embed(_ texts: [String], inputType: String) async throws -> EmbeddingBatch {
        guard (1...8).contains(texts.count) else {
            throw AskBaseError.invalidInput("Candidate and document batches must contain 1–8 inputs")
        }
        if inputType == "document" {
            recorded.documents.append(texts)
            await suspendIfArmed(.document)
            return EmbeddingBatch(vectors: texts.map { _ in Self.vector(documentAxis) }, signature: signature)
        }
        guard inputType == "query" else { throw AskBaseError.invalidInput("Unexpected embedding input type") }
        recorded.queries.append(texts)
        // Deliberately ignore task cancellation here: the engine must check it
        // after an otherwise valid late service response.
        await suspendIfArmed(.query)
        if queryFault == .unavailable { throw AskBaseError.modelUnavailable("Synthetic candidate service failure") }
        var vectors = texts.map { text in
            Self.vector(text.contains("Kubernetes:") || additionalMatch.map { text.contains($0) } == true ? 0 : 1)
        }
        switch queryFault {
        case .uniform: vectors = texts.map { _ in Self.vector(0) }
        case .shortVector: vectors = texts.map { _ in [Float(1)] }
        case .zeroVector: vectors = texts.map { _ in Array(repeating: Float(0), count: 768) }
        case .nonFinite: vectors[0][0] = .nan
        case .notNormalized: vectors = texts.map { _ in Self.vector(0).map { $0 * 2 } }
        case .missingVector: vectors.removeLast()
        default: break
        }
        return EmbeddingBatch(vectors: vectors, signature: queryFault == .signature ? "wrong-space" : signature)
    }

    private func suspendIfArmed(_ point: PausePoint) async {
        guard pause == point else { return }
        pause = nil
        await withCheckedContinuation { pending[point] = $0 }
    }
    func pauseNext(_ point: PausePoint) { pause = point }
    func isPaused(at point: PausePoint?) -> Bool {
        if let point { return pending[point] != nil }
        return !pending.isEmpty
    }
    func resume(_ point: PausePoint? = nil) {
        if let point {
            pending.removeValue(forKey: point)?.resume()
        } else {
            let continuations = Array(pending.values)
            pending.removeAll()
            for continuation in continuations { continuation.resume() }
        }
    }
    func calls() -> Calls { recorded }
    func setQueryFault(_ fault: QueryFault) { queryFault = fault }
    func setSignature(_ value: String) { signature = value }
    func setDocumentAxis(_ value: Int) { documentAxis = value }
    func setAdditionalMatch(_ value: String) { additionalMatch = value }
}

private final class AutoTagForbiddenChat: ChatProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func record() { lock.lock(); defer { lock.unlock() }; count += 1 }
    func models() async throws -> [String] {
        record()
        throw AskBaseError.modelUnavailable("Auto-tagging must not call ChatProviding.models")
    }
    func answer(model: String, question: String, sources: [SearchResult], history: [ChatMessage]) async throws -> String {
        record()
        throw AskBaseError.modelUnavailable("Auto-tagging must not call ChatProviding.answer")
    }
}

/// Exercise the real HTTP clients without binding ports or contacting a model.
private final class AutoTagHTTPProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    static func reset() { lock.lock(); defer { lock.unlock() }; requests = [] }
    static func recordedRequests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    private static func record(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.record(request)
        do {
            let data: Data
            if request.url?.path == "/health" {
                data = try JSONEncoder().encode(EmbeddingHealth(encoderSignature: AutoTagTestEmbedder.originalSignature))
            } else if request.url?.path == "/v1/embeddings" {
                var body = request.httpBody ?? Data()
                if body.isEmpty, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                }
                guard let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let texts = payload["input"] as? [String], let type = payload["input_type"] as? String,
                      (1...8).contains(texts.count), ["query", "document"].contains(type) else {
                    throw AskBaseError.invalidInput("Invalid synthetic embedding HTTP request")
                }
                let entries: [[String: Any]] = texts.enumerated().map { index, text in
                    let axis = type == "query" ? (text.contains("Kubernetes:") ? 0 : 1)
                        : (text.contains("UNRELATED_OFFLINE_FIXTURE") ? 2 : 0)
                    return ["index": index, "embedding": AutoTagTestEmbedder.vector(axis)]
                }
                data = try JSONSerialization.data(withJSONObject: [
                    "model": "embeddinggemma-2", "dimensions": 768, "input_type": type,
                    "encoder_signature": AutoTagTestEmbedder.originalSignature, "data": entries,
                ])
            } else {
                throw AskBaseError.invalidInput("Forbidden HTTP route: \(request.url?.path ?? "")")
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
