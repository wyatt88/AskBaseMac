import Foundation

public struct KnowledgeBase: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
}

public enum DocumentStatus: String, Codable, Sendable {
    case indexing, ready, failed
    public var label: String {
        switch self { case .indexing: "正在索引"; case .ready: "可检索"; case .failed: "需处理" }
    }
}

public struct LibraryDocument: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var knowledgeBaseID: String
    public var title: String
    public var fileName: String
    public var relativePath: String
    public var contentHash: String
    public var status: DocumentStatus
    public var errorMessage: String?
    public var chunkCount: Int
    public var byteCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var isFavorite: Bool
    public var tags: [String]
    public var media: MediaReference?
    public init(id: String = UUID().uuidString, knowledgeBaseID: String, title: String,
                fileName: String, relativePath: String, contentHash: String,
                status: DocumentStatus = .indexing, errorMessage: String? = nil,
                chunkCount: Int = 0, byteCount: Int = 0, createdAt: Date = Date(),
                updatedAt: Date = Date(), isFavorite: Bool = false, tags: [String] = [],
                media: MediaReference? = nil) {
        self.id = id; self.knowledgeBaseID = knowledgeBaseID; self.title = title
        self.fileName = fileName; self.relativePath = relativePath; self.contentHash = contentHash
        self.status = status; self.errorMessage = errorMessage; self.chunkCount = chunkCount
        self.byteCount = byteCount; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.isFavorite = isFavorite; self.tags = tags
        self.media = media
    }
}

public struct DocumentChunk: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var documentID: String
    public var knowledgeBaseID: String
    public var ordinal: Int
    public var page: Int?
    public var text: String
    public var embedding: [Float]
    public var encoderSignature: String
    public var dimensions: Int
    public var media: MediaReference?
    public init(id: String = UUID().uuidString, documentID: String, knowledgeBaseID: String,
                ordinal: Int, page: Int? = nil, text: String, embedding: [Float] = [],
                encoderSignature: String = "", dimensions: Int = 768, media: MediaReference? = nil) {
        self.id = id; self.documentID = documentID; self.knowledgeBaseID = knowledgeBaseID
        self.ordinal = ordinal; self.page = page; self.text = text; self.embedding = embedding
        self.encoderSignature = encoderSignature; self.dimensions = dimensions
        self.media = media
    }
}

public struct SearchResult: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var documentID: String
    public var knowledgeBaseID: String
    public var title: String
    public var text: String
    public var page: Int?
    public var score: Double
    public var media: MediaReference?
    public init(id: String, documentID: String, knowledgeBaseID: String, title: String,
                text: String, page: Int? = nil, score: Double, media: MediaReference? = nil) {
        self.id = id; self.documentID = documentID; self.knowledgeBaseID = knowledgeBaseID
        self.title = title; self.text = text; self.page = page; self.score = score
        self.media = media
    }
    public var sourceLabel: String {
        if let media { return "\(title) · \(media.positionLabel)" }
        return page.map { "\(title) · 第 \($0) 页" } ?? title
    }
    public var hasReadableEvidence: Bool { media == nil || media?.textSource != nil }
}

public struct LibraryNote: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var knowledgeBaseID: String
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: String = UUID().uuidString, knowledgeBaseID: String, title: String,
                body: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.knowledgeBaseID = knowledgeBaseID; self.title = title; self.body = body
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var knowledgeBaseID: String
    public var title: String
    public var createdAt: Date
    public init(id: String = UUID().uuidString, knowledgeBaseID: String, title: String, createdAt: Date = Date()) {
        self.id = id; self.knowledgeBaseID = knowledgeBaseID; self.title = title; self.createdAt = createdAt
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var conversationID: String
    public var role: String
    public var content: String
    public var sources: [SearchResult]
    public var createdAt: Date
    public init(id: String = UUID().uuidString, conversationID: String, role: String,
                content: String, sources: [SearchResult] = [], createdAt: Date = Date()) {
        self.id = id; self.conversationID = conversationID; self.role = role
        self.content = content; self.sources = sources; self.createdAt = createdAt
    }
}

public struct LibrarySnapshot: Sendable {
    public var knowledgeBases: [KnowledgeBase]
    public var documents: [LibraryDocument]
    public var notes: [LibraryNote]
    public var conversations: [Conversation]
    public init(knowledgeBases: [KnowledgeBase], documents: [LibraryDocument],
                notes: [LibraryNote], conversations: [Conversation]) {
        self.knowledgeBases = knowledgeBases; self.documents = documents
        self.notes = notes; self.conversations = conversations
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var embeddingBaseURL: String
    public var ollamaBaseURL: String
    public var chatModel: String
    public var topK: Int
    public init(embeddingBaseURL: String = "http://127.0.0.1:8871",
                ollamaBaseURL: String = "http://127.0.0.1:11434",
                chatModel: String = "", topK: Int = 6) {
        self.embeddingBaseURL = embeddingBaseURL; self.ollamaBaseURL = ollamaBaseURL
        self.chatModel = chatModel; self.topK = topK
    }
}

public struct ModelStatus: Sendable {
    public var embeddingAvailable: Bool
    public var embeddingDetail: String
    public var embeddingModalities: [String]
    public var chatAvailable: Bool
    public var chatModels: [String]
    public var chatDetail: String
    public init(embeddingAvailable: Bool = false, embeddingDetail: String = "尚未检查",
                chatAvailable: Bool = false, chatModels: [String] = [], chatDetail: String = "尚未检查",
                embeddingModalities: [String] = []) {
        self.embeddingAvailable = embeddingAvailable; self.embeddingDetail = embeddingDetail
        self.chatAvailable = chatAvailable; self.chatModels = chatModels; self.chatDetail = chatDetail
        self.embeddingModalities = embeddingModalities
    }
}

public struct ImportReport: Sendable {
    public var imported: [LibraryDocument] = []
    public var skipped: [String] = []
    public var failures: [String] = []
    public init() {}
    public var summary: String {
        "已索引 \(imported.count) 份 · 已跳过 \(skipped.count) 份 · 需处理 \(failures.count) 份"
    }
}

public struct ParsedPage: Equatable, Sendable {
    public var page: Int?
    public var text: String
    public init(page: Int? = nil, text: String) { self.page = page; self.text = text }
}

public struct PreparedDocument: Sendable {
    public var document: LibraryDocument
    public var chunks: [DocumentChunk]
    public init(document: LibraryDocument, chunks: [DocumentChunk]) {
        self.document = document; self.chunks = chunks
    }
}

public enum AskBaseError: LocalizedError {
    case invalidInput(String), storage(String), importFailed(String), modelUnavailable(String)
    case incompatibleIndex(String), network(String)
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let s), .storage(let s), .importFailed(let s), .modelUnavailable(let s),
             .incompatibleIndex(let s), .network(let s): s
        }
    }
}
