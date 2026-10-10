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
    private var taggingDocuments: Set<String> = []
    private var tagVectorCache: [String: [Float]] = [:]

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
                result.embeddingModalities = health.modalities ?? ["text"]
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
        guard !urls.isEmpty else { throw AskBaseError.importFailed("所选位置没有可导入的普通文件。请选择文档、媒体或文件夹。") }
        var report = ImportReport()
        for url in urls {
            try Task.checkCancellation()
            try requireBase(knowledgeBaseID)
            var pending: LibraryDocument?
            do {
                let prepared = try await DocumentImporter.prepareForImport(
                    url: url, knowledgeBaseID: knowledgeBaseID, originalsRoot: root.appendingPathComponent("Originals")
                )
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
                let chunks: [DocumentChunk]
                if prepared.document.media != nil {
                    chunks = try await DocumentImporter.withSnapshot(
                        url: originalURL(documentID: prepared.document.id), expectedHash: prepared.document.contentHash
                    ) { snapshot in
                        try await self.embeddedMedia(prepared.chunks, url: snapshot, using: client)
                    }
                } else {
                    chunks = try await embedded(prepared.chunks, using: client)
                }
                try Task.checkCancellation()
                guard try store.document(id: prepared.document.id) != nil else {
                    throw AskBaseError.importFailed("资料已被删除，已取消索引写入。")
                }
                try store.replaceChunks(documentID: prepared.document.id, chunks: chunks)
                // Indexing is already committed. Optional enrichment must never
                // turn a successfully imported document into a failed one.
                pending = nil
                if configuration.autoTagOnImport {
                    do { _ = try await autoTag(documentID: prepared.document.id) }
                    catch {
                        if Task.isCancelled { throw CancellationError() }
                        report.taggingWarnings.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
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
            guard try store.document(id: batch[0].documentID) != nil else {
                throw AskBaseError.importFailed("资料已被删除，已停止后续索引。")
            }
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

    private func embeddedMedia(
        _ chunks: [DocumentChunk], url: URL, using client: any EmbeddingProviding
    ) async throws -> [DocumentChunk] {
        guard let kind = chunks.first?.media?.kind, !chunks.isEmpty else {
            throw AskBaseError.importFailed("没有可索引的媒体片段。")
        }
        let health = try await client.health()
        guard health.supports(kind) else {
            throw AskBaseError.modelUnavailable("本机服务尚未启用\(kind.label)。请更新 EmbeddingGemma 2 服务后重新索引。")
        }
        var output: [DocumentChunk] = []
        for var chunk in chunks {
            try Task.checkCancellation()
            guard try store.document(id: chunk.documentID) != nil else {
                throw AskBaseError.importFailed("资料已被删除，已停止后续媒体处理。")
            }
            guard let reference = chunk.media, reference.kind == kind else {
                throw AskBaseError.importFailed("媒体片段类型不一致。")
            }
            let prepared = try await MediaProcessor.segment(url: url, reference: reference)
            try Task.checkCancellation()
            guard try store.document(id: chunk.documentID) != nil else {
                throw AskBaseError.importFailed("资料已被删除，已停止媒体编码。")
            }
            let response = try await client.embedMedia(prepared.input, inputType: "document")
            guard response.signature == health.encoderSignature,
                  response.mediaSignature == health.mediaEncoderSignature,
                  response.vectors.count == 1, let vector = response.vectors.first, validEmbedding(vector) else {
                throw AskBaseError.incompatibleIndex("媒体编码版本在索引期间发生变化或返回了无效向量，原索引已保留。")
            }
            var position = prepared.reference
            position.encoderSignature = response.mediaSignature
            if let text = prepared.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
               position.textSource != nil {
                chunk.text = text
            } else {
                position.textSource = nil
                chunk.text = DocumentImporter.mediaPlaceholder(position)
            }
            chunk.media = position
            chunk.embedding = vector; chunk.encoderSignature = response.signature; chunk.dimensions = 768
            output.append(chunk)
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
            let client = embedder(try store.settings())
            let encoded = try await DocumentImporter.withSnapshot(
                url: originalURL(documentID: documentID), expectedHash: document.contentHash
            ) { snapshot in
                if let media = document.media {
                    guard let plan = try await MediaProcessor.inspect(url: snapshot), plan.reference.kind == media.kind else {
                        throw AskBaseError.importFailed("媒体副本无法识别，旧索引已保留。")
                    }
                    let chunks = try DocumentImporter.mediaChunks(
                        plan: plan, documentID: documentID, knowledgeBaseID: document.knowledgeBaseID
                    )
                    return try await self.embeddedMedia(chunks, url: snapshot, using: client)
                }
                let pages = try DocumentTextExtractor.parse(url: snapshot, originalFilename: document.fileName)
                let chunks = try TextChunker.cancellableChunks(pages: pages, documentID: documentID,
                                                              knowledgeBaseID: document.knowledgeBaseID)
                return try await self.embedded(chunks, using: client)
            }
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
        try await searchText(query: query, knowledgeBaseID: knowledgeBaseID, readableOnly: false)
    }

    private func searchText(query: String, knowledgeBaseID: String, readableOnly: Bool) async throws -> [SearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 4000 else { throw AskBaseError.invalidInput("请输入 1–4000 字的问题或关键词。") }
        try requireBase(knowledgeBaseID)
        let configuration = try store.settings()
        let client = embedder(configuration)
        let embedded = try await client.embed([query], inputType: "query")
        let health: EmbeddingHealth?
        if try store.chunks(knowledgeBaseID: knowledgeBaseID).contains(where: { $0.media != nil }) {
            health = try await client.health()
        } else { health = nil }
        try Task.checkCancellation()
        try requireBase(knowledgeBaseID)
        // Read after the await so concurrent removal cannot yield deleted sources.
        let chunks = try store.chunks(knowledgeBaseID: knowledgeBaseID).filter {
            !readableOnly || $0.media == nil || $0.media?.textSource != nil
        }
        guard !chunks.isEmpty else { return [] }
        try validateSpace(chunks: chunks, signature: embedded.signature, health: health)
        guard embedded.vectors.count == 1, let vector = embedded.vectors.first, validEmbedding(vector) else {
            throw AskBaseError.modelUnavailable("查询向量无效。")
        }
        let documents = try store.snapshot().documents.filter { $0.knowledgeBaseID == knowledgeBaseID }
        return Retrieval.rank(query: query, vector: vector, chunks: chunks, documents: documents, limit: configuration.topK)
    }

    /// A media query is transient: it is never copied into the user's library.
    /// Long queries cover every segment; each source keeps its best similarity.
    public func search(mediaURL: URL, knowledgeBaseID: String) async throws -> [SearchResult] {
        try requireBase(knowledgeBaseID)
        let configuration = try store.settings()
        let client = embedder(configuration)
        let health = try await client.health()
        let vectors = try await DocumentImporter.withSnapshot(url: mediaURL) { snapshot in
            guard let plan = try await MediaProcessor.inspect(url: snapshot) else {
                throw AskBaseError.invalidInput("用媒体搜索需要图片、音频或视频文件。")
            }
            guard health.supports(plan.reference.kind) else {
                throw AskBaseError.modelUnavailable("本机服务尚未启用\(plan.reference.kind.label)，请先更新嵌入服务。")
            }
            var vectors: [[Float]] = []
            for reference in plan.segments {
                try Task.checkCancellation()
                let prepared = try await MediaProcessor.segment(url: snapshot, reference: reference)
                let response = try await client.embedMedia(prepared.input, inputType: "query")
                guard response.signature == health.encoderSignature,
                      response.mediaSignature == health.mediaEncoderSignature,
                      response.vectors.count == 1, let vector = response.vectors.first, validEmbedding(vector) else {
                    throw AskBaseError.incompatibleIndex("媒体查询期间编码服务发生变化或返回无效向量，请重试。")
                }
                vectors.append(vector)
            }
            return vectors
        }
        try Task.checkCancellation()
        try requireBase(knowledgeBaseID)
        let chunks = try store.chunks(knowledgeBaseID: knowledgeBaseID)
        try validateSpace(chunks: chunks, signature: health.encoderSignature, health: health)
        let documents = try store.snapshot().documents.filter { $0.knowledgeBaseID == knowledgeBaseID }
        var best: [String: SearchResult] = [:]
        for vector in vectors {
            try Task.checkCancellation()
            for result in Retrieval.rank(query: "", vector: vector, chunks: chunks,
                                          documents: documents, limit: configuration.topK) {
                if result.score > (best[result.id]?.score ?? -Double.infinity) { best[result.id] = result }
            }
        }
        return Array(best.values.sorted {
            $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score
        }.prefix(configuration.topK))
    }

    private func validateSpace(chunks: [DocumentChunk], signature: String, health: EmbeddingHealth?) throws {
        guard chunks.allSatisfy({ $0.dimensions == 768 && $0.encoderSignature == signature }) else {
            throw AskBaseError.incompatibleIndex("部分资料的向量来自另一编码版本。请在资料库重新索引后搜索；不同版本的向量不能混用。")
        }
        for chunk in chunks {
            if let media = chunk.media {
                guard let health, health.encoderSignature == signature, health.supports(media.kind),
                      media.encoderSignature == health.mediaEncoderSignature,
                      media.recipe == MediaProcessor.recipe else {
                    throw AskBaseError.incompatibleIndex("部分媒体使用了不同的编码版本，或本机媒体服务尚未就绪。请更新服务并重新索引这些媒体。")
                }
            }
        }
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

    /// Fill only an untagged, ready document. Reuses stored content vectors and
    /// the current embedding service; no chat model, downloads, or remote calls.
    @discardableResult
    public func autoTag(documentID: String) async throws -> [String] {
        try Task.checkCancellation()
        guard let document = try store.document(id: documentID) else {
            throw AskBaseError.invalidInput("资料已不存在。")
        }
        guard document.tags.isEmpty else { return [] }
        guard document.status == .ready, !reindexingDocuments.contains(documentID) else {
            throw AskBaseError.invalidInput("资料索引完成后才能匹配标签。")
        }
        guard taggingDocuments.insert(documentID).inserted else { return [] }
        defer { taggingDocuments.remove(documentID) }
        let configuration = try store.settings()
        let client = embedder(configuration)
        let chunks = try store.documentChunks(documentID: documentID)
        guard !chunks.isEmpty, chunks.allSatisfy({ validEmbedding($0.embedding) }) else {
            throw AskBaseError.incompatibleIndex("资料没有有效向量，请先重新索引。")
        }
        let health = try await client.health()
        try Task.checkCancellation()
        try validateSpace(chunks: chunks, signature: health.encoderSignature, health: health)
        let frequencies = try store.snapshot().documents
            .filter { $0.knowledgeBaseID == document.knowledgeBaseID }
            .flatMap(\.tags).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let existing = frequencies.keys.sorted {
            frequencies[$0] == frequencies[$1] ? $0 < $1 : frequencies[$0]! > frequencies[$1]!
        }
        let candidates = AutoTagging.candidates(existingTags: existing)
        let keys = candidates.map {
            "\(configuration.embeddingBaseURL)\u{0}\(health.encoderSignature)\u{0}\($0.prompt)"
        }
        if tagVectorCache.count + keys.filter({ tagVectorCache[$0] == nil }).count > 256 {
            tagVectorCache.removeAll()
        }
        var vectors = keys.map { tagVectorCache[$0] }
        let missing = vectors.indices.filter { vectors[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: 8) {
            try Task.checkCancellation()
            guard let current = try store.document(id: documentID),
                  current.tags.isEmpty, current.updatedAt == document.updatedAt,
                  !reindexingDocuments.contains(documentID) else { return [] }
            let indices = Array(missing[start..<min(start + 8, missing.count)])
            let response = try await client.embed(indices.map { candidates[$0].prompt }, inputType: "query")
            guard response.signature == health.encoderSignature,
                  response.vectors.count == indices.count,
                  response.vectors.allSatisfy({ validEmbedding($0) }) else {
                throw AskBaseError.incompatibleIndex("标签匹配期间编码模型发生变化或返回无效向量，请重试。")
            }
            for (index, vector) in zip(indices, response.vectors) {
                vectors[index] = vector
                tagVectorCache[keys[index]] = vector
            }
        }
        try Task.checkCancellation()
        guard !reindexingDocuments.contains(documentID) else { return [] }
        let tags = AutoTagging.select(candidates: candidates, vectors: vectors.compactMap { $0 },
                                      chunks: chunks, title: document.title)
        return try store.applyAutomaticTags(documentID: documentID, expectedUpdatedAt: document.updatedAt,
                                             tags: tags) ? tags : []
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
        // Filter before top-K so opaque media hits cannot crowd readable text
        // out of the RAG context or become fabricated transcript evidence.
        let sources = try await searchText(query: question, knowledgeBaseID: knowledgeBaseID, readableOnly: true)
        guard !sources.isEmpty else {
            throw AskBaseError.invalidInput("没有可用于文字问答的原文或 OCR 文字。图片、录音和视频仍可在语义搜索中检索、预览或播放。")
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
