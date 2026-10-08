import CryptoKit
import CSQLite
import Darwin
import Foundation
import XCTest
@testable import AskBaseCore

final class ImportRegressionTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskBaseImportRegressionTests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }

    func testChunkCoverageAcrossGraphemeBoundariesAndOverlapExtremes() throws {
        // Every grapheme contains non-whitespace, so no intentionally empty
        // window is discarded. Compare bytes as well as grapheme counts.
        let texts = [
            "中。a!👩🏽‍💻e\u{301}🇨🇳🇺🇸क्‍ष；x?終.",
            String(repeating: "🇦🇧🇨🇩e\u{301}👨‍👩‍👧‍👦。", count: 37) + "末尾",
            "a" + String(repeating: "\u{301}", count: 2_000) + "。尾",
        ]
        for text in texts {
            for size in [1, 2, 3, 4, 7, 16, 83, 1_200] {
                for requestedOverlap in [-1, 0, 1, size / 2, size - 1, Int.max] {
                    let overlap = min(max(requestedOverlap, 0), size - 1)
                    let chunks = try TextChunker.cancellableChunks(
                        pages: [ParsedPage(page: 9, text: text)],
                        documentID: "document", knowledgeBaseID: "base",
                        maxCharacters: size, overlap: requestedOverlap
                    )
                    let label = "size=\(size), overlap=\(requestedOverlap)"
                    var reconstructed = try XCTUnwrap(chunks.first, label).text
                    for chunk in chunks.dropFirst() {
                        reconstructed.append(contentsOf: chunk.text.dropFirst(overlap))
                    }
                    XCTAssertEqual(Data(reconstructed.utf8), Data(text.utf8), label)
                    XCTAssertTrue(chunks.allSatisfy { $0.text.count <= size && $0.page == 9 }, label)
                    XCTAssertEqual(chunks.map(\.ordinal), Array(chunks.indices), label)
                }
            }
        }
    }

    func testSnapshotHashCopyAndChunksAgreeAcrossReadBoundaries() throws {
        let text = String(repeating: "a", count: 1_048_575)
            + "中👩🏽‍💻e\u{301}\r\n"
            + String(repeating: "第二段资料。", count: 100_000)
            + "\r最终标记"
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        let source = try fixture("boundary.unlisted", bytes)
        let prepared = try DocumentImporter.prepare(
            url: source, knowledgeBaseID: "base",
            originalsRoot: root.appendingPathComponent("Originals")
        )
        let expectedHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(prepared.document.contentHash, expectedHash)
        XCTAssertEqual(prepared.document.byteCount, bytes.count)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(prepared.document.relativePath)), bytes)
        var reconstructed = try XCTUnwrap(prepared.chunks.first).text
        for chunk in prepared.chunks.dropFirst() {
            reconstructed.append(contentsOf: chunk.text.dropFirst(160))
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        XCTAssertEqual(Data(reconstructed.utf8), Data(normalized.utf8))
    }

    func testCombiningMarkExtensionCanImportReindexAndDelete() async throws {
        let engine = try KnowledgeEngine(root: root, embeddingClient: ImportReviewEmbedder())
        let base = try await engine.snapshot().knowledgeBases[0]
        // This is a legal filesystem extension. The separator and accent form
        // one Swift Character, but are still distinct filename bytes.
        let source = try fixture("report.\u{301}", Data("合法组合字符扩展名。".utf8))
        let report = try await engine.importDocuments(urls: [source], knowledgeBaseID: base.id)
        XCTAssertEqual(report.imported.count, 1, report.failures.joined(separator: "\n"))
        guard let document = report.imported.first else { return }
        try await engine.reindex(documentID: document.id)
        let chunks = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(chunks.map(\.text), ["合法组合字符扩展名。"])
        let copy = try await engine.originalURL(documentID: document.id)
        try await engine.deleteDocument(id: document.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCancellingCopyAfterAStagedWriteRemovesEveryPartialFile() async throws {
        let originals = root.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let source = temporary.appendingPathComponent("controlled-source")
        XCTAssertEqual(mkfifo(source.path, 0o600), 0)
        let filename = "\(UUID().uuidString).custom"
        let releaseWriter = DispatchSemaphore(value: 0)
        let writerFinishedFirstBlock = ImportReviewFlag()
        // Only this helper-level fixture uses a FIFO; public import rejects it.
        // Holding the writer open makes cancellation after real copy progress
        // deterministic, without relying on a large file being slow enough.
        let writer = Task.detached {
            let descriptor = Darwin.open(source.path, O_WRONLY | O_CLOEXEC)
            guard descriptor >= 0 else { throw AskBaseError.storage("无法打开测试管道") }
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? output.close() }
            try output.write(contentsOf: Data(repeating: 0x61, count: 1_048_576))
            writerFinishedFirstBlock.set()
            _ = releaseWriter.wait(timeout: .now() + 10)
        }
        let copy = Task.detached {
            try OriginalFileStorage.copy(source, filename: filename, directory: originals)
        }
        defer { copy.cancel(); releaseWriter.signal() }
        var observedWrite = false
        for _ in 0..<500 {
            if writerFinishedFirstBlock.value {
                let entries = try FileManager.default.contentsOfDirectory(
                    at: originals, includingPropertiesForKeys: nil
                )
                observedWrite = try entries.contains {
                    guard $0.lastPathComponent.hasPrefix(".askbase-") else { return false }
                    let attributes = try FileManager.default.attributesOfItem(atPath: $0.path)
                    return ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0
                }
                if observedWrite { break }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        copy.cancel()
        releaseWriter.signal()
        try await writer.value
        do {
            try await copy.value
            XCTFail("Cancellation after a staged write must not publish a destination")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(observedWrite, "The fixture must reach a real write before cancellation")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: originals.path).isEmpty)
    }

    func testCancelledImportKeepsACompleteExtensionlessCopyThatCanBeRetried() async throws {
        let embedder = ImportReviewEmbedder()
        await embedder.pauseNextBatch()
        let engine = try KnowledgeEngine(root: root, embeddingClient: embedder)
        let base = try await engine.snapshot().knowledgeBases[0]
        let bytes = Data("取消之后仍可完整重试的资料。".utf8)
        let source = try fixture("README", bytes)
        let importing = Task { try await engine.importDocuments(urls: [source], knowledgeBaseID: base.id) }
        let waiting = await waitForPause(embedder)
        importing.cancel()
        await embedder.release()
        do {
            _ = try await importing.value
            XCTFail("The engine must check cancellation even if an embedder returns vectors")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(waiting)
        let snapshot = try await engine.snapshot()
        let document = try XCTUnwrap(snapshot.documents.first)
        XCTAssertEqual(document.status, .failed)
        let original = try await engine.originalURL(documentID: document.id)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let beforeRetry = try await engine.documentChunks(documentID: document.id)
        XCTAssertTrue(beforeRetry.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path),
                       [document.id])
        try await engine.reindex(documentID: document.id)
        let afterRetry = try await engine.snapshot()
        XCTAssertEqual(afterRetry.documents.first?.status, .ready)
        let chunks = try await engine.documentChunks(documentID: document.id)
        XCTAssertEqual(chunks.map(\.text), ["取消之后仍可完整重试的资料。"])
    }

    func testCancelledReindexPreservesCommittedIndexForLongUnknownExtension() async throws {
        let embedder = ImportReviewEmbedder()
        let engine = try KnowledgeEngine(root: root, embeddingClient: embedder)
        let base = try await engine.snapshot().knowledgeBases[0]
        let source = try fixture("a." + String(repeating: "x", count: 220), Data("必须保留的旧索引。".utf8))
        let report = try await engine.importDocuments(urls: [source], knowledgeBaseID: base.id)
        let document = try XCTUnwrap(report.imported.first, report.failures.joined(separator: "\n"))
        XCTAssertEqual(document.relativePath, "Originals/\(document.id)")
        let before = try await engine.documentChunks(documentID: document.id)
        await embedder.pauseNextBatch()
        let reindexing = Task { try await engine.reindex(documentID: document.id) }
        let waiting = await waitForPause(embedder)
        reindexing.cancel()
        await embedder.release()
        do {
            try await reindexing.value
            XCTFail("A cancelled replacement must not commit new chunk identities")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(waiting)
        let after = try await engine.documentChunks(documentID: document.id)
        let snapshot = try await engine.snapshot()
        XCTAssertEqual(after, before)
        XCTAssertEqual(snapshot.documents.first, document)
        let original = try await engine.originalURL(documentID: document.id)
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: source))
    }

    func testFailedMetadataInsertDoesNotLeaveAnUnownedManagedCopy() async throws {
        let engine = try KnowledgeEngine(root: root, embeddingClient: ImportReviewEmbedder())
        let base = try await engine.snapshot().knowledgeBases[0]
        try executeSQL("""
            CREATE TRIGGER reject_import_metadata BEFORE INSERT ON documents
            BEGIN SELECT RAISE(ABORT, 'synthetic import metadata failure'); END;
            """)
        let source = try fixture("metadata.custom", Data("写入记录失败时应清理尚未归属的副本。".utf8))
        let report = try await engine.importDocuments(urls: [source], knowledgeBaseID: base.id)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.imported.isEmpty)
        let snapshot = try await engine.snapshot()
        XCTAssertTrue(snapshot.documents.isEmpty)
        let reopened = try KnowledgeEngine(root: root, embeddingClient: ImportReviewEmbedder())
        let afterReopen = try await reopened.snapshot()
        XCTAssertTrue(afterReopen.documents.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Originals").path)
        XCTAssertTrue(files.isEmpty, "Unowned copies survive recovery: \(files)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testReindexRejectsSymlinkedOriginalsDirectoryAndKeepsOldChunks() async throws {
        let engine = try KnowledgeEngine(root: root, embeddingClient: ImportReviewEmbedder())
        let base = try await engine.snapshot().knowledgeBases[0]
        let source = try fixture("README", Data("已验证的原始内容。".utf8))
        let report = try await engine.importDocuments(urls: [source], knowledgeBaseID: base.id)
        let document = try XCTUnwrap(report.imported.first, report.failures.joined(separator: "\n"))
        let before = try await engine.documentChunks(documentID: document.id)
        let originals = root.appendingPathComponent("Originals")
        let external = temporary.appendingPathComponent("external-originals")
        try FileManager.default.moveItem(at: originals, to: external)
        let replacement = Data("外部替换内容不应成为这份资料的索引。".utf8)
        try replacement.write(to: external.appendingPathComponent(document.id))
        try FileManager.default.createSymbolicLink(at: originals, withDestinationURL: external)
        do {
            try await engine.reindex(documentID: document.id)
            XCTFail("Reindex must not canonicalize away the protected directory's symlink")
        } catch {
            XCTAssertTrue(error is AskBaseError, "\(error)")
        }
        let after = try await engine.documentChunks(documentID: document.id)
        XCTAssertTrue(after == before, "Rejected reindex must preserve all committed chunks")
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent(document.id)), replacement)
    }

    func testCombiningMarkAfterSlashCannotBypassManagedFilenameValidationOrDeleteOutside() throws {
        let originals = root.appendingPathComponent("Originals")
        let external = temporary.appendingPathComponent("outside-library")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinel = external.appendingPathComponent("\u{301}sentinel")
        let bytes = Data("This file is outside the managed Originals directory.".utf8)
        try bytes.write(to: sentinel)
        let intermediateName = "\(UUID().uuidString).dir"
        try FileManager.default.createSymbolicLink(
            at: originals.appendingPathComponent(intermediateName), withDestinationURL: external
        )
        // A slash followed by an accent is one Swift Character, but POSIX still
        // interprets the 0x2F byte as a directory separator.
        let path = "Originals/\(intermediateName)/\u{301}sentinel"
        XCTAssertThrowsError(try OriginalFileStorage.filename(relativePath: path))
        XCTAssertThrowsError(try OriginalFileStorage.remove(relativePath: path, directory: originals))
        XCTAssertEqual(try? Data(contentsOf: sentinel), bytes,
                       "Validation must prevent unlinkat from following an intermediate symlink")
    }

    func testDeletingManagedSymlinksWithNewFilenameShapesLeavesTargetsIntact() async throws {
        let engine = try KnowledgeEngine(root: root, embeddingClient: ImportReviewEmbedder())
        let base = try await engine.snapshot().knowledgeBases[0]
        for name in ["README", "notes.中文", "a." + String(repeating: "x", count: 220)] {
            let bytes = Data("真实来源必须保留：\(name)".utf8)
            let source = try fixture(name, bytes)
            let report = try await engine.importDocuments(urls: [source], knowledgeBaseID: base.id)
            let document = try XCTUnwrap(report.imported.first, report.failures.joined(separator: "\n"))
            let managed = root.appendingPathComponent(document.relativePath)
            try FileManager.default.removeItem(at: managed)
            try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: source)
            try await engine.deleteDocument(id: document.id)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            var info = stat()
            XCTAssertEqual(lstat(managed.path, &info), -1)
            XCTAssertEqual(errno, ENOENT)
        }
        let snapshot = try await engine.snapshot()
        XCTAssertTrue(snapshot.documents.isEmpty)
    }

    func testDeclaredMissingOOXMLRootCannotFallBackToAnUnreferencedBody() async throws {
        let bytes = storedZIP([
            ("[Content_Types].xml", """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Override PartName="/word/document.xml"
                ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
            """),
            ("_rels/.rels", """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="main"
                Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
                Target="word/missing.xml"/>
            </Relationships>
            """),
            ("word/document.xml", """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body><w:p><w:r><w:t>Unreferenced stale text must not hide a missing main part.</w:t></w:r></w:p></w:body>
            </w:document>
            """),
        ])
        try await assertIncompletePackageRejected(name: "missing-root.docx", bytes: bytes)
    }

    func testDOCXMissingAltChunkCannotCommitOnlyThePrecedingParagraph() async throws {
        let bytes = storedZIP([
            ("word/document.xml", """
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <w:body>
                <w:p><w:r><w:t>Only the beginning is stored in the main XML.</w:t></w:r></w:p>
                <w:altChunk r:id="remainingText"/>
              </w:body>
            </w:document>
            """),
            ("word/_rels/document.xml.rels", """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="remainingText"
                Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/aFChunk"
                Target="missing-body.html"/>
            </Relationships>
            """),
        ])
        try await assertIncompletePackageRejected(name: "missing-altchunk.docx", bytes: bytes)
    }

    func testEPUBMissingNonTextSpineMemberCannotCommitOnlyTheFirstChapter() async throws {
        let bytes = storedZIP([
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """),
            ("OPS/book.opf", """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="first" href="first.xhtml" media-type="application/xhtml+xml"/>
                <item id="missing" href="missing.svg" media-type="image/svg+xml"/>
              </manifest>
              <spine><itemref idref="first"/><itemref idref="missing"/></spine>
            </package>
            """),
            ("OPS/first.xhtml", "<html><body><p>The first chapter exists.</p></body></html>"),
        ])
        try await assertIncompletePackageRejected(name: "missing-spine.epub", bytes: bytes)
    }

    private func assertIncompletePackageRejected(
        name: String, bytes: Data, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let source = try fixture(name, bytes)
        let engine = try KnowledgeEngine(root: root, embeddingClient: ImportReviewEmbedder())
        let base = try await engine.snapshot().knowledgeBases[0]
        let report = try await engine.importDocuments(urls: [source], knowledgeBaseID: base.id)
        XCTAssertTrue(report.imported.isEmpty, "Incomplete package must not become ready", file: file, line: line)
        XCTAssertEqual(report.failures.count, 1, file: file, line: line)
        let snapshot = try await engine.snapshot()
        XCTAssertTrue(snapshot.documents.isEmpty, file: file, line: line)
        let copies = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Originals").path)
        XCTAssertTrue(copies.isEmpty, "Rejected package must not leave managed copies", file: file, line: line)
    }

    private func fixture(_ name: String, _ bytes: Data) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func waitForPause(_ embedder: ImportReviewEmbedder) async -> Bool {
        for _ in 0..<500 {
            if await embedder.isWaiting { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func executeSQL(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("library.sqlite").path, &database,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw AskBaseError.storage("无法打开隔离测试数据库")
        }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AskBaseError.storage(String(cString: sqlite3_errmsg(database)))
        }
    }

    /// Stored entries keep the missing-resource fixtures self-contained and
    /// deterministic; none of these tests invokes a compressor or uses a corpus.
    private func storedZIP(_ entries: [(String, String)]) -> Data {
        var output = Data(), central = Data()
        func append(_ number: UInt64, width: Int, to data: inout Data) {
            for index in 0..<width { data.append(UInt8(truncatingIfNeeded: number >> (8 * index))) }
        }
        for (name, value) in entries {
            let filename = Data(name.utf8), bytes = Data(value.utf8)
            let offset = output.count
            var checksum: UInt32 = 0xFFFFFFFF
            for byte in bytes {
                checksum ^= UInt32(byte)
                for _ in 0..<8 {
                    checksum = checksum & 1 == 1 ? (checksum >> 1) ^ 0xEDB88320 : checksum >> 1
                }
            }
            let crc = UInt64(~checksum)
            append(0x04034B50, width: 4, to: &output)
            for field in [UInt64(20), 0x0800, 0, 0, 0] { append(field, width: 2, to: &output) }
            for field in [crc, UInt64(bytes.count), UInt64(bytes.count)] { append(field, width: 4, to: &output) }
            append(UInt64(filename.count), width: 2, to: &output)
            append(0, width: 2, to: &output)
            output.append(filename)
            output.append(bytes)
            append(0x02014B50, width: 4, to: &central)
            for field in [UInt64(20), 20, 0x0800, 0, 0, 0] { append(field, width: 2, to: &central) }
            for field in [crc, UInt64(bytes.count), UInt64(bytes.count)] { append(field, width: 4, to: &central) }
            for field in [UInt64(filename.count), 0, 0, 0, 0] { append(field, width: 2, to: &central) }
            append(0, width: 4, to: &central)
            append(UInt64(offset), width: 4, to: &central)
            central.append(filename)
        }
        let offset = output.count
        output.append(central)
        append(0x06054B50, width: 4, to: &output)
        for field in [UInt64(0), 0, UInt64(entries.count), UInt64(entries.count)] {
            append(field, width: 2, to: &output)
        }
        append(UInt64(central.count), width: 4, to: &output)
        append(UInt64(offset), width: 4, to: &output)
        append(0, width: 2, to: &output)
        return output
    }
}

private final class ImportReviewFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.lock(); defer { lock.unlock() }; stored = true }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
}

private actor ImportReviewEmbedder: EmbeddingProviding {
    private var shouldPause = false
    private var pending: CheckedContinuation<EmbeddingBatch, Never>?
    private var pendingBatch: EmbeddingBatch?
    func health() async throws -> EmbeddingHealth {
        EmbeddingHealth(encoderSignature: "import-review-v1")
    }
    func embed(_ texts: [String], inputType: String) async throws -> EmbeddingBatch {
        let batch = EmbeddingBatch(
            vectors: texts.map { _ in [Float(1)] + Array(repeating: 0, count: 767) },
            signature: "import-review-v1"
        )
        if shouldPause {
            shouldPause = false
            pendingBatch = batch
            return await withCheckedContinuation { pending = $0 }
        }
        return batch
    }
    func pauseNextBatch() { shouldPause = true }
    var isWaiting: Bool { pending != nil }
    func release() {
        if let pending, let pendingBatch { pending.resume(returning: pendingBatch) }
        pending = nil
        pendingBatch = nil
    }
}
