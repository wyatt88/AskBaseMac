import SwiftUI
import AskBaseCore

struct DocumentDetailView: View {
    @EnvironmentObject private var state: AppState
    let documentID: String
    var source: SearchResult? = nil
    @State private var chunks: [DocumentChunk] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var editingMetadata = false
    @State private var selectedChunkID: String?
    @State private var loadedKey: String?
    @State private var previewSelectionRevision = 0

    private var document: LibraryDocument? {
        state.documents.first { $0.id == documentID }
    }
    private var loadKey: String {
        "\(state.selectedKnowledgeBaseID ?? ""):\(documentID):\(document?.updatedAt.timeIntervalSince1970 ?? 0):\(document?.chunkCount ?? 0):\(source?.id ?? "")"
    }
    private var previewMedia: MediaReference? {
        if loadedKey == loadKey, let selectedChunkID,
           let media = chunks.first(where: { $0.id == selectedChunkID })?.media {
            return media
        }
        return source?.media ?? document?.media
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    if let document {
                        header(document)
                        if let error = document.errorMessage, document.status == .failed {
                            ErrorPanel(title: "索引未完成", message: error, actionTitle: "重试索引",
                                       isActionDisabled: !state.canReindex) {
                                state.reindex(document)
                            }
                        }
                        if document.status == .indexing || state.reindexActivity?.currentDocumentID == document.id {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("正在为资料建立检索索引…").font(.callout).foregroundStyle(.secondary)
                            }
                        } else if state.reindexingDocumentIDs.contains(document.id) {
                            Label("已加入队列，等待重新索引", systemImage: "clock")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let media = previewMedia {
                            MediaPreviewView(document: document, media: media,
                                             selectionRevision: previewSelectionRevision)
                                .id("media-preview")
                        }
                        if let source {
                            sourceExcerpt(source)
                        }
                        Divider()
                        HStack {
                            Text(document.media == nil ? "文档内容" : "索引片段").font(.headline)
                            Spacer()
                            if loadedKey == loadKey, !chunks.isEmpty {
                                Text("\(chunks.count) 个片段").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if loading {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("正在读取内容…").foregroundStyle(.secondary)
                            }.padding(.vertical, 18)
                        } else if let loadError {
                            ErrorPanel(title: "无法读取内容", message: loadError, actionTitle: "重新读取") {
                                Task { await loadChunks() }
                            }
                        } else if loadedKey != loadKey || chunks.isEmpty {
                            Text(document.status == .ready ? "当前没有可显示的索引片段。" : "索引完成后，这里会显示可检索的片段。你仍可查看已保存的原始文件。")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                ForEach(chunks) { chunk in
                                    chunkContent(chunk) {
                                        selectedChunkID = chunk.id
                                        previewSelectionRevision += 1
                                        withAnimation { proxy.scrollTo("media-preview", anchor: .top) }
                                    }
                                }
                            }
                        }
                    } else {
                        Label("来源已移除", systemImage: "doc.badge.ellipsis").font(.headline)
                        Text("这份资料已不在当前知识库中，无法继续显示旧片段或预览。")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(25)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(AppPalette.surface)
        .task(id: loadKey) { await loadChunks() }
        .sheet(isPresented: $editingMetadata) {
            if let document { DocumentMetadataEditor(document: document) }
        }
    }

    private func header(_ document: LibraryDocument) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                Text(document.title).font(.title2.weight(.semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Button { state.toggleFavorite(document) } label: {
                    Image(systemName: document.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(document.isFavorite ? AppPalette.accent : .secondary)
                }
                .buttonStyle(.borderless)
                .help(document.isFavorite ? "取消收藏" : "收藏资料")
                .disabled(!state.canEditDocument(document.id))
            }
            Text(document.fileName).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let media = document.media {
                Label("\(media.kind.label) · \(MediaEvidence.position(for: media))", systemImage: media.kind.symbol)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                DocumentStatusLabel(status: document.status,
                                    reindexing: state.reindexActivity?.currentDocumentID == document.id,
                                    queued: state.reindexingDocumentIDs.contains(document.id))
                Text(document.formattedSize).font(.caption).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(document.createdAt, format: .dateTime.year().month().day())
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                Button { state.openOriginal(document.id) } label: {
                    Label("打开原文件", systemImage: "arrow.up.right.square")
                }.controlSize(.small)
                Button("编辑信息") { editingMetadata = true }.controlSize(.small)
                    .disabled(!state.canEditDocument(document.id))
                Spacer(minLength: 0)
                Menu {
                    Button("在 Finder 中显示") { state.openOriginal(document.id, reveal: true) }
                    Button(document.status == .failed ? "重试索引" : "重建索引") { state.reindex(document) }
                        .disabled(document.status == .indexing || !state.canReindex)
                    Divider()
                    Button("删除资料…", role: .destructive) { state.requestDelete(document) }
                        .disabled(!state.canDeleteDocument(document))
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("更多资料操作")
            }
            if document.tags.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 14) {
                        Button { state.matchTags(documentID: document.id) } label: {
                            Label("匹配主题标签", systemImage: "tag")
                        }
                        .controlSize(.small).disabled(!state.canTagDocument(document.id))
                        .accessibilityIdentifier("matchDocumentTags")
                        Button("手动添加") { editingMetadata = true }
                            .buttonStyle(.borderless).font(.caption)
                            .disabled(!state.canEditDocument(document.id))
                    }
                    Text("复用本机 EmbeddingGemma 2 匹配主题标签，无需额外下载模型。匹配后可手动编辑。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if document.status != .ready {
                        Text("索引完成后可匹配标签。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(document.tags, id: \.self) { TagLabel(text: $0) }
                }
            }
            if state.taggingDocumentIDs.contains(document.id) {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.mini)
                    Text(state.isCancellingTagging ? "正在停止…"
                         : state.taggingActivity?.currentDocumentID == document.id ? "正在匹配主题…" : "等待匹配主题…")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("停止匹配") { state.cancelTagging() }
                        .controlSize(.small).disabled(state.isCancellingTagging)
                }
            } else if let outcome = state.taggingOutcome, !outcome.activity.isBatch,
                      outcome.activity.knowledgeBaseID == state.selectedKnowledgeBaseID,
                      outcome.activity.documentIDs.contains(document.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(outcome.wasCancelled ? "主题标签匹配已停止，已写入的标签保留。"
                         : outcome.activity.succeeded > 0 ? "已匹配主题标签，可在“编辑信息”中调整。"
                         : outcome.activity.failures.isEmpty ? "未找到合适标签或资料已变更，可手动添加。"
                         : "主题标签匹配失败，资料仍可检索。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(outcome.activity.failures.enumerated()), id: \.offset) { _, failure in
                        Text(failure).font(.caption).foregroundStyle(.orange)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func sourceExcerpt(_ source: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("检索命中片段", systemImage: source.media?.kind.symbol ?? "quote.opening")
                    .font(.callout.weight(.semibold))
                Spacer()
                if let media = source.media {
                    Text(MediaEvidence.position(for: media)).font(.caption).foregroundStyle(.secondary)
                } else if let page = source.page {
                    Text("第 \(page) 页").font(.caption).foregroundStyle(.secondary)
                }
                if source.hasReadableEvidence, MediaEvidence.isReadable(text: source.text, media: source.media) {
                    CopyTextButton(text: source.text)
                }
            }
            if source.hasReadableEvidence, MediaEvidence.isReadable(text: source.text, media: source.media) {
                if let label = source.media?.textSource?.label {
                    Label(label, systemImage: "text.viewfinder").font(.caption).foregroundStyle(AppPalette.accent)
                }
                Text(source.text).font(.body).lineSpacing(5).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let media = source.media {
                Text(MediaEvidence.summary(for: media)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(17)
        .background(AppPalette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppPalette.accent.opacity(0.16)))
    }

    private func chunkContent(_ chunk: DocumentChunk, select: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(chunk.media.map { "\($0.kind.label) · \(MediaEvidence.position(for: $0)) · 片段 \(chunk.ordinal + 1)" }
                     ?? chunk.page.map { "第 \($0) 页 · 片段 \(chunk.ordinal + 1)" } ?? "片段 \(chunk.ordinal + 1)")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if MediaEvidence.isReadable(text: chunk.text, media: chunk.media) {
                    CopyTextButton(text: chunk.text)
                }
            }
            if let media = chunk.media {
                Button(action: select) {
                    Label(media.kind == .image ? "查看这一帧／页" : "定位到这个片段",
                          systemImage: media.kind == .image ? "photo" : "play.rectangle")
                }
                .controlSize(.small)
                .accessibilityIdentifier("previewChunk-\(chunk.id)")
            }
            if MediaEvidence.isReadable(text: chunk.text, media: chunk.media) {
                if let label = chunk.media?.textSource?.label {
                    Label(label, systemImage: "text.viewfinder").font(.caption).foregroundStyle(AppPalette.accent)
                }
                Text(chunk.text).font(.body).lineSpacing(5).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let media = chunk.media {
                Text(MediaEvidence.summary(for: media)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.top, 3)
        }
        .id(chunk.id)
    }

    private func loadChunks() async {
        let key = loadKey
        chunks = []
        loadedKey = nil
        selectedChunkID = nil
        guard document != nil else { loading = false; loadError = nil; return }
        loading = true
        loadError = nil
        defer { if loadKey == key { loading = false } }
        do {
            let result = try await state.chunks(for: documentID)
            guard !Task.isCancelled, loadKey == key, document != nil else { return }
            chunks = result
            loadedKey = key
        } catch {
            guard !Task.isCancelled, loadKey == key, document != nil else { return }
            loadError = error.localizedDescription
        }
    }
}

struct SourceDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: SearchResult

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(source.media.map { "\($0.kind.label)来源" } ?? "引用来源",
                      systemImage: source.media?.kind.symbol ?? "doc.text.magnifyingglass").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            DocumentDetailView(documentID: source.documentID, source: source)
                .id(source.id)
        }
        .frame(width: 780, height: 630)
        .background(AppPalette.canvas)
    }
}

struct DocumentMetadataEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let document: LibraryDocument
    @State private var title: String
    @State private var tagsText: String
    @State private var saving = false
    @State private var error: String?

