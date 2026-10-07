import Foundation
import AskBaseCore

@main
struct AskBaseCLI {
    static func main() async {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            func option(_ name: String) -> String? {
                guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
                let value = arguments[i + 1]
                arguments.removeSubrange(i...(i + 1))
                return value
            }
            let rootOption = option("--root")
            let model = option("--model")
            let kbOption = option("--kb")
            let command = arguments.first ?? "help"
            if command == "help" || command == "--help" {
                print("""
                AskBase Local
                  askbase status
                  askbase import <file-or-folder> ...
                  askbase search <question>
                  askbase ask --model <ollama-model> <question>
                  askbase smoke [--model <ollama-model>]
                Options: --root <library-directory>, --kb <knowledge-base-id>
                Smoke always uses an isolated temporary library and synthetic documents.
                """)
                return
            }
            arguments.removeFirst()
            if command == "smoke" {
                try await smoke(model: model)
                return
            }
            let root = rootOption.map { URL(fileURLWithPath: $0) } ?? KnowledgeEngine.defaultRoot
            let engine = try KnowledgeEngine(root: root)
            let snapshot = try await engine.snapshot()
            guard let kbID = kbOption ?? snapshot.knowledgeBases.first?.id else {
                throw AskBaseError.invalidInput("没有知识库。")
            }
            switch command {
            case "status":
                let status = await engine.modelStatus()
                try printJSON([
                    "embedding_ready": status.embeddingAvailable,
                    "embedding": status.embeddingDetail,
                    "chat_ready": status.chatAvailable,
                    "chat_models": status.chatModels,
                    "documents": snapshot.documents.count,
                    "knowledge_bases": snapshot.knowledgeBases.map { ["id": $0.id, "name": $0.name] },
                    "library": root.path,
                ])
            case "import":
                let report = try await engine.importDocuments(urls: arguments.map { URL(fileURLWithPath: $0) }, knowledgeBaseID: kbID)
                try printJSON(["summary": report.summary, "failures": report.failures, "skipped": report.skipped,
                               "imported": report.imported.map { ["id": $0.id, "title": $0.title, "chunks": $0.chunkCount] }])
                if !report.failures.isEmpty { exit(1) }
            case "search":
                let results = try await engine.search(query: arguments.joined(separator: " "), knowledgeBaseID: kbID)
                try printJSON(results.map { ["source": $0.sourceLabel, "text": $0.text, "score": $0.score, "chunk_id": $0.id] })
            case "ask":
                if let model {
                    var settings = try await engine.settings()
                    settings.chatModel = model
                    try await engine.saveSettings(settings)
                }
                let question = arguments.joined(separator: " ")
                let conversation = try await engine.createConversation(knowledgeBaseID: kbID, title: String(question.prefix(80)))
                let reply = try await engine.ask(question: question, conversationID: conversation.id, knowledgeBaseID: kbID)
                print(reply.content)
                print("\n参考资料：")
                for (i, source) in reply.sources.enumerated() { print("[\(i + 1)] \(source.sourceLabel)") }
            default: throw AskBaseError.invalidInput("未知命令：\(command)")
            }
        } catch {
            FileHandle.standardError.write(Data(("错误：\(error.localizedDescription)\n").utf8))
            exit(1)
        }
    }

    static func printJSON(_ value: Any) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: bytes, as: UTF8.self))
    }

    static func smoke(model: String?) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("AskBase-Smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let fixtures = base.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let documents = [
            ("北辰计划.md", "# 北辰计划（虚构验收资料）\n北辰计划的文档审核截止日为 10 月 18 日。负责人是林舟。上线前必须完成资料来源检查和索引一致性验证。\n预算上限为 3 万元，不能用于推断其他项目的预算。"),
            ("果园管理.txt", "苹果树需要充分的日照，幼树应定期浇水。果园土壤要保持透气。成熟的苹果应适时采摘。"),
            ("备份手册.md", "# 备份规则（虚构验收资料）\n资料备份每周日执行。备份包含 SQLite 数据库、原始文件和索引。恢复前需要验证校验和。"),
        ]
        var urls: [URL] = []
        for (name, text) in documents {
            let url = fixtures.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            urls.append(url)
        }
        let engine = try KnowledgeEngine(root: base.appendingPathComponent("library"))
        let kb = try await engine.snapshot().knowledgeBases[0]
        var checks: [String: Bool] = [:]
        let start = Date()
        let status = await engine.modelStatus()
        checks["embedding_ready"] = status.embeddingAvailable
        let imported = try await engine.importDocuments(urls: urls, knowledgeBaseID: kb.id)
        checks["three_documents_indexed"] = imported.imported.count == 3 && imported.failures.isEmpty
        checks["nonempty_ready_chunks"] = imported.imported.allSatisfy { $0.chunkCount > 0 && $0.status == .ready }
        let duplicate = try await engine.importDocuments(urls: [urls[0]], knowledgeBaseID: kb.id)
        checks["duplicate_skipped"] = duplicate.skipped.count == 1 && duplicate.imported.isEmpty
        let query = "北辰计划的审核截止日期是哪天？"
        let results = try await engine.search(query: query, knowledgeBaseID: kb.id)
        checks["relevant_source_ranked_first"] = results.first?.title.contains("北辰") == true
        checks["stable_source_id"] = results.allSatisfy { !$0.id.isEmpty && !$0.documentID.isEmpty }
        let note = LibraryNote(knowledgeBaseID: kb.id, title: "验收笔记", body: "测试数据仅用于本地工程检查。")
        try await engine.saveNote(note)
        checks["note_persisted"] = try await engine.snapshot().notes.contains(where: { $0.id == note.id })
        var answer = ""
        var conversationID: String?
        if let model {
            var configuration = try await engine.settings()
            configuration.chatModel = model
            try await engine.saveSettings(configuration)
            let conversation = try await engine.createConversation(knowledgeBaseID: kb.id, title: query)
            conversationID = conversation.id
            let reply = try await engine.ask(question: query, conversationID: conversation.id, knowledgeBaseID: kb.id)
            answer = reply.content
            checks["answer_has_known_date"] = answer.contains("18")
            checks["answer_has_citation"] = answer.contains("[1]")
            checks["exchange_persisted"] = try await engine.messages(conversationID: conversation.id).count == 2
        }
        let restored = try KnowledgeEngine(root: base.appendingPathComponent("library"))
        checks["database_reopened"] = try await restored.snapshot().documents.count == 3
        if let relevant = imported.imported.first(where: { $0.title.contains("北辰") }) {
            try await engine.reindex(documentID: relevant.id)
            checks["reindex_succeeded"] = try await engine.snapshot().documents.first(where: { $0.id == relevant.id })?.status == .ready
            try await engine.deleteDocument(id: relevant.id)
            let after = try await engine.search(query: query, knowledgeBaseID: kb.id)
            checks["deleted_source_not_retrieved"] = !after.contains { $0.documentID == relevant.id }
            if let conversationID {
                let messages = try await engine.messages(conversationID: conversationID)
                checks["saved_sources_invalidated"] = !messages.flatMap(\.sources).contains { $0.documentID == relevant.id }
            }
        }
        try await engine.deleteKnowledgeBase(id: kb.id)
        let end = try await engine.snapshot()
        checks["knowledge_base_delete_cascades"] = end.documents.isEmpty && end.notes.isEmpty && end.conversations.isEmpty
        try printJSON([
            "checks": checks, "passed": checks.values.filter { $0 }.count, "total": checks.count,
            "seconds": Date().timeIntervalSince(start), "answer": answer,
            "model": model ?? "not_run", "test_data": "synthetic; isolated temporary library; removed on exit",
        ])
        if checks.values.contains(false) { throw AskBaseError.storage("本地集成验收有未通过项目。") }
    }
}
