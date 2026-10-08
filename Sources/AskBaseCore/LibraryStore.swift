import CSQLite
import Darwin
import Foundation

/// One connection per store, protected across whole operations (not just SQLite
/// calls). FULLMUTEX and SQLite transactions also protect distinct store instances.
public final class LibraryStore: @unchecked Sendable {
    public let root: URL
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let schemaVersion = 1
    private static let dimensions = 768
    private var originalsRoot: URL { root.appendingPathComponent("Originals", isDirectory: true) }

    public init(root: URL) throws {
        guard root.isFileURL else { throw AskBaseError.storage("资料库必须保存在本机目录。") }
        let inputRoot = root.standardizedFileURL
        do { try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true) }
        catch { throw AskBaseError.storage("无法创建资料库目录：\(error.localizedDescription)") }
        // Foundation's resolvingSymlinksInPath may retain the system /var alias
        // even after the directory exists. SQLite NOFOLLOW rejects that ancestor.
        // Resolve the now-existing directory with POSIX realpath instead.
        guard let canonicalPath = realpath(inputRoot.path, nil) else {
            throw AskBaseError.storage("无法解析资料库的真实目录路径。")
        }
        self.root = URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
        free(canonicalPath)
        let originalsFD = try OriginalFileStorage.openDirectory(originalsRoot, create: true)
        Darwin.close(originalsFD)
        let databaseURL = self.root.appendingPathComponent("library.sqlite")
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = URL(fileURLWithPath: databaseURL.path + suffix)
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw AskBaseError.storage("数据库及其日志不能是符号链接。")
            }
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let code = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        guard code == SQLITE_OK else {
            let error = sqliteError("打开数据库")
            if let database { sqlite3_close_v2(database) }
            database = nil
            throw error
        }
        do {
            sqlite3_extended_result_codes(database, 1)
            sqlite3_busy_timeout(database, 5_000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA trusted_schema = OFF")
            guard try integer("PRAGMA foreign_keys") == 1 else {
                throw AskBaseError.storage("数据库无法启用外键，拒绝打开以避免残留资料。")
            }
            try migrate()
            guard try strings("PRAGMA quick_check(1)") == ["ok"],
                  try strings("PRAGMA foreign_key_check").isEmpty else {
                throw AskBaseError.storage("数据库完整性检查失败，请保留原文件并从备份恢复。")
            }
            try drainFileDeletions()
        } catch {
            if let database { sqlite3_close_v2(database) }
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close_v2(database) } }

    public func snapshot() throws -> LibrarySnapshot {
        try synchronized {
            try transaction(write: false) {
                LibrarySnapshot(
                    knowledgeBases: try records("SELECT record FROM knowledge_bases ORDER BY created_at, id"),
                    documents: try records("SELECT record FROM documents ORDER BY created_at DESC, id"),
                    notes: try records("SELECT record FROM notes ORDER BY updated_at DESC, id"),
                    conversations: try records("SELECT record FROM conversations ORDER BY created_at DESC, id")
                )
            }
        }
    }

    public func createKnowledgeBase(name: String) throws -> KnowledgeBase {
        try synchronized {
            let base = KnowledgeBase(name: try nameValue(name))
            try execute(
                "INSERT INTO knowledge_bases(id, created_at, record) VALUES(?, ?, ?)",
                [.text(base.id), .real(base.createdAt.timeIntervalSince1970), try recordValue(base)]
            )
            return base
        }
    }

    public func renameKnowledgeBase(id: String, name: String) throws {
        try synchronized {
            try transaction {
                guard var base: KnowledgeBase = try first(
                    "SELECT record FROM knowledge_bases WHERE id = ?", [.text(id)]
                ) else { throw AskBaseError.invalidInput("知识库已不存在。") }
                base.name = try nameValue(name)
                try execute("UPDATE knowledge_bases SET record = ? WHERE id = ?", [try recordValue(base), .text(id)])
            }
        }
    }

    public func deleteKnowledgeBase(id: String) throws {
        try synchronized {
            try transaction {
                let documents: [LibraryDocument] = try records(
                    "SELECT record FROM documents WHERE knowledge_base_id = ?", [.text(id)]
                )
                for document in documents {
                    try invalidateSources(documentID: document.id, keeping: [], reason: "来源已删除")
                    try enqueueFileDeletion(document.relativePath)
                }
                // Cascades remove documents, chunks, notes, conversations, messages,
                // and the normalized source lookup rows, all in this transaction.
                try execute("DELETE FROM knowledge_bases WHERE id = ?", [.text(id)])
            }
            try drainFileDeletions()
        }
    }

    public func upsertDocument(_ document: LibraryDocument) throws {
        try synchronized {
            try transaction {
                try validateIdentity(document.id)
                guard !document.contentHash.isEmpty, document.byteCount >= 0 else {
                    throw AskBaseError.invalidInput("资料缺少内容标识或文件大小无效。")
                }
                if let media = document.media, !media.isValid {
                    throw AskBaseError.invalidInput("媒体类型或原文件时间范围无效。")
                }
                _ = try OriginalFileStorage.filename(relativePath: document.relativePath)
                try requireBase(document.knowledgeBaseID)
                if let existing = try documentUnlocked(id: document.id) {
                    guard existing.knowledgeBaseID == document.knowledgeBaseID,
                          existing.relativePath == document.relativePath,
                          existing.contentHash == document.contentHash,
                          existing.fileName == document.fileName,
                          existing.byteCount == document.byteCount,
                          existing.media == document.media else {
                        throw AskBaseError.invalidInput("资料所属知识库与原文件身份不能修改，请重新导入。")
                    }
                }
                guard try integer("SELECT COUNT(*) FROM pending_file_deletions WHERE relative_path = ?",
                                  [.text(document.relativePath)]) == 0 else {
                    throw AskBaseError.storage("此副本正在等待删除，请重新导入原文件。")
                }
                if let duplicate: LibraryDocument = try first(
                    "SELECT record FROM documents WHERE knowledge_base_id = ? AND content_hash = ? AND id <> ?",
                    [.text(document.knowledgeBaseID), .text(document.contentHash), .text(document.id)]
                ) {
                    throw AskBaseError.invalidInput("此知识库已包含相同文件：“\(duplicate.title)”。")
                }
                var value = document
                value.title = try nameValue(value.title)
                value.chunkCount = try integer("SELECT COUNT(*) FROM chunks WHERE document_id = ?", [.text(value.id)])
                // UI metadata changes may retain ready, but may never manufacture
                // ready from a document that has not committed a validated index.
                if value.status == .ready {
                    guard value.chunkCount > 0 else {
                        throw AskBaseError.incompatibleIndex("没有有效向量分块的资料不能标记为可检索。")
                    }
                    let signatures = try strings(
                        "SELECT DISTINCT encoder_signature FROM chunks WHERE document_id = ?", [.text(value.id)]
                    )
                    guard signatures.count == 1 else {
                        throw AskBaseError.incompatibleIndex("资料包含不同编码签名，请重新索引。")
                    }
                    value.errorMessage = nil
                }
                if let existing = try documentUnlocked(id: value.id) { value.createdAt = existing.createdAt }
                try writeDocument(value)
            }
        }
    }

    public func document(id: String) throws -> LibraryDocument? {
        try synchronized { try documentUnlocked(id: id) }
    }

    public func duplicate(contentHash: String, knowledgeBaseID: String) throws -> LibraryDocument? {
        try synchronized {
            try first("SELECT record FROM documents WHERE knowledge_base_id = ? AND content_hash = ?",
                      [.text(knowledgeBaseID), .text(contentHash)])
        }
    }

    public func replaceChunks(documentID: String, chunks: [DocumentChunk]) throws {
        try synchronized {
            try transaction {
                guard var document = try documentUnlocked(id: documentID) else {
                    throw AskBaseError.invalidInput("资料已不存在，不能写入索引。")
                }
                try validateChunks(chunks, document: document)
                // A knowledge base may temporarily contain several signatures
                // while its documents are upgraded one by one. KnowledgeEngine
                // rejects searching that mixed state against a query signature.
                // Encoding also happens before removal. SQLite rolls back any
                // subsequent constraint/disk error, including one late in a batch.
                let encoded = try chunks.map { try recordValue($0) }
                try invalidateSources(documentID: documentID, keeping: chunks, reason: "来源已更新")
                try execute("DELETE FROM chunks WHERE document_id = ?", [.text(documentID)])
                for (chunk, record) in zip(chunks, encoded) {
                    try execute("""
                        INSERT INTO chunks(id, document_id, knowledge_base_id, ordinal, encoder_signature, dimensions, record)
                        VALUES(?, ?, ?, ?, ?, ?, ?)
                        """, [.text(chunk.id), .text(documentID), .text(document.knowledgeBaseID), .integer(chunk.ordinal),
                              .text(chunk.encoderSignature), .integer(chunk.dimensions), record])
                }
                // Restoring normalized source links is necessary if a caller
                // deliberately retained IDs for text-identical replacement chunks.
                let messages: [ChatMessage] = try records(
                    "SELECT record FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE knowledge_base_id = ?)",
                    [.text(document.knowledgeBaseID)]
                )
                for message in messages where message.sources.contains(where: { $0.documentID == documentID }) {
                    try writeMessage(message)
                }
                document.status = .ready
                document.errorMessage = nil
                document.chunkCount = chunks.count
                document.updatedAt = Date()
                try writeDocument(document)
            }
        }
    }

    public func chunks(knowledgeBaseID: String) throws -> [DocumentChunk] {
        try synchronized {
            try records("""
                SELECT c.record FROM chunks c JOIN documents d ON d.id = c.document_id
                WHERE c.knowledge_base_id = ? AND d.status = 'ready'
                ORDER BY d.created_at, d.id, c.ordinal
                """, [.text(knowledgeBaseID)])
        }
    }

    public func documentChunks(documentID: String) throws -> [DocumentChunk] {
        try synchronized {
            try records("SELECT record FROM chunks WHERE document_id = ? ORDER BY ordinal", [.text(documentID)])
        }
    }

    public func deleteDocument(id: String) throws {
        try synchronized {
            try transaction {
                guard let document = try documentUnlocked(id: id) else { return }
                try invalidateSources(documentID: id, keeping: [], reason: "来源已删除")
                try enqueueFileDeletion(document.relativePath)
                try execute("DELETE FROM documents WHERE id = ?", [.text(id)])
            }
            try drainFileDeletions()
        }
    }

    public func saveNote(_ note: LibraryNote) throws {
        try synchronized {
            try transaction {
                try validateIdentity(note.id)
                try requireBase(note.knowledgeBaseID)
                if let existing: LibraryNote = try first("SELECT record FROM notes WHERE id = ?", [.text(note.id)]),
                   existing.knowledgeBaseID != note.knowledgeBaseID {
                    throw AskBaseError.invalidInput("笔记不能通过保存操作移动到另一知识库。")
                }
                var value = note
                value.title = try nameValue(value.title)
                try execute("""
                    INSERT INTO notes(id, knowledge_base_id, updated_at, record) VALUES(?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, record = excluded.record
                    """, [.text(value.id), .text(value.knowledgeBaseID),
                          .real(value.updatedAt.timeIntervalSince1970), try recordValue(value)])
                // Notes are a scratchpad. Saving them never creates document chunks.
            }
        }
    }

    public func deleteNote(id: String) throws {
        try synchronized { try execute("DELETE FROM notes WHERE id = ?", [.text(id)]) }
    }

    public func createConversation(knowledgeBaseID: String, title: String) throws -> Conversation {
        try synchronized {
            try transaction {
                try requireBase(knowledgeBaseID)
                let value = Conversation(knowledgeBaseID: knowledgeBaseID, title: try nameValue(title))
                try execute("INSERT INTO conversations(id, knowledge_base_id, created_at, record) VALUES(?, ?, ?, ?)",
                            [.text(value.id), .text(value.knowledgeBaseID),
                             .real(value.createdAt.timeIntervalSince1970), try recordValue(value)])
                return value
            }
        }
    }

    public func messages(conversationID: String) throws -> [ChatMessage] {
        try synchronized {
            try records("SELECT record FROM messages WHERE conversation_id = ? ORDER BY created_at, rowid",
                        [.text(conversationID)])
        }
    }

    public func saveMessage(_ message: ChatMessage) throws {
        try synchronized {
            try transaction {
                try validateMessage(message)
                try writeMessage(message)
            }
        }
    }

    /// Save an entire turn atomically: a failed assistant insert/source check
    /// cannot leave a user message that appears to be waiting for a response.
    public func saveExchange(user: ChatMessage, assistant: ChatMessage) throws {
        try synchronized {
            try transaction {
                guard user.conversationID == assistant.conversationID, user.id != assistant.id,
                      user.role == "user", assistant.role == "assistant" else {
                    throw AskBaseError.invalidInput("一轮问答必须包含同一对话中的用户消息和助手回复。")
                }
                try validateMessage(user)
                try writeMessage(user)
                try validateMessage(assistant)
                try writeMessage(assistant)
            }
        }
    }

    public func deleteConversation(id: String) throws {
        try synchronized { try execute("DELETE FROM conversations WHERE id = ?", [.text(id)]) }
    }

    public func settings() throws -> AppSettings {
        try synchronized { try first("SELECT record FROM settings WHERE id = 1") ?? AppSettings() }
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try synchronized {
            try execute("INSERT INTO settings(id, record) VALUES(1, ?) ON CONFLICT(id) DO UPDATE SET record = excluded.record",
                        [try recordValue(settings)])
        }
    }

    /// Explicitly called by the engine at startup; opening another connection
    /// alone must not mark an actively running import as interrupted.
    public func recoverInterruptedImports() throws {
        try synchronized {
            try transaction {
                let interrupted: [LibraryDocument] = try records("SELECT record FROM documents WHERE status = 'indexing'")
                for var document in interrupted {
                    document.status = .failed
                    document.errorMessage = "上次导入或索引因应用退出而中断，副本已保留。请使用“重新索引”重试。"
                    document.updatedAt = Date()
                    document.chunkCount = try integer("SELECT COUNT(*) FROM chunks WHERE document_id = ?", [.text(document.id)])
                    try writeDocument(document)
                }
            }
            try drainFileDeletions()
        }
    }

    // MARK: Record invariants

    private func validateChunks(_ chunks: [DocumentChunk], document: LibraryDocument) throws {
        guard let first = chunks.first, !first.encoderSignature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AskBaseError.incompatibleIndex("索引不能为空，且必须携带 EmbeddingGemma 2 的编码签名。")
        }
        var ids = Set<String>()
        var ordinals = Set<Int>()
        for chunk in chunks {
            try validateIdentity(chunk.id)
            guard chunk.documentID == document.id, chunk.knowledgeBaseID == document.knowledgeBaseID,
                  ids.insert(chunk.id).inserted, ordinals.insert(chunk.ordinal).inserted,
                  chunk.ordinal >= 0, chunk.ordinal < chunks.count,
                  chunk.page.map({ $0 > 0 }) ?? true,
                  !chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AskBaseError.incompatibleIndex("分块身份、顺序、页码或内容无效，原索引已保留。")
            }
            guard chunk.dimensions == Self.dimensions, validEmbedding(chunk.embedding),
                  chunk.encoderSignature == first.encoderSignature else {
                throw AskBaseError.incompatibleIndex("分块必须使用相同签名的 768 维有限、归一化向量，原索引已保留。")
            }
            switch (document.media, chunk.media) {
            case (nil, nil): break
            case (.some(let original), .some(let media)):
                guard media.isValid, media.kind == original.kind, chunk.page == nil,
                      !(media.encoderSignature ?? "").isEmpty, !(media.recipe ?? "").isEmpty,
                      media.encoderSignature == first.media?.encoderSignature,
                      media.recipe == first.media?.recipe else {
                    throw AskBaseError.incompatibleIndex("媒体位置、预处理版本或编码签名无效，原索引已保留。")
                }
                if media.kind == .video, media.frameTimes?.isEmpty != false {
                    throw AskBaseError.incompatibleIndex("视频分块必须保留实际抽取的帧位置。")
                }
            default:
                throw AskBaseError.incompatibleIndex("资料与分块的媒体类型不一致，原索引已保留。")
            }
        }
        if let media = document.media {
            let ordered = chunks.sorted { $0.ordinal < $1.ordinal }
            if media.kind == .image {
                guard ordered.enumerated().allSatisfy({ $0.element.media?.imageIndex == $0.offset }) else {
                    throw AskBaseError.incompatibleIndex("图片各帧／页必须连续索引，原索引已保留。")
                }
            } else {
                var end = media.startSeconds ?? 0
                for chunk in ordered {
                    guard let segment = chunk.media, let start = segment.startSeconds, let next = segment.endSeconds,
                          abs(start - end) < 0.001, next > start, next - start <= 10.001 else {
                        throw AskBaseError.incompatibleIndex("音视频索引缺少时间段或片段超过 10 秒，原索引已保留。")
                    }
                    end = next
                }
                guard let durationEnd = media.endSeconds, abs(end - durationEnd) < 0.001 else {
                    throw AskBaseError.incompatibleIndex("音视频索引没有覆盖完整文件，原索引已保留。")
                }
            }
        }
    }

    private func documentUnlocked(id: String) throws -> LibraryDocument? {
        try first("SELECT record FROM documents WHERE id = ?", [.text(id)])
    }

    private func writeDocument(_ document: LibraryDocument) throws {
        try execute("""
            INSERT INTO documents(id, knowledge_base_id, content_hash, relative_path, status, created_at, record)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET status = excluded.status, record = excluded.record
            """, [.text(document.id), .text(document.knowledgeBaseID), .text(document.contentHash),
                  .text(document.relativePath), .text(document.status.rawValue),
                  .real(document.createdAt.timeIntervalSince1970), try recordValue(document)])
    }

    private func requireBase(_ id: String) throws {
        guard try integer("SELECT COUNT(*) FROM knowledge_bases WHERE id = ?", [.text(id)]) == 1 else {
            throw AskBaseError.invalidInput("知识库已不存在。")
        }
    }

    private func validateIdentity(_ id: String) throws {
        guard !id.isEmpty, !id.contains("\0") else { throw AskBaseError.invalidInput("记录标识无效。") }
    }

    private func nameValue(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\0") else { throw AskBaseError.invalidInput("名称不能为空或包含空字符。") }
        return value
    }

    private func writeMessage(_ message: ChatMessage) throws {
        try execute("""
            INSERT INTO messages(id, conversation_id, created_at, record) VALUES(?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET record = excluded.record
            """, [.text(message.id), .text(message.conversationID),
                  .real(message.createdAt.timeIntervalSince1970), try recordValue(message)])
        try execute("DELETE FROM message_sources WHERE message_id = ?", [.text(message.id)])
        for (position, source) in message.sources.enumerated() {
            try execute("INSERT INTO message_sources(message_id, position, document_id, chunk_id) VALUES(?, ?, ?, ?)",
                        [.text(message.id), .integer(position), .text(source.documentID), .text(source.id)])
        }
    }

    private func validateMessage(_ message: ChatMessage) throws {
        try validateIdentity(message.id)
        guard let conversation: Conversation = try first(
            "SELECT record FROM conversations WHERE id = ?", [.text(message.conversationID)]
        ) else { throw AskBaseError.invalidInput("对话已不存在。") }
        if let existing: ChatMessage = try first("SELECT record FROM messages WHERE id = ?", [.text(message.id)]),
           existing.conversationID != message.conversationID {
            throw AskBaseError.invalidInput("消息不能移动到另一对话。")
        }
        for source in message.sources {
            guard source.knowledgeBaseID == conversation.knowledgeBaseID, source.score.isFinite,
                  let chunk: DocumentChunk = try first("""
                    SELECT c.record FROM chunks c JOIN documents d ON d.id = c.document_id
                    WHERE c.id = ? AND c.document_id = ? AND d.status = 'ready'
                    """, [.text(source.id), .text(source.documentID)]),
                  chunk.knowledgeBaseID == source.knowledgeBaseID,
                  chunk.text == source.text, chunk.page == source.page,
                  chunk.media == source.media, source.hasReadableEvidence else {
                throw AskBaseError.incompatibleIndex("回答来源已删除、已更新或不属于此知识库，请重新提问。")
            }
        }
    }

    private func invalidateSources(documentID: String, keeping chunks: [DocumentChunk], reason: String) throws {
        let replacements = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
        let affected: [ChatMessage] = try records("""
            SELECT m.record FROM messages m WHERE m.id IN
            (SELECT message_id FROM message_sources WHERE document_id = ?)
            """, [.text(documentID)])
        for var message in affected {
            let oldSources = message.sources
            let allSourcesStillValid = oldSources.allSatisfy { source in
                let replacement = replacements[source.id]
                return source.documentID != documentID ||
                    (replacement?.text == source.text && replacement?.page == source.page &&
                     replacement?.media == source.media && replacement != nil)
            }
            guard !allSourcesStillValid else { continue }
            // SearchResult has no persistent citation ordinal/tombstone field.
            // Revoke this answer's complete source list and keep its original
            // prose/numbering, rather than silently reassigning [2] to [1].
            message.sources = []
            message.content += "\n\n〔历史回答来源已撤销：\(reason)。原引用编号仅保留作历史记录，请重新提问以获得当前来源。〕"
            try writeMessage(message)
        }
    }

    // MARK: Crash-safe deletion outbox

    private func enqueueFileDeletion(_ relativePath: String) throws {
        _ = try OriginalFileStorage.filename(relativePath: relativePath)
        try execute("INSERT OR IGNORE INTO pending_file_deletions(relative_path) VALUES(?)", [.text(relativePath)])
    }

    private func drainFileDeletions() throws {
        // A queued filename cannot be reused by upsertDocument. Deleting twice is
        // safe if the process exits between unlink and acknowledging this row.
        let paths = try strings("SELECT relative_path FROM pending_file_deletions ORDER BY relative_path")
        var firstError: Error?
        for path in paths {
            do {
                try transaction {
                    // Another connection may have drained our snapshot already.
                    // Hold the writer transaction through unlink/acknowledgment
                    // so a concurrently reused filename can never be removed.
                    guard try integer("SELECT COUNT(*) FROM pending_file_deletions WHERE relative_path = ?",
                                      [.text(path)]) == 1 else { return }
                    guard try integer("SELECT COUNT(*) FROM documents WHERE relative_path = ?", [.text(path)]) == 0 else {
                        throw AskBaseError.storage("待删除副本仍有资料引用，已停止清理。")
                    }
                    try OriginalFileStorage.remove(relativePath: path, directory: originalsRoot)
                    try execute("DELETE FROM pending_file_deletions WHERE relative_path = ?", [.text(path)])
                }
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    // MARK: SQLite

    private enum Value {
        case text(String), integer(Int), real(Double), blob(Data)
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func transaction<T>(write: Bool = true, _ body: () throws -> T) throws -> T {
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN DEFERRED")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func withStatement<T>(_ sql: String, _ values: [Value], _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError("准备数据库操作")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == values.count else {
            throw AskBaseError.storage("数据库操作的参数数量不匹配。")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .text(let text):
                let bytes = text.utf8CString
                guard bytes.count - 1 <= Int32.max else { throw AskBaseError.storage("记录字段过大。") }
                code = bytes.withUnsafeBufferPointer {
                    sqlite3_bind_text(statement, index, $0.baseAddress, Int32(bytes.count - 1), transient)
                }
            case .integer(let value):
                code = sqlite3_bind_int64(statement, index, Int64(value))
            case .real(let value):
                guard value.isFinite else { throw AskBaseError.invalidInput("记录日期或数值无效。") }
                code = sqlite3_bind_double(statement, index, value)
            case .blob(let data):
                guard data.count <= Int32.max else { throw AskBaseError.storage("记录数据过大。") }
                code = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient)
                }
            }
            guard code == SQLITE_OK else { throw sqliteError("绑定数据库字段") }
        }
        return try body(statement)
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        try withStatement(sql, values) { statement in
            var code = sqlite3_step(statement)
            // PRAGMA journal_mode returns a row even when used for configuration.
            while code == SQLITE_ROW { code = sqlite3_step(statement) }
            guard code == SQLITE_DONE else { throw sqliteError("保存资料") }
        }
    }

    private func records<T: Decodable>(_ sql: String, _ values: [Value] = []) throws -> [T] {
        try withStatement(sql, values) { statement in
            var records: [T] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                let count = Int(sqlite3_column_bytes(statement, 0))
                guard let bytes = sqlite3_column_blob(statement, 0), count > 0 else {
                    throw AskBaseError.storage("资料库存在空记录，请从备份恢复。")
                }
                do { records.append(try decoder.decode(T.self, from: Data(bytes: bytes, count: count))) }
                catch { throw AskBaseError.storage("无法读取资料记录，格式损坏或版本不兼容：\(error.localizedDescription)") }
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw sqliteError("读取资料") }
            return records
        }
    }

    private func first<T: Decodable>(_ sql: String, _ values: [Value] = []) throws -> T? {
        try records(sql, values).first
    }

    private func recordValue<T: Encodable>(_ value: T) throws -> Value {
        do { return .blob(try encoder.encode(value)) }
        catch { throw AskBaseError.storage("资料无法序列化：\(error.localizedDescription)") }
    }

    private func integer(_ sql: String, _ values: [Value] = []) throws -> Int {
        try withStatement(sql, values) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError("读取数据库计数") }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func strings(_ sql: String, _ values: [Value] = []) throws -> [String] {
        try withStatement(sql, values) { statement in
            var values: [String] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                if let bytes = sqlite3_column_text(statement, 0) {
                    let count = Int(sqlite3_column_bytes(statement, 0))
                    values.append(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self))
                }
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw sqliteError("读取数据库字段") }
            return values
        }
    }

    private func sqliteError(_ operation: String) -> AskBaseError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "连接不可用"
        let code = sqlite3_extended_errcode(database)
        return .storage("\(operation)失败：\(message)（SQLite \(code)）")
    }

    private func migrate() throws {
        try transaction {
            let version = try integer("PRAGMA user_version")
            guard version <= Self.schemaVersion else {
                throw AskBaseError.storage("资料库由较新版本创建，请升级应用；不会降级或覆盖现有数据。")
            }
            guard version == 0 else { return }
            let statements = [
                """
                CREATE TABLE knowledge_bases(
                    id TEXT PRIMARY KEY NOT NULL, created_at REAL NOT NULL, record BLOB NOT NULL
                )
                """,
                """
                CREATE TABLE documents(
                    id TEXT PRIMARY KEY NOT NULL,
                    knowledge_base_id TEXT NOT NULL REFERENCES knowledge_bases(id) ON DELETE CASCADE,
                    content_hash TEXT NOT NULL, relative_path TEXT UNIQUE NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('indexing', 'ready', 'failed')),
                    created_at REAL NOT NULL, record BLOB NOT NULL,
                    UNIQUE(knowledge_base_id, content_hash), UNIQUE(id, knowledge_base_id)
                )
                """,
                """
                CREATE TABLE chunks(
                    id TEXT PRIMARY KEY NOT NULL, document_id TEXT NOT NULL, knowledge_base_id TEXT NOT NULL,
                    ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
                    encoder_signature TEXT NOT NULL CHECK(length(trim(encoder_signature)) > 0),
                    dimensions INTEGER NOT NULL CHECK(dimensions = 768), record BLOB NOT NULL,
                    FOREIGN KEY(document_id, knowledge_base_id) REFERENCES documents(id, knowledge_base_id) ON DELETE CASCADE,
                    UNIQUE(document_id, ordinal), UNIQUE(id, document_id)
                )
                """,
                "CREATE INDEX chunks_base ON chunks(knowledge_base_id)",
                """
                CREATE TABLE notes(
                    id TEXT PRIMARY KEY NOT NULL,
                    knowledge_base_id TEXT NOT NULL REFERENCES knowledge_bases(id) ON DELETE CASCADE,
                    updated_at REAL NOT NULL, record BLOB NOT NULL
                )
                """,
                "CREATE INDEX notes_base ON notes(knowledge_base_id)",
                """
                CREATE TABLE conversations(
                    id TEXT PRIMARY KEY NOT NULL,
                    knowledge_base_id TEXT NOT NULL REFERENCES knowledge_bases(id) ON DELETE CASCADE,
                    created_at REAL NOT NULL, record BLOB NOT NULL
                )
                """,
                "CREATE INDEX conversations_base ON conversations(knowledge_base_id)",
                """
                CREATE TABLE messages(
                    id TEXT PRIMARY KEY NOT NULL,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    created_at REAL NOT NULL, record BLOB NOT NULL
                )
                """,
                "CREATE INDEX messages_conversation ON messages(conversation_id, created_at)",
                """
                CREATE TABLE message_sources(
                    message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL CHECK(position >= 0), document_id TEXT NOT NULL, chunk_id TEXT NOT NULL,
                    PRIMARY KEY(message_id, position),
                    FOREIGN KEY(chunk_id, document_id) REFERENCES chunks(id, document_id) ON DELETE CASCADE
                )
                """,
                "CREATE INDEX sources_document ON message_sources(document_id)",
                "CREATE INDEX sources_chunk ON message_sources(chunk_id, document_id)",
                "CREATE TABLE settings(id INTEGER PRIMARY KEY CHECK(id = 1), record BLOB NOT NULL)",
                "CREATE TABLE pending_file_deletions(relative_path TEXT PRIMARY KEY NOT NULL)",
                "PRAGMA user_version = 1"
            ]
            for statement in statements { try execute(statement) }
        }
    }
}
