import CryptoKit
import Darwin
import Foundation

struct InputFileSnapshot {
    let directory: URL
    let url: URL
    let contentHash: String
    let byteCount: Int

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Acquire cloud-provider contents before opening them, then release the source
/// as soon as a verified private copy exists. Parsing and inference use that copy.
enum FileSnapshotReader {
    /// Per-call fault injection for deterministic filesystem regression tests.
    /// Production callers use the empty hooks; no process-global test state.
    struct Hooks {
        var afterCopyChunk: ((Int, Int) throws -> Void)?
        var afterValidationRead: ((Int, Int) throws -> Void)?
        var snapshotCreated: ((URL) throws -> Void)?
    }

    private enum ReadFailure: Error { case changed }
    private static let chunkSize = 1_048_576
    private static let attempts = 3

    static func read(_ url: URL, hooks: Hooks = .init()) throws -> InputFileSnapshot {
        try read(url, control: ReadControl(), hooks: hooks, checkTask: { try Task.checkCancellation() })
    }

    /// Waiting for iCloud / File Provider must not occupy the library actor.
    /// Cancellation also interrupts a coordinator still waiting for a download.
    static func readAsync(_ url: URL, hooks: Hooks = .init()) async throws -> InputFileSnapshot {
        let control = ReadControl()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let snapshot: InputFileSnapshot = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try read(url, control: control, hooks: hooks, checkTask: {})
                    })
                }
            }
            do {
                try Task.checkCancellation()
                return snapshot
            } catch {
                snapshot.remove()
                throw error
            }
        } onCancel: {
            control.cancel()
        }
    }

    private static func read(
        _ url: URL, control: ReadControl, hooks: Hooks, checkTask: () throws -> Void
    ) throws -> InputFileSnapshot {
        func checkCancellation() throws {
            try checkTask()
            try control.checkCancellation()
        }
        try checkCancellation()
        guard url.isFileURL else { throw AskBaseError.importFailed("只能导入本机文件。") }
        // Do not ask a file coordinator to resolve links, devices or FIFOs.
        // Cloud placeholders may be empty here; inspect size only after access.
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFREG {
            throw AskBaseError.importFailed("只能导入普通文件，不支持符号链接、目录、设备或管道。")
        }
        for attempt in 1...attempts {
            try checkCancellation()
            let coordinator = NSFileCoordinator(filePresenter: nil)
            try control.register(coordinator)
            defer { control.unregister(coordinator) }
            var coordinationError: NSError?
            var result: Result<InputFileSnapshot, Error>?
            // Content coordination waits for provider materialization. Using
            // metadata-only access here would permit reading a dataless file.
            // withoutChanges imports the saved version without asking another
            // application to save its unsaved edits.
            coordinator.coordinate(readingItemAt: url, options: .withoutChanges,
                                   error: &coordinationError) { readableURL in
                result = Result {
                    try checkCancellation()
                    return try copy(readableURL, attempt: attempt, hooks: hooks,
                                    checkCancellation: checkCancellation)
                }
            }
            do {
                try checkCancellation()
            } catch {
                if case .success(let snapshot) = result { snapshot.remove() }
                throw error
            }
            if let coordinationError {
                if case .success(let snapshot) = result { snapshot.remove() }
                throw AskBaseError.importFailed(
                    "无法准备文件：\(coordinationError.localizedDescription)。若文件来自 iCloud 或 OneDrive，" +
                    "请确认云盘已登录并联网，或在 Finder 中选择“立即下载”／“始终保留在此设备上”后重试。"
                )
            }
            guard let result else { throw AskBaseError.importFailed("系统未提供可读取的文件，请重新选择后导入。") }
            do {
                return try result.get()
            } catch ReadFailure.changed {
                // A synchronizer may replace the placeholder or finish a write
                // during access. Reacquire the current URL, never reuse a partial
                // snapshot or the descriptor for an obsolete revision.
                if attempt == attempts {
                    throw AskBaseError.importFailed(
                        "文件仍在同步或内容持续变化，自动尝试 3 次后仍未取得完整副本。" +
                        "请在 Finder 中下载并等待同步完成，或保存文件后重新导入。"
                    )
                }
                // Give an uncoordinated provider/write a short chance to settle;
                // check cancellation during the wait rather than freezing Stop.
                for _ in 0..<(attempt * 8) {
                    try checkCancellation()
                    Thread.sleep(forTimeInterval: 0.025)
                }
            }
        }
        throw AskBaseError.importFailed("未能取得文件副本。")
    }

    private static func copy(
        _ url: URL, attempt: Int, hooks: Hooks, checkCancellation: () throws -> Void
    ) throws -> InputFileSnapshot {
        try checkCancellation()
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw ReadFailure.changed }
            throw AskBaseError.importFailed("无法打开文件；请检查下载状态、访问权限，且不要选择符号链接。")
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw AskBaseError.importFailed("只能导入普通文件，不支持目录、设备或管道。")
        }
        guard before.st_size > 0, let expectedSize = Int(exactly: before.st_size) else {
            throw AskBaseError.importFailed("文件为空，没有可索引的内容；若来自云盘，请先确认下载完成。")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskBase-Import-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        try hooks.snapshotCreated?(directory)
        let destination = directory.appendingPathComponent("snapshot")
        let outputFD = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard outputFD >= 0 else { throw AskBaseError.importFailed("无法创建导入暂存文件。") }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var hasher = SHA256()
        var byteCount = 0
        // Read the original extent. An uncoordinated writer continuously
        // appending must not turn this into an unbounded read-until-EOF loop.
        while byteCount < expectedSize {
            try checkCancellation()
            guard let part = try input.read(upToCount: min(chunkSize, expectedSize - byteCount)),
                  !part.isEmpty else { throw ReadFailure.changed }
            try output.write(contentsOf: part)
            hasher.update(data: part)
            byteCount += part.count
            try hooks.afterCopyChunk?(attempt, byteCount)
        }
        try output.synchronize()
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == byteCount,
              sameFile(at: url, as: after) else { throw ReadFailure.changed }
        let digest = hasher.finalize()
        if !sameModificationTime(before, after) || !sameChangeTime(before, after) {
            // ctime includes tags, attributes and provider hydration, not just
            // bytes. Verify a second complete read instead of rejecting benign
            // metadata churn. This also catches same-size edits with a restored
            // mtime. Hashing, parsing and the managed original stay aligned.
            try input.seek(toOffset: 0)
            var verifier = SHA256()
            var verified = 0
            while verified < byteCount {
                try checkCancellation()
                guard let part = try input.read(upToCount: min(chunkSize, byteCount - verified)),
                      !part.isEmpty else { throw ReadFailure.changed }
                verifier.update(data: part)
                verified += part.count
                try hooks.afterValidationRead?(attempt, verified)
            }
            var final = stat()
            // The verification pass itself must be stable. A writer that
            // restores mtime can otherwise reproduce the same torn two-pass
            // read; new ctime churn here requires a fresh bounded attempt.
            guard fstat(descriptor, &final) == 0, final.st_size == byteCount,
                  sameModificationTime(after, final), sameChangeTime(after, final),
                  sameFile(at: url, as: final),
                  verifier.finalize() == digest else { throw ReadFailure.changed }
        }
        try checkCancellation()
        completed = true
        return InputFileSnapshot(directory: directory, url: destination,
                                 contentHash: digest.map { String(format: "%02x", $0) }.joined(),
                                 byteCount: byteCount)
    }

    private static func sameFile(at url: URL, as descriptor: stat) -> Bool {
        var current = stat()
        return lstat(url.path, &current) == 0 && (current.st_mode & S_IFMT) == S_IFREG
            && current.st_dev == descriptor.st_dev && current.st_ino == descriptor.st_ino
    }

    private static func sameModificationTime(_ a: stat, _ b: stat) -> Bool {
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }

    private static func sameChangeTime(_ a: stat, _ b: stat) -> Bool {
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private final class ReadControl: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var coordinator: NSFileCoordinator?

        func checkCancellation() throws {
            lock.lock()
            let stopped = cancelled
            lock.unlock()
            if stopped { throw CancellationError() }
        }

        func register(_ value: NSFileCoordinator) throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            coordinator = value
        }

        func unregister(_ value: NSFileCoordinator) {
            lock.lock()
            if coordinator === value { coordinator = nil }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let active = coordinator
            lock.unlock()
            // Foundation explicitly permits cancel() from any thread.
            active?.cancel()
        }
    }
}
