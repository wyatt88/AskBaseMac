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

enum SearchInput: Equatable {
    case text(String)
    case media(URL)

    var methodLabel: String {
        switch self {
        case .text: "文字查询"
        case .media: "媒体文件查询"
        }
    }

    var summary: String {
        switch self {
        case .text(let query): query
        case .media(let url): url.lastPathComponent
        }
    }
}

/// Capability labels describe the last health response, never the file extension
/// or the fact that the service happens to be reachable.
struct EmbeddingCapabilities {
    let status: ModelStatus?
    var checking = false

    private var modalities: [String] {
        Array(Set((status?.embeddingModalities ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })).sorted()
    }

    var reportedLabel: String {
        guard !checking else { return "正在检测模型模态…" }
        guard status != nil else { return "模型模态尚未检测" }
        guard !modalities.isEmpty else { return "服务未报告支持的模态" }
        let known = ["text", "code", "image", "audio", "video"]
        let ordered = known.filter { modalities.contains($0) } + modalities.filter { !known.contains($0) }
        return "模型报告：\(ordered.map(Self.label).joined(separator: "、"))"
    }

    var mediaUnavailableReason: String? {
        if checking { return "媒体能力正在检测，请等待连接检查完成。" }
        guard let status else { return "媒体能力尚未检测；请到设置中测试连接。" }
        guard status.embeddingAvailable else { return "媒体索引尚未就绪：\(status.embeddingDetail)" }
        guard !modalities.isEmpty else {
            return "当前服务未报告模态，尚不能确认媒体能力；请更新本机嵌入服务后测试连接。"
        }
        let missing = ["image", "audio", "video"].filter { !modalities.contains($0) }
        guard !missing.isEmpty else { return nil }
        return "\(missing.map(Self.label).joined(separator: "、"))尚未就绪：当前嵌入服务未报告这些模态的支持。"
    }

    private static func label(_ modality: String) -> String {
        switch modality {
        case "text": "文本"
        case "code": "代码"
        case "image": "图片"
        case "audio": "音频"
        case "video": "视频"
        default: modality
        }
    }
}

enum MediaEvidence {
    static func isReadable(text: String, media: MediaReference?) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (media == nil || media?.textSource == .ocr)
    }

    static func summary(for media: MediaReference) -> String {
        media.kind == .image
            ? "媒体语义索引；可查看原图。此处没有可读的 OCR 文字。"
            : "媒体语义索引；可播放原片段。此处没有语音转写。"
    }

    static func position(for media: MediaReference) -> String {
        if media.kind == .image, let index = media.imageIndex {
            guard index >= 0, index < Int.max else { return "帧／页位置无效" }
            return "第 \(index + 1) 帧／页"
        }
        return media.positionLabel
    }
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
