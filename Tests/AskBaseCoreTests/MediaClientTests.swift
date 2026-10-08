import Foundation
import XCTest
@testable import AskBaseCore

private final class MediaHTTPStub: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var mediaReady = true
    static var responseSignature = "media-v1"
    static var responseType = "document"
    static var responseVector = [Float(1)] + Array(repeating: Float(0), count: 767)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        var payload: [String: Any] = [
            "model": "embeddinggemma-2", "dimensions": 768, "encoder_signature": "text-v1",
        ]
        if request.url?.path == "/health" {
            payload["status"] = "ok"
            payload["modalities"] = Self.mediaReady ? ["text", "image", "audio", "video"] : ["text"]
            if Self.mediaReady { payload["media_encoder_signature"] = "media-v1" }
        } else {
            payload["input_type"] = Self.responseType
            payload["media_encoder_signature"] = Self.responseSignature
            payload["data"] = [["index": 0, "embedding": Self.responseVector]]
        }
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

final class MediaClientTests: XCTestCase {
    override func setUp() {
        MediaHTTPStub.lock.lock()
        MediaHTTPStub.requests = []; MediaHTTPStub.mediaReady = true
        MediaHTTPStub.responseSignature = "media-v1"; MediaHTTPStub.responseType = "document"
        MediaHTTPStub.responseVector = [1] + Array(repeating: 0, count: 767)
        MediaHTTPStub.lock.unlock()
    }
    private func client() -> EmbeddingClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaHTTPStub.self]
        return EmbeddingClient(http: LocalHTTPClient(configuration: configuration))
    }
    private var input: MediaEmbeddingInput { MediaEmbeddingInput(kind: .image, images: [Data("PRIVATE_IMAGE_BYTES".utf8)]) }
    private func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    func testMediaBytesSentOnlyAfterCapabilityCheckAndBothSignaturesAreReturned() async throws {
        let response = try await client().embedMedia(input, inputType: "document")
        XCTAssertEqual(response.signature, "text-v1"); XCTAssertEqual(response.mediaSignature, "media-v1")
        XCTAssertEqual(MediaHTTPStub.requests.map { $0.url!.path }, ["/health", "/v1/media/embeddings"])
        let request = try XCTUnwrap(MediaHTTPStub.requests.last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body(request)) as? [String: Any])
        let media = try XCTUnwrap(payload["input"] as? [String: Any])
        XCTAssertEqual(media["images"] as? [String], input.images?.map { $0.base64EncodedString() })
        XCTAssertEqual(media["kind"] as? String, "image")
        XCTAssertNil(media["path"]); XCTAssertNil(media["url"])
    }

    func testTextOnlyServiceNeverReceivesPrivateMedia() async throws {
        MediaHTTPStub.mediaReady = false
        do { _ = try await client().embedMedia(input, inputType: "document"); XCTFail("Media must require a media-capable service") }
        catch { XCTAssertTrue(error.localizedDescription.contains("尚未启用")) }
        XCTAssertEqual(MediaHTTPStub.requests.map { $0.url!.path }, ["/health"])
        XCTAssertTrue(body(MediaHTTPStub.requests[0]).isEmpty)
    }

    func testChangedMediaSignatureAndWrongInputTypeAreRejected() async throws {
        MediaHTTPStub.responseSignature = "media-v2"
        do { _ = try await client().embedMedia(input, inputType: "document"); XCTFail("Signature drift must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("编码响应无效")) }
        MediaHTTPStub.responseSignature = "media-v1"
        MediaHTTPStub.responseType = "query"
        do { _ = try await client().embedMedia(input, inputType: "document"); XCTFail("Wrong prefix must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("编码响应无效")) }
    }

    func testMalformedMediaVectorsAndFrameTimestampsAreRejected() async throws {
        MediaHTTPStub.responseVector = [0, 0]
        do { _ = try await client().embedMedia(input, inputType: "document"); XCTFail("Malformed vector must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("编码响应无效")) }
        let priorRequests = MediaHTTPStub.requests.count
        for timestamps in [[1, 1], [2, 1], [-1, 0], [0, Double.infinity], [0]] {
            let malformed = MediaEmbeddingInput(kind: .video, images: [Data([1]), Data([2])], timestamps: timestamps)
            do { _ = try await client().embedMedia(malformed, inputType: "query"); XCTFail("Bad frame alignment must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("有效")) }
        }
        XCTAssertEqual(MediaHTTPStub.requests.count, priorRequests, "Malformed media should fail before any HTTP request")
    }

    func testOpaqueMediaCannotBeSentDirectlyToTextAnswerClient() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaHTTPStub.self]
        let answerer = OllamaClient(http: LocalHTTPClient(configuration: configuration))
        let source = SearchResult(id: "chunk", documentID: "document", knowledgeBaseID: "base",
                                  title: "录音", text: "This is a label, not a transcript", score: 1,
                                  media: MediaReference(kind: .audio, startSeconds: 0, endSeconds: 10))
        do {
            _ = try await answerer.answer(model: "local", question: "what was said?", sources: [source], history: [])
            XCTFail("No public API may treat media metadata as a transcript")
        } catch { XCTAssertTrue(error.localizedDescription.contains("未转写")) }
        XCTAssertTrue(MediaHTTPStub.requests.isEmpty)
    }
}