    init(document: LibraryDocument) {
        self.document = document
        _title = State(initialValue: document.title)
        _tagsText = State(initialValue: document.tags.joined(separator: "，"))
    }

    private var tags: [String] {
        Array(Set(tagsText.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("编辑资料信息").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 7) {
                Text("标题").font(.callout.weight(.medium))
                TextField("资料标题", text: $title).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("标签").font(.callout.weight(.medium))
                TextField("用逗号分隔标签", text: $tagsText).textFieldStyle(.roundedBorder)
                Text("最多 12 个标签，每个不超过 32 字。").font(.caption).foregroundStyle(.secondary)
            }
            if let error { ErrorPanel(title: "无法保存", message: error) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("保存") {
                    saving = true
                    error = nil
                    Task {
                        do {
                            guard tags.count <= 12, tags.allSatisfy({ $0.count <= 32 }) else {
                                throw AskBaseError.invalidInput("最多可添加 12 个标签，每个标签不超过 32 字。")
                            }
                            try await state.updateDocument(
                                id: document.id, title: title == document.title ? nil : title,
                                tags: tags == document.tags.sorted() ? nil : tags
                            )
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                            saving = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(saving || !state.canEditDocument(document.id)
                          || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 128)
            }
        }
        .padding(28).frame(width: 480)
        .background(AppPalette.canvas)
        .interactiveDismissDisabled(saving)
    }
}
