import Foundation
import Combine
import AskBaseCore
import Darwin

/// Owns only the supervisor. Service identity checks and child cleanup belong to
/// supervisor.py; the app never kills a process discovered by name or port.
@MainActor
final class LocalModelRuntime: ObservableObject {
    enum Ownership: String, Decodable {
        case managed, external, unavailable
        var label: String {
            switch self {
            case .managed: "由 AskBase 管理，退出时释放"
            case .external: "外部或共享服务，退出时保持运行"
            case .unavailable: "尚不可用"
            }
        }
    }
    enum Phase { case disabled, idle, starting, ready, stopping, stopped, failed }

    @Published private(set) var phase: Phase
    @Published private(set) var message: String
    @Published private(set) var embedding: Ownership = .unavailable
    @Published private(set) var ollama: Ownership = .unavailable
    @Published private(set) var details: [String] = []
    @Published var preloadMessage: String?

    let enabled: Bool
    private var worker: SupervisorProcess?
    private var eventTask: Task<Void, Never>?
    private var sawStopped = false
    private var stopRequested = false
    private var cleanupError: String?
    private var lastSupervisorError: String?
    private var exitError: String?
    private var managedOllamaURL: String?

    var isBusy: Bool { phase == .starting || phase == .stopping || (stopRequested && worker != nil) }
    var canRestart: Bool { enabled && worker == nil && (phase == .failed || phase == .stopped) }
    var ownershipSummary: String {
        "EmbeddingGemma 2：\(embedding.label)。Ollama：\(ollama.label)。"
    }

    init(enabled: Bool) {
        self.enabled = enabled
        phase = enabled ? .idle : .disabled
        message = enabled ? "本地模型随应用启动，退出时释放专用服务。"
            : "独立资料库模式：自动模型管理已关闭。"
    }

    func managesOllama(at url: String) -> Bool {
        phase == .ready && ollama == .managed && managedOllamaURL == url
    }

    /// Launch is asynchronous, but ownership of the worker is recorded before
    /// the first suspension, including when Quit races with Process.run().
    func start(settings: AppSettings, timeout: Duration = .seconds(300)) async {
        guard enabled, worker == nil, !Task.isCancelled else { return }
        let python = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AskBase/EmbeddingGemma2/.venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            phase = .failed
            message = "未找到 AskBase 专用模型运行时。资料库仍可打开；请先完成 EmbeddingGemma 2 本机安装，再重新启动模型。"
            details = ["所需 Python：\(python.path)"]
            return
        }
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("ModelRuntime/supervisor.py"),
              FileManager.default.isReadableFile(atPath: script.path) else {
            phase = .failed
            message = "应用中缺少模型启动组件（ModelRuntime/supervisor.py）。资料库仍可使用，请安装完整的 AskBase 应用。"
            return
        }
        do {
            _ = try LocalEndpoint.validate(settings.embeddingBaseURL)
            _ = try LocalEndpoint.validate(settings.ollamaBaseURL)
        } catch {
            phase = .failed
            message = error.localizedDescription
            return
        }
        sawStopped = false
        stopRequested = false
        cleanupError = nil
        lastSupervisorError = nil
        exitError = nil
        managedOllamaURL = nil
        embedding = .unavailable
        ollama = .unavailable
        details = []
        preloadMessage = nil
        phase = .starting
        message = "正在启动本地模型服务…资料库已经可以打开。"
        let process = SupervisorProcess(python: python, script: script, settings: settings)
        worker = process
        eventTask = Task { [weak self] in
            for await output in process.events {
                guard let self else { break }
                self.receive(output, ollamaURL: settings.ollamaBaseURL)
            }
        }
        process.start()
        let deadline = ContinuousClock.now + timeout
        while phase == .starting, !Task.isCancelled {
            if ContinuousClock.now >= deadline {
                message = "模型启动等待超时，正在清理本次启动的专用服务。资料库仍可使用。"
                requestStop()
                return
            }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
    }

