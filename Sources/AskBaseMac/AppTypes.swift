import Foundation
import AskBaseCore

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case library, search, chat, notes, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: "资料库"
        case .search: "语义搜索"
        case .chat: "知识问答"
        case .notes: "笔记"
        case .settings: "设置"
        }
    }
    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .search: "magnifyingglass"
        case .chat: "bubble.left.and.bubble.right"
        case .notes: "square.and.pencil"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum DocumentSort: String, CaseIterable, Identifiable {
    case newest = "最近加入"
    case title = "名称"
    var id: String { rawValue }
}

struct AppIssue: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum AppSheet: Identifiable {
    case knowledgeBase(KnowledgeBase?)
    case source(SearchResult)
    case importReport
    case issue(AppIssue)

    var id: String {
        switch self {
        case .knowledgeBase(let base): "base:\(base?.id ?? "new")"
        case .source(let source): "source:\(source.id)"
        case .importReport: "import-report"
        case .issue(let issue): "issue:\(issue.id)"
        }
    }
}

struct DeletionRequest: Identifiable {
    enum Target {
        case knowledgeBase(KnowledgeBase)
        case document(LibraryDocument)
        case note(LibraryNote)
        case conversation(Conversation)
    }
    let id = UUID()
    var target: Target
    var title: String
    var explanation: String
}

struct ImportActivity {
    let id = UUID()
    var knowledgeBaseID: String
    var knowledgeBaseName: String
    var selectedCount: Int
    var existingDocumentIDs: Set<String>
    var startedAt = Date()
}

struct ImportOutcome {
    var report: ImportReport
    var knowledgeBaseName: String
    var wasCancelled = false
    var error: String?
    var finishedAt = Date()

    var title: String {
        if wasCancelled { return "导入已停止" }
        if error != nil { return "导入未完成" }
        if !report.failures.isEmpty { return "导入完成，有资料需要处理" }
        return "导入完成"
    }

    var summary: String {
        if wasCancelled || error != nil {
            return "已保留 \(report.imported.count) 份索引 · \(report.failures.count) 份需处理"
        }
        return report.summary
    }

    var plainText: String {
        var lines = [title, knowledgeBaseName, summary]
        if let error { lines.append(error) }
        lines += report.imported.map { "已索引：\($0.fileName)" }
        lines += report.skipped.map { "已跳过：\($0)" }
        lines += report.failures.map { "需处理：\($0)" }
        return lines.joined(separator: "\n")
    }
}

struct ReindexActivity {
    let id = UUID()
    var total: Int
    var processed = 0
    var succeeded = 0
    var currentDocumentID: String?
    var currentTitle = ""
    var failures: [String] = []
    var startedAt = Date()
}

enum NoteSaveState: Equatable {
    case saved, pending, saving, failed(String)

    var label: String {
        switch self {
        case .saved: "已保存到本机"
        case .pending: "等待保存"
        case .saving: "正在保存…"
        case .failed: "保存失败，内容仍保留在编辑器中"
        }
    }
}
