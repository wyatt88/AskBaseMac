import Foundation
import XCTest
@testable import AskBaseCore

private final class ModelStubProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var show: [String: Any] = [:]
    static var tags: [[String: Any]] = []
    static var answer = "资料显示截止日为 10 月 18 日。[1]"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let path = request.url!.path
        let payload: [String: Any]
        if path == "/api/show" { payload = Self.show }
        else if path == "/api/tags" { payload = ["models": Self.tags] }
        else { payload = ["message": ["content": Self.answer], "done": true] }
        Self.lock.unlock()
        let data = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                                                             httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ModelClientTests: XCTestCase {
    override func setUp() {
        ModelStubProtocol.lock.lock()
        ModelStubProtocol.requests = []
        ModelStubProtocol.show = [
            "details": ["format": "safetensors"],
            "model_info": ["general.architecture": "gemma4"],
            "capabilities": ["completion"],
        ]
        ModelStubProtocol.tags = []
        ModelStubProtocol.answer = "资料显示截止日为 10 月 18 日。[1]"
        ModelStubProtocol.lock.unlock()
    }
    private func client() -> OllamaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelStubProtocol.self]
        return OllamaClient(http: LocalHTTPClient(configuration: configuration))
    }
    private var source: SearchResult {
        SearchResult(id: "chunk", documentID: "document", knowledgeBaseID: "kb", title: "Synthetic",
                     text: "LOCAL_PRIVATE_FIXTURE_OnlyForThisTest", score: 0.8)
    }
    func testCloudAliasIsRejectedBeforePrivateTextIsSent() async throws {
        ModelStubProtocol.show["remote_model"] = "remote-large-model"
        ModelStubProtocol.show["remote_host"] = "https://ollama.com"
        do {
            _ = try await client().answer(model: "innocent-alias", question: "LOCAL_PRIVATE_QUESTION",
                                           sources: [source], history: [])
            XCTFail("Cloud alias must be rejected even without cloud in its name")
        } catch { XCTAssertTrue(error.localizedDescription.contains("无法确认")) }
        XCTAssertEqual(ModelStubProtocol.requests.map { $0.url!.path }, ["/api/show"])
        for request in ModelStubProtocol.requests {
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertFalse(body.contains("LOCAL_PRIVATE"))
        }
    }
    func testUnknownModelMetadataFailsClosed() async throws {
        ModelStubProtocol.show = ["details": ["format": "gguf"]]
        do {
            _ = try await client().answer(model: "unknown", question: "private", sources: [source], history: [])
            XCTFail("Incomplete model metadata must be rejected")
        } catch {}
        XCTAssertEqual(ModelStubProtocol.requests.map { $0.url!.path }, ["/api/show"])
    }
    func testLocalModelIsCheckedBeforeGenerationAndBadCitationFails() async throws {
        ModelStubProtocol.answer = "无法核实的说法。[9]"
        do {
            _ = try await client().answer(model: "local", question: "question", sources: [source], history: [])
            XCTFail("Invalid citation must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不存在的来源编号")) }
        XCTAssertEqual(ModelStubProtocol.requests.map { $0.url!.path }, ["/api/show", "/api/chat"])
    }
    func testModelPickerFiltersCloudAndEmbeddingOnlyEntries() async throws {
        ModelStubProtocol.tags = [
            ["name": "local-chat", "size": 100, "details": ["format": "gguf"], "capabilities": ["completion"]],
            ["name": "remote-alias", "size": 100, "details": ["format": "gguf"], "remote_model": "x"],
            ["name": "only-embeddings", "size": 100, "details": ["format": "gguf"], "capabilities": ["embedding"]],
            ["name": "unknown", "size": 100],
        ]
        let models = try await client().models()
        XCTAssertEqual(models, ["local-chat"])
    }
    func testFactualAnswerWithoutCitationIsRejected() async throws {
        ModelStubProtocol.answer = "截止日是 10 月 18 日。"
        do {
            _ = try await client().answer(model: "local", question: "question", sources: [source], history: [])
            XCTFail("An uncited factual answer must not be saved")
        } catch { XCTAssertTrue(error.localizedDescription.contains("没有附上有效来源")) }
    }
    func testOverflowingCitationIsRejectedEvenAlongsideAValidCitation() async throws {
        ModelStubProtocol.answer = "一条说法。[1] 另一条说法。[9999999999999999999999999999999999]"
        do {
            _ = try await client().answer(model: "local", question: "question", sources: [source], history: [])
            XCTFail("An overflowing citation must not evade source validation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不存在的来源编号")) }
    }
    func testNoncanonicalCitationCannotSubstituteForARealSource() async throws {
        for text in ["说法。[１]", "说法。[1] 另一条说法。[１]", "说法。[01]", "说法。[0]"] {
            ModelStubProtocol.answer = text
            do {
                _ = try await client().answer(model: "local", question: "question", sources: [source], history: [])
                XCTFail("Noncanonical citation must fail: \(text)")
            } catch { XCTAssertTrue(error.localizedDescription.contains("不存在的来源编号")) }
        }
    }
    func testExactInsufficientEvidenceRefusalCanOmitCitation() async throws {
        ModelStubProtocol.answer = "资料中没有足够信息。"
        let answer = try await client().answer(model: "local", question: "question", sources: [source], history: [])
        XCTAssertEqual(answer, "资料中没有足够信息。")
    }
    func testMalformedRemoteMetadataCannotPassAsLocal() async throws {
        ModelStubProtocol.show["remote_host"] = 42
        do {
            _ = try await client().answer(model: "local", question: "private", sources: [source], history: [])
            XCTFail("Malformed remote metadata must fail closed")
        } catch {}
        XCTAssertEqual(ModelStubProtocol.requests.map { $0.url!.path }, ["/api/show"])
    }
}
