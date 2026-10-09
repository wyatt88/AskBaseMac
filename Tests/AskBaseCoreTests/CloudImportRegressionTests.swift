import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import AskBaseCore

/// Offline filesystem regressions. Hooks schedule real mutations after actual
/// IO; they do not supply fake metadata, fake bytes, or replacement digests.
final class CloudImportRegressionTests: XCTestCase {
    private let blockSize = 1_048_576
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskBaseCloudImportTests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }

    func testRealXattrChangeRevalidatesUnchangedBytesWithoutRetry() throws {
        let bytes = payload(0x41)
        let source = try fixture(bytes)
        let trace = CloudSnapshotTrace()
        let before = try metadata(source)
        let snapshot = try FileSnapshotReader.read(source, hooks: hooks(trace, copy: { attempt, copied in
            if attempt == 1 && copied == self.blockSize {
                try self.changeXattr(source)
                let changed = try self.metadata(source)
                XCTAssertNotEqual(self.ctime(before), self.ctime(changed), "Must change the real inode ctime")
                XCTAssertEqual(self.mtime(before), self.mtime(changed))
                XCTAssertEqual(before.st_size, changed.st_size)
                XCTAssertEqual(before.st_ino, changed.st_ino)
            }
        }))
        defer { snapshot.remove() }
        try assertSnapshot(snapshot, equals: bytes)
        XCTAssertEqual(trace.copyAttempts, [1])
        XCTAssertEqual(trace.validationBytes, bytes.count, "ctime is a reason to verify, not to ignore metadata")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        snapshot.remove()
        snapshot.remove()
        assertRemoved(trace.directories)
    }

    func testRealMtimeChangeRevalidatesIdenticalContents() throws {
        let bytes = payload(0x52)
        let source = try fixture(bytes)
        let trace = CloudSnapshotTrace()
        let before = try metadata(source)
        let snapshot = try FileSnapshotReader.read(source, hooks: hooks(trace, copy: { attempt, copied in
            if attempt == 1 && copied == self.blockSize {
                var later = before
                later.st_mtimespec.tv_sec += 10
                try self.restoreTimes(source, from: later)
                XCTAssertNotEqual(self.mtime(before), self.mtime(try self.metadata(source)))
            }
        }))
        defer { snapshot.remove() }
        try assertSnapshot(snapshot, equals: bytes)
        XCTAssertEqual(trace.copyAttempts, [1])
        XCTAssertEqual(trace.validationBytes, bytes.count)
        snapshot.remove()
        assertRemoved(trace.directories)
    }

    func testSameSizeOverwriteDuringCopyRetriesAndReturnsOnlyNewVersion() throws {
        let original = payload(0x61)
        let replacement = payload(0x62)
        let source = try fixture(original)
        let trace = CloudSnapshotTrace()
        let snapshot = try FileSnapshotReader.read(source, hooks: hooks(trace, copy: { attempt, copied in
            if attempt == 1 && copied == self.blockSize {
                try self.overwrite(source, with: replacement)
            }
        }))
        defer { snapshot.remove() }
        try assertSnapshot(snapshot, equals: replacement)
        XCTAssertEqual(trace.copyAttempts, [1, 2])
        XCTAssertEqual(trace.directories.count, 2)
        assertRemoved(trace.directories.filter { $0 != snapshot.directory })
        snapshot.remove()
        assertRemoved(trace.directories)
    }

    func testTruncationDuringCopyRetriesWithoutReturningAnIncompleteFile() throws {
        let original = payload(0x61)
        let replacement = Data(repeating: 0x62, count: 32_771)
        let source = try fixture(original)
        let trace = CloudSnapshotTrace()
        let snapshot = try FileSnapshotReader.read(source, hooks: hooks(trace, copy: { attempt, copied in
            if attempt == 1 && copied == self.blockSize {
                let writer = try FileHandle(forWritingTo: source)
                defer { try? writer.close() }
                try writer.truncate(atOffset: 0)
                try writer.write(contentsOf: replacement)
                try writer.synchronize()
            }
        }))
        defer { snapshot.remove() }
        try assertSnapshot(snapshot, equals: replacement)
        XCTAssertEqual(trace.copyAttempts, [1, 2])
        snapshot.remove()
        assertRemoved(trace.directories)
    }

    func testSameSizeOverwriteWithRestoredMtimeStillRetriesUsingCtimeAndHash() throws {
        let original = payload(0x31)
        let replacement = payload(0x32)
        let source = try fixture(original)
        let before = try metadata(source)
        let trace = CloudSnapshotTrace()
        let snapshot = try FileSnapshotReader.read(source, hooks: hooks(trace, copy: { attempt, copied in
            if attempt == 1 && copied == self.blockSize {
                try self.overwrite(source, with: replacement)
                try self.restoreTimes(source, from: before)
                let changed = try self.metadata(source)
                XCTAssertEqual(self.mtime(before), self.mtime(changed), "Fixture really restores mtime")
                XCTAssertNotEqual(self.ctime(before), self.ctime(changed))
            }
        }))
        defer { snapshot.remove() }
        try assertSnapshot(snapshot, equals: replacement)
        XCTAssertEqual(trace.copyAttempts, [1, 2])
        XCTAssertGreaterThan(trace.validationBytes, 0)
        snapshot.remove()
        assertRemoved(trace.directories)
    }

    func testWriteToAlreadyVerifiedPrefixDuringValidationForcesRetry() throws {
        let original = payload(0x41)
        var replacement = original
        replacement.replaceSubrange(0..<blockSize, with: Data(repeating: 0x42, count: blockSize))
        let source = try fixture(original)
        let trace = CloudSnapshotTrace()
        let snapshot = try FileSnapshotReader.read(source, hooks: hooks(trace, copy: { attempt, copied in
            if attempt == 1 && copied == self.blockSize { try self.changeXattr(source) }
        }, validation: { attempt, verified in
            if attempt == 1 && verified == self.blockSize {
                // The verifier already read this prefix; its digest alone would
                // still equal the old snapshot without checking the final stat.
                try self.overwrite(source, with: replacement)
            }
        }))
        defer { snapshot.remove() }
        try assertSnapshot(snapshot, equals: replacement)
        XCTAssertEqual(trace.copyAttempts, [1, 2])
        snapshot.remove()
        assertRemoved(trace.directories)
    }

    func testRepeatedWritesWithRestoredMtimeCannotValidateATornSnapshot() throws {
        let original = payload(0x41)
        let replacement = payload(0x42)
        let source = try fixture(original)
        let before = try metadata(source)
        let trace = CloudSnapshotTrace()
        let snapshot = try FileSnapshotReader.read(source, hooks: hooks(trace, copy: { attempt, copied in
            guard attempt == 1 else { return }
            if copied == self.blockSize {
                try self.overwrite(source, with: replacement)
                try self.restoreTimes(source, from: before)
            } else if copied == original.count {
                // First pass copied old prefix + new suffix. Restore A before
                // validation, then repeat the real A -> B write in pass two.
                try self.overwrite(source, with: original)
                try self.restoreTimes(source, from: before)
            }
        }, validation: { attempt, verified in
            if attempt == 1 && verified == self.blockSize {
                try self.overwrite(source, with: replacement)
                try self.restoreTimes(source, from: before)
            }
        }))
        defer { snapshot.remove() }
        let observed = try Data(contentsOf: snapshot.url)
        XCTAssertTrue(observed == replacement, "Matching two torn hashes must not accept a mixed version")
        XCTAssertEqual(snapshot.contentHash, sha256(replacement))
        XCTAssertEqual(trace.copyAttempts, [1, 2])
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        snapshot.remove()
        assertRemoved(trace.directories)
    }

    func testAtomicReplacementRetriesCurrentURLInsteadOfReadableOldDescriptor() throws {
        try checkAtomicReplacement(sameContents: false)
    }

    func testAtomicReplacementWithIdenticalContentsAndMtimeStillReopensNewInode() throws {
        try checkAtomicReplacement(sameContents: true)
    }

    func testThreeChangingAttemptsFailClearlyAndRemoveEverySnapshot() throws {
        let original = payload(0x61)
        let replacement = payload(0x62)
        let source = try fixture(original)
        let trace = CloudSnapshotTrace()
        defer { assertRemoved(trace.directories) }
        XCTAssertThrowsError(try FileSnapshotReader.read(source, hooks: hooks(trace, copy: { attempt, copied in
            if copied == self.blockSize {
                try self.overwrite(source, with: attempt.isMultiple(of: 2) ? original : replacement)
            }
        }))) { error in
            guard case AskBaseError.importFailed(let message) = error else {
                return XCTFail("Expected a clear import failure, got \(error)")
            }
            XCTAssertTrue(message.contains("同步"))
            XCTAssertTrue(message.contains("3"))
        }
        XCTAssertEqual(trace.copyAttempts, [1, 2, 3])
        XCTAssertEqual(trace.directories.count, 3)
    }

    func testContinuouslyGrowingFileHasBoundedReadExtentAndAttempts() throws {
        let bytes = Data(repeating: 0x61, count: blockSize + 13)
        let source = try fixture(bytes)
        let trace = CloudSnapshotTrace()
        let additional = Data(repeating: 0x62, count: blockSize)
        var expectedExtents = [Int: Int]()
        defer { assertRemoved(trace.directories) }
        XCTAssertThrowsError(try FileSnapshotReader.read(source, hooks: hooks(trace, copy: { attempt, copied in
            if expectedExtents[attempt] == nil {
                expectedExtents[attempt] = Int(try self.metadata(source).st_size)
            }
            let writer = try FileHandle(forWritingTo: source)
            defer { try? writer.close() }
            try writer.seekToEnd()
            try writer.write(contentsOf: additional)
            try writer.synchronize()
            XCTAssertLessThanOrEqual(copied, try XCTUnwrap(expectedExtents[attempt]))
        })))
        XCTAssertEqual(trace.copyAttempts, [1, 2, 3])
        XCTAssertEqual(trace.directories.count, 3)
    }

    func testSymlinkSubstitutionDuringCopyIsRejectedAndTargetIsUntouched() throws {
        let source = try fixture(payload(0x41))
        let targetBytes = Data("Synthetic target; never a user document.".utf8)
        let target = try fixture(targetBytes, name: "target")
        let link = temporary.appendingPathComponent("replacement-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let trace = CloudSnapshotTrace()
        defer { assertRemoved(trace.directories) }
        XCTAssertThrowsError(try FileSnapshotReader.read(source, hooks: hooks(trace, copy: { attempt, copied in
            if attempt == 1 && copied == self.blockSize {
                try self.checkPOSIX(Darwin.rename(link.path, source.path), operation: "rename symlink")
            }
        })))
        XCTAssertEqual(trace.copyAttempts, [1])
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
    }

    func testNonRegularSourcesAreRejectedBeforeSnapshotCreation() throws {
        let regular = try fixture(Data("Synthetic regular file".utf8))
        let link = temporary.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let fifo = temporary.appendingPathComponent("fifo")
        try checkPOSIX(mkfifo(fifo.path, 0o600), operation: "mkfifo")
        for source in [link, fifo, temporary!] {
            let trace = CloudSnapshotTrace()
            XCTAssertThrowsError(try FileSnapshotReader.read(source, hooks: hooks(trace)))
            XCTAssertTrue(trace.directories.isEmpty)
            XCTAssertTrue(trace.copyAttempts.isEmpty)
        }
    }

    func testSnapshotCreationFailureRemovesNewDirectoryWithoutRetry() throws {
        let source = try fixture(payload(0x41))
        let trace = CloudSnapshotTrace()
        var faultHooks = hooks(trace)
        faultHooks.snapshotCreated = { directory in
            trace.recordDirectory(directory)
            throw CloudFixtureError.injected
        }
        XCTAssertThrowsError(try FileSnapshotReader.read(source, hooks: faultHooks))
        XCTAssertEqual(trace.directories.count, 1)
        XCTAssertTrue(trace.copyAttempts.isEmpty)
        assertRemoved(trace.directories)
    }

    func testCancellationAfterFirstAsyncCopyChunkRemovesPartialSnapshot() async throws {
        try await checkAsyncCopyCancellation(atEnd: false)
    }

    func testCancellationAfterLastAsyncCopyChunkRemovesCompletedBytesBeforeReturn() async throws {
        try await checkAsyncCopyCancellation(atEnd: true)
    }

    func testCancellationDuringAsyncValidationRemovesSnapshotWithoutRetry() async throws {
        let source = try fixture(payload(0x41))
        let paused = expectation(description: "Actual second-pass read reached the first block")
        let release = DispatchSemaphore(value: 0)
        let trace = CloudSnapshotTrace()
        let worker = Task.detached { () throws -> Void in
            let snapshot = try await FileSnapshotReader.readAsync(source, hooks: self.hooks(trace, copy: { attempt, copied in
                if attempt == 1 && copied == self.blockSize { try self.changeXattr(source) }
            }, validation: { attempt, verified in
                if attempt == 1 && verified == self.blockSize {
                    paused.fulfill()
                    guard release.wait(timeout: .now() + 10) == .success else { throw CloudFixtureError.timeout }
                }
            }))
            snapshot.remove()
            XCTFail("A cancelled validation must not transfer ownership")
        }
        defer { worker.cancel(); release.signal() }
        await fulfillment(of: [paused], timeout: 5)
        worker.cancel()
        release.signal()
        do { try await worker.value; XCTFail("Expected CancellationError") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(trace.copyAttempts, [1])
        XCTAssertEqual(trace.validationBytes, blockSize)
        assertRemoved(trace.directories)
    }

    func testAsyncCompletionCancellationRaceDoesNotLeakSnapshots() async throws {
        let source = try fixture(Data(repeating: 0x41, count: 32_771))
        // Success and CancellationError are both legitimate race outcomes.
        // Every created directory must nevertheless have exactly one owner
        // responsible for removal, including across continuation resumption.
        for iteration in 0..<16 {
            let copied = expectation(description: "Last write \(iteration)")
            let release = DispatchSemaphore(value: 0)
            let trace = CloudSnapshotTrace()
            let worker = Task.detached {
                do {
                    let snapshot = try await FileSnapshotReader.readAsync(source, hooks: self.hooks(trace, copy: { _, _ in
                        copied.fulfill()
                        guard release.wait(timeout: .now() + 10) == .success else { throw CloudFixtureError.timeout }
                    }))
                    defer { snapshot.remove() }
                    try Task.checkCancellation()
                } catch is CancellationError {
                    // The reader owns cleanup when no snapshot is returned.
                }
            }
            await fulfillment(of: [copied], timeout: 5)
            release.signal()
            worker.cancel()
            try await worker.value
            XCTAssertEqual(trace.directories.count, 1)
            assertRemoved(trace.directories)
        }
    }

    func testPreCancelledAsyncReadNeverCreatesSnapshot() async throws {
        let source = try fixture(payload(0x41))
        let trace = CloudSnapshotTrace()
        let worker = Task.detached { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            let snapshot = try await FileSnapshotReader.readAsync(source, hooks: self.hooks(trace))
            snapshot.remove()
            XCTFail("A pre-cancelled task must not return a snapshot")
        }
        do { try await worker.value; XCTFail("Expected CancellationError") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(trace.directories.isEmpty)
        XCTAssertTrue(trace.copyAttempts.isEmpty)
    }

    func testCancellationWhileFoundationWaitsForPresenterDoesNotNeedPresenterRelease() async throws {
        let bytes = payload(0x41)
        let source = try fixture(bytes)
        let requested = expectation(description: "Foundation requested relinquishPresentedItemToReader")
        let finished = expectation(description: "Cancellation finishes while presenter is still held")
        let presenter = CloudHoldingPresenter(url: source, requested: requested)
        NSFileCoordinator.addFilePresenter(presenter)
        defer {
            presenter.releaseReader()
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        let trace = CloudSnapshotTrace()
        let worker = Task.detached { () throws -> Void in
            defer { finished.fulfill() }
            let snapshot = try await FileSnapshotReader.readAsync(source, hooks: self.hooks(trace))
            snapshot.remove()
            XCTFail("The accessor must not execute before the presenter grants access")
        }
        await fulfillment(of: [requested], timeout: 5)
        XCTAssertTrue(trace.copyAttempts.isEmpty)
        worker.cancel()
        // Keep the presenter held during this bounded wait. Releasing it before
        // checking completion would let a broken cancellation path pass.
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertTrue(presenter.isHoldingReader)
        presenter.releaseReader()
        do { try await worker.value; XCTFail("Expected CancellationError") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(trace.directories.isEmpty)
        XCTAssertTrue(trace.copyAttempts.isEmpty)
    }

    func testCancellationAfterSnapshotOwnershipTransferCleansUpInCallerDefer() async throws {
        let bytes = payload(0x41)
        let source = try fixture(bytes)
        let transferred = expectation(description: "Caller owns a complete snapshot")
        let trace = CloudSnapshotTrace()
        let worker = Task.detached { () throws -> Void in
            let snapshot = try await FileSnapshotReader.readAsync(source, hooks: self.hooks(trace))
            defer { snapshot.remove() }
            try self.assertSnapshot(snapshot, equals: bytes)
            transferred.fulfill()
            try await Task.sleep(for: .seconds(30))
            XCTFail("Cancellation should interrupt the downstream operation")
        }
        await fulfillment(of: [transferred], timeout: 5)
        worker.cancel()
        do { try await worker.value; XCTFail("Expected CancellationError") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(trace.directories.count, 1)
        assertRemoved(trace.directories)
    }

    func testWithSnapshotCleansUpOnDownstreamErrorAndCancellation() async throws {
        let source = try fixture(payload(0x41))
        let trace = CloudSnapshotTrace()
        do {
            try await DocumentImporter.withSnapshot(url: source) { url in
                trace.recordDirectory(url.deletingLastPathComponent())
                throw CloudFixtureError.injected
            }
            XCTFail("Expected the downstream error")
        } catch {
            XCTAssertTrue(error is CloudFixtureError, "\(error)")
        }
        assertRemoved(trace.directories)
        let started = expectation(description: "Importer handed off the snapshot")
        let worker = Task.detached {
            try await DocumentImporter.withSnapshot(url: source) { url in
                trace.recordDirectory(url.deletingLastPathComponent())
                started.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await fulfillment(of: [started], timeout: 5)
        worker.cancel()
        do { try await worker.value; XCTFail("Expected CancellationError") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(trace.directories.count, 2)
        assertRemoved(trace.directories)
    }

    private func checkAtomicReplacement(sameContents: Bool) throws {
        let original = payload(0x61)
        let replacement = sameContents ? original : payload(0x62)
        let source = try fixture(original)
        let other = try fixture(replacement, name: "replacement")
        let before = try metadata(source)
        try restoreTimes(other, from: before)
        let trace = CloudSnapshotTrace()
        let snapshot = try FileSnapshotReader.read(source, hooks: hooks(trace, copy: { attempt, copied in
            if attempt == 1 && copied == self.blockSize {
                try self.checkPOSIX(Darwin.rename(other.path, source.path), operation: "atomic rename")
                let current = try self.metadata(source)
                XCTAssertNotEqual(current.st_ino, before.st_ino)
                XCTAssertEqual(self.mtime(current), self.mtime(before))
            }
        }))
        defer { snapshot.remove() }
        try assertSnapshot(snapshot, equals: replacement)
        XCTAssertEqual(trace.copyAttempts, [1, 2])
        XCTAssertEqual(trace.directories.count, 2)
        assertRemoved(trace.directories.filter { $0 != snapshot.directory })
        snapshot.remove()
        assertRemoved(trace.directories)
    }

    private func checkAsyncCopyCancellation(atEnd: Bool) async throws {
        let bytes = payload(0x41)
        let source = try fixture(bytes)
        let paused = expectation(description: "Real snapshot write reached cancellation boundary")
        let release = DispatchSemaphore(value: 0)
        let trace = CloudSnapshotTrace()
        let boundary = atEnd ? bytes.count : blockSize
        let worker = Task.detached { () throws -> Void in
            let snapshot = try await FileSnapshotReader.readAsync(source, hooks: self.hooks(trace, copy: { attempt, copied in
                if attempt == 1 && copied == boundary {
                    paused.fulfill()
                    guard release.wait(timeout: .now() + 10) == .success else {
                        throw CloudFixtureError.timeout
                    }
                }
            }))
            snapshot.remove()
            XCTFail("Cancelled copy must not transfer ownership")
        }
        defer { worker.cancel(); release.signal() }
        await fulfillment(of: [paused], timeout: 5)
        XCTAssertEqual(trace.directories.count, 1)
        if let directory = trace.directories.first {
            let partial = try metadata(directory.appendingPathComponent("snapshot"))
            XCTAssertEqual(Int(partial.st_size), boundary, "Cancellation follows a real disk write")
        }
        worker.cancel()
        release.signal()
        do { try await worker.value; XCTFail("Expected CancellationError") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(trace.copyAttempts, [1])
        assertRemoved(trace.directories)
    }

    private func hooks(
        _ trace: CloudSnapshotTrace,
        copy: ((Int, Int) throws -> Void)? = nil,
        validation: ((Int, Int) throws -> Void)? = nil
    ) -> FileSnapshotReader.Hooks {
        .init(afterCopyChunk: { attempt, bytes in
            trace.recordCopy(attempt, bytes)
            try copy?(attempt, bytes)
        }, afterValidationRead: { attempt, bytes in
            trace.recordValidation(attempt, bytes)
            try validation?(attempt, bytes)
        }, snapshotCreated: { trace.recordDirectory($0) })
    }

    private func payload(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: blockSize * 3 + 29)
    }

    private func fixture(_ bytes: Data, name: String = "synthetic-source.pdf") throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func overwrite(_ url: URL, with bytes: Data) throws {
        let before = try metadata(url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        let after = try metadata(url)
        XCTAssertEqual(before.st_ino, after.st_ino, "This fixture must edit in place")
        XCTAssertEqual(after.st_size, off_t(bytes.count))
    }

    private func changeXattr(_ url: URL) throws {
        let old = try metadata(url)
        for sequence in 0..<25 {
            let bytes = Data("synthetic metadata \(sequence)".utf8)
            let result = bytes.withUnsafeBytes {
                Darwin.setxattr(url.path, "com.askbase.cloud-import-test", $0.baseAddress, $0.count, 0, 0)
            }
            try checkPOSIX(result, operation: "setxattr")
            if ctime(try metadata(url)) != ctime(old) { return }
            usleep(1_000)
        }
        XCTFail("The filesystem did not expose a changed ctime after real xattr writes")
        throw CloudFixtureError.metadataDidNotChange
    }

    private func restoreTimes(_ url: URL, from info: stat) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        let values = [info.st_atimespec, info.st_mtimespec]
        try values.withUnsafeBufferPointer {
            try checkPOSIX(futimens(descriptor, $0.baseAddress), operation: "futimens")
        }
    }

    private func metadata(_ url: URL) throws -> stat {
        var info = stat()
        try checkPOSIX(lstat(url.path, &info), operation: "lstat")
        return info
    }

    private func mtime(_ info: stat) -> [Int] {
        [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
    }

    private func ctime(_ info: stat) -> [Int] {
        [info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec]
    }

    private func checkPOSIX(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"])
        }
    }

    private func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func assertSnapshot(
        _ snapshot: InputFileSnapshot, equals bytes: Data, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        // Avoid megabyte-sized failure logs; still compare every byte.
        XCTAssertTrue(try Data(contentsOf: snapshot.url) == bytes, "Snapshot bytes differ", file: file, line: line)
        XCTAssertEqual(snapshot.contentHash, sha256(bytes), file: file, line: line)
        XCTAssertEqual(snapshot.byteCount, bytes.count, file: file, line: line)
    }

    private func assertRemoved(_ directories: [URL], file: StaticString = #filePath, line: UInt = #line) {
        for directory in directories {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                           "Snapshot not removed: \(directory.lastPathComponent)", file: file, line: line)
        }
    }
}

private enum CloudFixtureError: Error {
    case injected, timeout, metadataDidNotChange
}

private final class CloudSnapshotTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [URL] = []
    private var copied: [(Int, Int)] = []
    private var validated: [(Int, Int)] = []

    func recordDirectory(_ url: URL) { lock.lock(); defer { lock.unlock() }; created.append(url) }
    func recordCopy(_ attempt: Int, _ bytes: Int) { lock.lock(); defer { lock.unlock() }; copied.append((attempt, bytes)) }
    func recordValidation(_ attempt: Int, _ bytes: Int) { lock.lock(); defer { lock.unlock() }; validated.append((attempt, bytes)) }
    var directories: [URL] { lock.lock(); defer { lock.unlock() }; return created }
    var copyAttempts: [Int] { lock.lock(); defer { lock.unlock() }; return Set(copied.map(\.0)).sorted() }
    var validationBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(grouping: validated, by: \.0).values.reduce(0) { total, events in
            total + (events.map(\.1).max() ?? 0)
        }
    }
}

/// Hold the real Foundation relinquish callback, including for .withoutChanges.
/// The operation queue remains free so NSFileCoordinator.cancel() can be tested
/// without a fake coordinator or a timing guess about whether IO already began.
private final class CloudHoldingPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let requested: XCTestExpectation
    private let lock = NSLock()
    private var reader: (@Sendable ((@Sendable () -> Void)?) -> Void)?
    private var released = false

    init(url: URL, requested: XCTestExpectation) {
        presentedItemURL = url
        self.requested = requested
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue.name = "AskBaseCloudImportTests.presenter"
        super.init()
    }

    func relinquishPresentedItem(toReader reader: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        lock.lock()
        let shouldRelease = released
        if !shouldRelease { self.reader = reader }
        lock.unlock()
        requested.fulfill()
        if shouldRelease { reader(nil) }
    }

    var isHoldingReader: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reader != nil && !released
    }

    func releaseReader() {
        lock.lock()
        released = true
        let held = reader
        reader = nil
        lock.unlock()
        held?(nil)
    }
}
