import Foundation

public actor KnowledgeEngine {
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AskBaseMac", isDirectory: true)
    }
    public nonisolated let root: URL
    private let store: LibraryStore
    private let embeddingOverride: (any EmbeddingProviding)?
    private let chatOverride: (any ChatProviding)?
    private var importingBases: Set<String> = []
    private var reindexingDocuments: Set<String> = []
    private var answeringConversations: Set<String> = []

    public init(root: URL = KnowledgeEngine.defaultRoot, embeddingClient: (any EmbeddingProviding)? = nil,
                chatClient: (any ChatProviding)? = nil) throws {
        let store = try LibraryStore(root: root)
        self.root = store.root
        self.store = store
        self.embeddingOverride = embeddingClient
        self.chatOverride = chatClient
        try store.recoverInterruptedImports()
        if try store.snapshot().knowledgeBases.isEmpty {
            _ = try store.createKnowledgeBase(name: "我的知识库")
        }
    }
    public func snapshot() throws -> LibrarySnapshot { try store.snapshot() }
    public func settings() throws -> AppSettings { try store.settings() }
    public func saveSettings(_ settings: AppSettings) throws {
        _ = try LocalEndpoint.validate(settings.embeddingBaseURL)
        _ = try LocalEndpoint.validate(settings.ollamaBaseURL)
        guard (1...12).contains(settings.topK), settings.chatModel.count <= 200 else {
            throw AskBaseError.invalidInput("检索条数需要在 1–12 之间，模型名不超过 200 字符。")
        }
        try store.saveSettings(settings)
    }
    private func embedder(_ settings: AppSettings) -> any EmbeddingProviding {
        embeddingOverride ?? EmbeddingClient(base: settings.embeddingBaseURL)
    }
    private func chat(_ settings: AppSettings) -> any ChatProviding {
        chatOverride ?? OllamaClient(base: settings.ollamaBaseURL)
    }
    public func modelStatus() async -> ModelStatus {
        var result = ModelStatus()
        do {
            let configuration = try store.settings()
            let embedding = embedder(configuration)
            let answer = chat(configuration)
            async let embeddingResult = Result { try await embedding.health() }
            async let chatResult = Result { try await answer.models() }
            switch await embeddingResult {
            case .success(let health):
                result.embeddingAvailable = true
                result.embeddingDetail = "EmbeddingGemma 2 · \(health.dimensions) 维 · 本机已连接"
            case .failure(let error): result.embeddingDetail = error.localizedDescription
            }
            switch await chatResult {
            case .success(let models):
                result.chatModels = models
                result.chatAvailable = !models.isEmpty
                result.chatDetail = models.isEmpty ? "Ollama 已连接，尚未安装回答模型。" : "Ollama · \(models.count) 个本地模型"
            case .failure(let error): result.chatDetail = error.localizedDescription
            }
        } catch { result.embeddingDetail = error.localizedDescription; result.chatDetail = error.localizedDescription }
        return result
    }

    public func createKnowledgeBase(name: String) throws -> KnowledgeBase {
        try store.createKnowledgeBase(name: validatedName(name))
    }
    public func renameKnowledgeBase(id: String, name: String) throws {
        try store.renameKnowledgeBase(id: id, name: validatedName(name))
    }
    public func deleteKnowledgeBase(id: String) throws {
        try store.deleteKnowledgeBase(id: id)
    }
    private func validatedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128 else { throw AskBaseError.invalidInput("名称需要 1–128 个字符。") }
        return name
    }
    private func requireBase(_ id: String) throws {
        guard try store.snapshot().knowledgeBases.contains(where: { $0.id == id }) else {
            throw AskBaseError.invalidInput("知识库已不存在，请重新选择。")
        }
    }

    public func importDocuments(urls: [URL], knowledgeBaseID: String) async throws -> ImportReport {
        try requireBase(knowledgeBaseID)
        guard !importingBases.contains(knowledgeBaseID) else {
            throw AskBaseError.invalidInput("此知识库正在导入资料，请等待完成。")
        }
        importingBases.insert(knowledgeBaseID)
        defer { importingBases.remove(knowledgeBaseID) }
        let configuration = try store.settings()
        let client = embedder(configuration)
        _ = try await client.health()
        let urls = try DocumentImporter.expand(urls)
        guard !urls.isEmpty else { throw AskBaseError.importFailed("所选位置没有可导入的普通文件。请选择包含文字的文档或文件夹。") }
        var report = ImportReport()
        for url in urls {
            try Task.checkCancellation()
            try requireBase(knowledgeBaseID)
            var pending: LibraryDocument?
            do {
                let prepared = try DocumentImporter.prepare(url: url, knowledgeBaseID: knowledgeBaseID,
                                                            originalsRoot: root.appendingPathComponent("Originals"))
                do {
                    if let duplicate = try store.duplicate(contentHash: prepared.document.contentHash,
                                                           knowledgeBaseID: knowledgeBaseID) {
                        try OriginalFileStorage.remove(relativePath: prepared.document.relativePath,
                                                       directory: root.appendingPathComponent("Originals"))
                        report.skipped.append("\(url.lastPathComponent)：已存在（\(duplicate.status.label)）")
                        continue
                    }
                    try store.upsertDocument(prepared.document)
                } catch {
                    let metadataError = error
                    // Until metadata commits, no library record owns this copy.
                    // Clean it on duplicate lookup / database errors as well.
                    do {
                        try OriginalFileStorage.remove(relativePath: prepared.document.relativePath,
                                                       directory: root.appendingPathComponent("Originals"))
                    } catch {
                        throw AskBaseError.storage(
                            "\(metadataError.localizedDescription)；未能清理导入副本：\(error.localizedDescription)"
                        )
                    }
                    throw metadataError
                }
                pending = prepared.document
                let chunks = try await embedded(prepared.chunks, using: client)
                try Task.checkCancellation()
                guard try store.document(id: prepared.document.id) != nil else {
                    throw AskBaseError.importFailed("资料已被删除，已取消索引写入。")
                }
                try store.replaceChunks(documentID: prepared.document.id, chunks: chunks)
                if let complete = try store.document(id: prepared.document.id) { report.imported.append(complete) }
            } catch {
                if let pending, var document = try store.document(id: pending.id) {
                    document.status = .failed
                    document.errorMessage = Task.isCancelled ? "导入已取消，可使用重新索引重试。" : error.localizedDescription
                    document.updatedAt = Date()
                    try store.upsertDocument(document)
                }
                if Task.isCancelled { throw CancellationError() }
                report.failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return report
    }

    private func embedded(_ chunks: [DocumentChunk], using client: any EmbeddingProviding) async throws -> [DocumentChunk] {
        guard !chunks.isEmpty else { throw AskBaseError.importFailed("没有可索引的文字。") }
        var output: [DocumentChunk] = []
        var signature: String?
        for start in stride(from: 0, to: chunks.count, by: 8) {
            try Task.checkCancellation()
            let batch = Array(chunks[start..<min(start + 8, chunks.count)])
            let response = try await client.embed(batch.map(\.text), inputType: "document")
            guard response.vectors.count == batch.count else { throw AskBaseError.modelUnavailable("向量数量不完整。") }
            if let signature, signature != response.signature {
                throw AskBaseError.incompatibleIndex("索引过程中编码模型发生变化，请重新索引。")
            }
            signature = response.signature
            for (var chunk, vector) in zip(batch, response.vectors) {
                guard validEmbedding(vector) else { throw AskBaseError.modelUnavailable("向量维度或数值无效。") }
                chunk.embedding = vector; chunk.encoderSignature = response.signature; chunk.dimensions = 768
                output.append(chunk)
            }
        }
        return output
    }

    public func reindex(documentID: String) async throws {
        guard !reindexingDocuments.contains(documentID) else { throw AskBaseError.invalidInput("此资料正在重新索引。") }
        guard let document = try store.document(id: documentID) else { throw AskBaseError.invalidInput("资料已不存在。") }
        guard document.status != .indexing else { throw AskBaseError.invalidInput("资料仍在导入，请等待完成后重新索引。") }
        reindexingDocuments.insert(documentID)
        defer { reindexingDocuments.remove(documentID) }
        do {
            let pages = try DocumentImporter.parse(url: originalURL(documentID: documentID),
                                                  originalFilename: document.fileName)
            let chunks = try TextChunker.cancellableChunks(pages: pages, documentID: documentID,
                                                          knowledgeBaseID: document.knowledgeBaseID)
            let encoded = try await embedded(chunks, using: embedder(store.settings()))
            try Task.checkCancellation()
            try store.replaceChunks(documentID: documentID, chunks: encoded)
        } catch {
            if document.status != .ready, var current = try store.document(id: documentID) {
                current.status = .failed; current.errorMessage = error.localizedDescription
                try store.upsertDocument(current)
            }
            throw error
        }
    }

    public func search(query: String, knowledgeBaseID: String) async throws -> [SearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 4000 else { throw AskBaseError.invalidInput("请输入 1–4000 字的问题或关键词。") }
        try requireBase(knowledgeBaseID)
        let configuration = try store.settings()
        let client = embedder(configuration)
        let embedded = try await client.embed([query], inputType: "query")
        // Read after the await so concurrent removal cannot yield deleted sources.
        let chunks = try store.chunks(knowledgeBaseID: knowledgeBaseID)
        guard !chunks.isEmpty else { return [] }
        guard chunks.allSatisfy({ $0.dimensions == 768 && $0.encoderSignature == embedded.signature }) else {
            throw AskBaseError.incompatibleIndex("部分资料的向量来自另一编码版本。请在资料库重新索引后搜索；不同版本的向量不能混用。")
        }
        guard let vector = embedded.vectors.first, validEmbedding(vector) else {
            throw AskBaseError.modelUnavailable("查询向量无效。")
        }
        let documents = try store.snapshot().documents.filter { $0.knowledgeBaseID == knowledgeBaseID }
        return Retrieval.rank(query: query, vector: vector, chunks: chunks, documents: documents, limit: configuration.topK)
    }
    public func deleteDocument(id: String) throws { try store.deleteDocument(id: id) }
    public func updateDocument(_ document: LibraryDocument) throws {
        guard var current = try store.document(id: document.id) else { throw AskBaseError.invalidInput("资料已不存在。") }
        current.title = try validatedName(document.title)
        current.isFavorite = document.isFavorite
        current.tags = Array(Set(document.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }).sorted().prefix(12)).map { String($0.prefix(32)) }
        current.updatedAt = Date()
        try store.upsertDocument(current)
    }
    public func originalURL(documentID: String) throws -> URL {
        guard let document = try store.document(id: documentID) else { throw AskBaseError.invalidInput("原始资料已被删除。") }
        return try OriginalFileStorage.existingURL(relativePath: document.relativePath,
                                                   directory: root.appendingPathComponent("Originals"))
    }
    public func documentChunks(documentID: String) throws -> [DocumentChunk] {
        try store.documentChunks(documentID: documentID)
    }
    public func saveNote(_ note: LibraryNote) throws {
        try requireBase(note.knowledgeBaseID)
        var note = note
        note.title = try validatedName(note.title)
        guard note.body.count <= 200_000 else { throw AskBaseError.invalidInput("笔记请控制在 20 万字以内。") }
        note.updatedAt = Date()
        try store.saveNote(note)
    }
    public func deleteNote(id: String) throws { try store.deleteNote(id: id) }
    public func createConversation(knowledgeBaseID: String, title: String) throws -> Conversation {
        try requireBase(knowledgeBaseID)
        return try store.createConversation(knowledgeBaseID: knowledgeBaseID, title: validatedName(String(title.prefix(80))))
    }
    public func messages(conversationID: String) throws -> [ChatMessage] {
        try store.messages(conversationID: conversationID)
    }
    public func deleteConversation(id: String) throws { try store.deleteConversation(id: id) }

    public func ask(question: String, conversationID: String, knowledgeBaseID: String) async throws -> ChatMessage {
        guard !answeringConversations.contains(conversationID) else { throw AskBaseError.invalidInput("此对话正在生成回答。") }
        guard let conversation = try store.snapshot().conversations.first(where: { $0.id == conversationID }),
              conversation.knowledgeBaseID == knowledgeBaseID else {
            throw AskBaseError.invalidInput("对话与当前知识库不一致，请创建新对话。")
        }
        answeringConversations.insert(conversationID)
        defer { answeringConversations.remove(conversationID) }
        let configuration = try store.settings()
        guard !configuration.chatModel.isEmpty else {
            throw AskBaseError.modelUnavailable("请先在设置中选择本地回答模型。语义搜索可以独立使用。")
        }
        let history = try store.messages(conversationID: conversationID)
        let sources = try await search(query: question, knowledgeBaseID: knowledgeBaseID)
        guard !sources.isEmpty else {
            throw AskBaseError.invalidInput("知识库中还没有可检索的资料，请先导入并完成索引。")
        }
        let content = try await chat(configuration).answer(model: configuration.chatModel,
                                                           question: question, sources: sources, history: history)
        try Task.checkCancellation()
        // Deletion/reindex while generating must not create a new answer with stale provenance.
        guard try store.snapshot().conversations.contains(where: { $0.id == conversationID }) else {
            throw AskBaseError.invalidInput("对话已删除，已取消保存。")
        }
        let currentChunks = Set(try store.chunks(knowledgeBaseID: knowledgeBaseID).map(\.id))
        guard sources.allSatisfy({ currentChunks.contains($0.id) }) else {
            throw AskBaseError.invalidInput("回答生成期间资料已更新或删除，请重新提问。")
        }
        let userMessage = ChatMessage(conversationID: conversationID, role: "user", content: question)
        let message = ChatMessage(conversationID: conversationID, role: "assistant", content: content, sources: sources)
        try store.saveExchange(user: userMessage, assistant: message)
        return message
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