    func stop(timeout: Duration = .seconds(60)) async throws {
        guard enabled else { return }
        if worker == nil {
            if let exitError { throw AskBaseError.modelUnavailable(exitError) }
            return
        }
        requestStop()
        let deadline = ContinuousClock.now + timeout
        while worker != nil {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                phase = .failed
                message = "等待模型释放超时，尚未确认专用服务已经停止。应用保持打开，可再次退出以继续等待。"
                throw AskBaseError.modelUnavailable(message)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let exitError { throw AskBaseError.modelUnavailable(exitError) }
    }

    private func requestStop() {
        guard let worker else { return }
        if !stopRequested {
            stopRequested = true
            phase = .stopping
            message = "正在释放 AskBase 专用模型服务…外部或共享服务会保持运行。"
            worker.requestStop()
        }
    }

    private func receive(_ output: SupervisorProcess.Output, ollamaURL: String) {
        switch output {
        case .event(let event):
            sawStopped = event.event == "stopped"
            switch event.event {
            case "status":
                if !stopRequested { message = event.message ?? "正在准备本地模型…" }
            case "ready":
                guard let embedding = event.embedding, let ollama = event.ollama else {
                    protocolFailure()
                    return
                }
                self.embedding = embedding
                self.ollama = ollama
                managedOllamaURL = ollama == .managed ? ollamaURL : nil
                details = Array((event.messages ?? []).prefix(8)).map { String($0.prefix(2000)) }
                guard !stopRequested else { return }
                phase = .ready
                message = embedding == .unavailable || ollama == .unavailable
                    ? "部分本地模型尚不可用，资料库可继续使用。"
                    : "本地模型服务已就绪。"
            case "error":
                let error = String((event.message ?? "模型监督器报告错误。").prefix(2000))
                lastSupervisorError = error
                if stopRequested { cleanupError = error }
                phase = .failed
                message = error
                details.append(error)
            case "stopped":
                if phase != .failed {
                    phase = .stopping
                    message = "模型服务已报告停止，正在确认监督器退出结果…"
                }
                // The helper emits this only after every owned child has
                // stopped. Still wait for EOF and a normal process exit.
            default: protocolFailure()
            }
        case .invalidOutput:
            protocolFailure()
        case .launchFailed:
            worker = nil
            phase = .failed
            message = "无法运行 AskBase 专用模型监督器。请检查本机运行时安装；资料库仍可使用。"
            // Process.run failed before any supervisor/children could start.
        case .exited(let status, let normally):
            worker = nil
            if !normally || !sawStopped {
                exitError = cleanupError ?? lastSupervisorError
                    ?? "模型监督器未确认清理成功（退出码 \(status)）。应用保持打开，不能确认专用服务已释放。"
                phase = .failed
                message = exitError!
            } else if status != 0 || lastSupervisorError != nil {
                // A startup error exits nonzero even when finally cleaned up
                // successfully. The final stopped event permits Quit in this
                // case; keep the original failure visible for diagnosis.
                exitError = nil
                phase = .failed
                message = (lastSupervisorError ?? "本地模型启动未完成（退出码 \(status)）。")
                    + " 本次专用服务已释放，可以正常退出。"
            } else if stopRequested {
                phase = .stopped
                message = "AskBase 专用模型服务已释放。外部或共享服务保持运行。"
            } else {
                phase = .failed
                message = "本地模型监督器已停止。资料库仍可使用，可在设置中重新启动模型。"
            }
        }
    }

    private func protocolFailure() {
        cleanupError = "模型监督器返回了无效事件，无法确认服务状态。"
        requestStop()
        phase = .failed
        message = cleanupError!
    }
}

/// Pipe IO and Process.run/waitUntilExit never execute on the main actor or
/// block Swift's cooperative executor. The control queue stays available while
/// the reader waits for stdout, so stop also works during slow model startup.
private final class SupervisorProcess: @unchecked Sendable {
    struct Event: Decodable {
        let event: String
        let message: String?
        let messages: [String]?
        let embedding: LocalModelRuntime.Ownership?
        let ollama: LocalModelRuntime.Ownership?
    }
    enum Output {
        case event(Event), invalidOutput, launchFailed
        case exited(Int32, normally: Bool)
    }
    let events: AsyncStream<Output>
    private let continuation: AsyncStream<Output>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let control = DispatchQueue(label: "AskBase.model-supervisor.control", qos: .utility)
    private var stopSent = false

    init(python: URL, script: URL, settings: AppSettings) {
        let stream = AsyncStream<Output>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        process.executableURL = python
        process.arguments = [
            script.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--embedding-url", settings.embeddingBaseURL, "--ollama-url", settings.ollamaBaseURL,
        ]
        process.standardInput = input
        process.standardOutput = output
        // Diagnostic output is intentionally not copied into app logs or UI.
        // User-facing diagnostics belong to the supervisor's JSON protocol.
        process.standardError = FileHandle.nullDevice
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "PYTHONUNBUFFERED": "1",
        ]
    }

    func start() {
        control.async { [self] in
            do {
                try process.run()
                try? input.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
                DispatchQueue(label: "AskBase.model-supervisor.stdout", qos: .utility).async { [self] in
                    readToEnd()
                }
            } catch {
                try? input.fileHandleForReading.close()
                try? input.fileHandleForWriting.close()
                try? output.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
                continuation.yield(.launchFailed)
                continuation.finish()
            }
        }
    }

    func requestStop() {
        control.async { [self] in
            guard !stopSent else { return }
            stopSent = true
            if process.isRunning {
                try? input.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
            }
            // EOF is also part of the contract and covers a failed pipe write.
            try? input.fileHandleForWriting.close()
        }
    }

    private func readToEnd() {
        var buffer = Data()
        var valid = true
        do {
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                // FileHandle.read(upToCount:) can wait for the requested byte
                // count or EOF on macOS pipes. POSIX read delivers each small
                // JSON event immediately while the supervisor stays alive.
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if count == 0 { break }
                let chunk = Data(bytes.prefix(count))
                guard valid else { continue } // Drain without retaining invalid output.
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard line.count <= 65_536, let event = try? JSONDecoder().decode(Event.self, from: line) else {
                        valid = false
                        continuation.yield(.invalidOutput)
                        break
                    }
                    continuation.yield(.event(event))
                }
                if buffer.count > 65_536 {
                    valid = false
                    continuation.yield(.invalidOutput)
                    buffer.removeAll()
                }
            }
            if valid, !buffer.isEmpty { continuation.yield(.invalidOutput) }
        } catch {
            continuation.yield(.invalidOutput)
        }
        try? output.fileHandleForReading.close()
        process.waitUntilExit()
        continuation.yield(.exited(process.terminationStatus, normally: process.terminationReason == .exit))
        continuation.finish()
    }
}
