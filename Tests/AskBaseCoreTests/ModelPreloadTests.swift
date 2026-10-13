import Foundation
import XCTest
@testable import AskBaseCore

private final class PreloadProtocol: URLProtocol {
    struct Request {
        let path: String
        let method: String?
        let body: [String: Any]
    }
    static let lock = NSLock()
    static var requests: [Request] = []
    static var metadata: [String: Any] = [:]
    static var response: [String: Any] = [:]
    static var heldPath: String?
    static var stoppedPaths: Set<String> = []
    static var generation = UUID()
    private var generation: UUID?
    static var captured: [Request] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        let path = request.url!.path
        let (payload, held) = Self.lock.withLock {
            generation = Self.generation
            Self.requests.append(Request(path: path, method: request.httpMethod,
                                         body: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]))
            let payload = path == "/api/show" ? Self.metadata : Self.response
            return (payload, path == Self.heldPath)
        }
        if held { return }
        let body = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                             httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.withLock {
            if generation == Self.generation, let path = request.url?.path {
                Self.stoppedPaths.insert(path)
            }
        }
    }
}

final class ModelPreloadTests: XCTestCase {
    override func setUp() {
        PreloadProtocol.lock.withLock {
            PreloadProtocol.requests = []
            PreloadProtocol.metadata = [
                "details": ["format": "gguf"],
                "model_info": ["general.architecture": "gemma"],
                "capabilities": ["completion"],
            ]
            PreloadProtocol.response = ["done": true, "response": ""]
            PreloadProtocol.heldPath = nil
            PreloadProtocol.stoppedPaths = []
            PreloadProtocol.generation = UUID()
        }
    }

    private func client(base: String = "http://127.0.0.1:11434") -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreloadProtocol.self]
        return OllamaClient(base: base, http: LocalHTTPClient(configuration: configuration))
    }

    func testPreloadChecksLocalMetadataThenSendsOnlyEmptyPrompt() async throws {
        try await client().preload(model: "selected-local:latest")
        let requests = PreloadProtocol.captured
        XCTAssertEqual(requests.map(\.path), ["/api/show", "/api/generate"])
        XCTAssertEqual(requests.last?.method, "POST")
        let body = try XCTUnwrap(requests.last?.body)
        XCTAssertEqual(Set(body.keys), ["model", "prompt", "stream", "keep_alive"])
        XCTAssertEqual(body["model"] as? String, "selected-local:latest")
        XCTAssertEqual(body["prompt"] as? String, "")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? Int, -1)
    }

    func testCloudAliasCannotBePreloaded() async {
        PreloadProtocol.lock.withLock { PreloadProtocol.metadata["remote_host"] = "https://ollama.com" }
        do {
            try await client().preload(model: "innocent-alias")
            XCTFail("A loopback endpoint does not establish local model ownership")
        } catch { XCTAssertTrue(error.localizedDescription.contains("无法确认")) }
        XCTAssertEqual(PreloadProtocol.captured.map(\.path), ["/api/show"])
    }

    func testUnknownMetadataCannotBePreloaded() async {
        PreloadProtocol.lock.withLock { PreloadProtocol.metadata = ["details": ["format": "gguf"]] }
        do {
            try await client().preload(model: "unknown")
            XCTFail("Incomplete locality metadata must fail closed")
        } catch {}
        XCTAssertEqual(PreloadProtocol.captured.map(\.path), ["/api/show"])
    }

    func testRemoteEndpointCannotReceiveEvenMetadataRequest() async {
        do {
            try await client(base: "https://example.com").preload(model: "local")
            XCTFail("Remote endpoint must be rejected before transport")
        } catch {}
        XCTAssertTrue(PreloadProtocol.captured.isEmpty)
    }

    func testEmptyModelDoesNotMakeARequest() async {
        do {
            try await client().preload(model: " \n ")
            XCTFail("No model was selected")
        } catch {}
        XCTAssertTrue(PreloadProtocol.captured.isEmpty)
    }

    func testUnfinishedLoadIsNotReportedAsSuccessful() async {
        PreloadProtocol.lock.withLock { PreloadProtocol.response = ["done": false, "response": ""] }
        do {
            try await client().preload(model: "local")
            XCTFail("Warm load must finish")
        } catch {}
    }

    func testGeneratedTextIsNotAcceptedAsAPreload() async {
        PreloadProtocol.lock.withLock { PreloadProtocol.response = ["done": true, "response": "unexpected generation"] }
        do {
            try await client().preload(model: "local")
            XCTFail("An empty prompt preload should not generate text")
        } catch {}
    }

    func testCancellationDuringLocalCheckNeverStartsLoad() async throws {
        try await assertCancellation(holding: "/api/show", expectedPaths: ["/api/show"])
    }

    func testCancellationDuringLoadCancelsTheUnderlyingRequest() async throws {
        try await assertCancellation(holding: "/api/generate", expectedPaths: ["/api/show", "/api/generate"])
    }

    func testAnswerLeavesRetentionToTheServicesOwnershipPolicy() async throws {
        PreloadProtocol.lock.withLock {
            PreloadProtocol.response = ["done": true, "message": ["content": "资料显示有一个测试项。[1]"]]
        }
        let source = SearchResult(id: "chunk", documentID: "doc", knowledgeBaseID: "test",
                                  title: "Synthetic", text: "只有一个测试项。", score: 1)
        _ = try await client().answer(model: "local", question: "测试项数量？", sources: [source], history: [])
        XCTAssertEqual(PreloadProtocol.captured.last?.path, "/api/chat")
        XCTAssertNil(PreloadProtocol.captured.last?.body["keep_alive"])
    }

    private func assertCancellation(holding path: String, expectedPaths: [String]) async throws {
        PreloadProtocol.lock.withLock { PreloadProtocol.heldPath = path }
        let client = client()
        let task = Task { try await client.preload(model: "local") }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !PreloadProtocol.captured.contains(where: { $0.path == path }) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Offline request did not reach the test transport")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled preload must not succeed")
        } catch { XCTAssertTrue(error is CancellationError) }
        // URLSession can resume the cancelled task before delivering the
        // protocol's stopLoading callback on its own queue (notably macOS 15).
        // Wait for this exact request, without accepting an earlier request's stop.
        let stopDeadline = ContinuousClock.now + .seconds(3)
        while !PreloadProtocol.lock.withLock({ PreloadProtocol.stoppedPaths.contains(path) }) {
            guard ContinuousClock.now < stopDeadline else {
                XCTFail("Cancelled transport did not receive stopLoading for \(path)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(PreloadProtocol.captured.map(\.path), expectedPaths)
    }
}
