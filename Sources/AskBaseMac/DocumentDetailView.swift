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

    private var document: LibraryDocument? {
        state.snapshot.documents.first { $0.id == documentID }
    }
    private var loadKey: String {
        "\(documentID):\(document?.updatedAt.timeIntervalSince1970 ?? 0):\(document?.chunkCount ?? 0)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                if let document {
                    header(document)
                    if let error = document.errorMessage, document.status == .failed {
                        ErrorPanel(title: "索引未完成", message: error, actionTitle: "重试索引",
                                   isActionDisabled: state.reindexActivity != nil || state.importActivity != nil) {
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
                } else {
                    Label("来源已移除", systemImage: "doc.badge.ellipsis").font(.headline)
                    Text("这份资料已不在当前资料库中，无法打开原始文件。")
                        .foregroundStyle(.secondary)
                }
                if let source {
                    sourceExcerpt(source)
                }
                if document != nil {
                    Divider()
                    HStack {
                        Text("文档内容").font(.headline)
                        Spacer()
                        if !chunks.isEmpty {
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
                    } else if chunks.isEmpty {
                        Text(document?.status == .ready ? "当前没有可显示的文字片段。" : "索引完成后，这里会显示可检索的文字。你仍可打开已保存的原始文件。")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(chunks) { chunk in
                                chunkContent(chunk)
                            }
                        }
                    }
                }
            }
            .padding(25)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                .disabled(state.changingDocumentIDs.contains(document.id))
            }
            Text(document.fileName).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
                    .disabled(state.changingDocumentIDs.contains(document.id))
                Spacer(minLength: 0)
                Menu {
                    Button("在 Finder 中显示") { state.openOriginal(document.id, reveal: true) }
                    Button(document.status == .failed ? "重试索引" : "重建索引") { state.reindex(document) }
                        .disabled(document.status == .indexing || state.reindexActivity != nil || state.importActivity != nil)
                    Divider()
                    Button("删除资料…", role: .destructive) { state.requestDelete(document) }
                        .disabled(document.status == .indexing || state.reindexingDocumentIDs.contains(document.id) || state.isDeleting)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("更多资料操作")
            }
            if document.tags.isEmpty {
                Button { editingMetadata = true } label: {
                    Label("添加标签", systemImage: "tag")
                }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(document.tags, id: \.self) { TagLabel(text: $0) }
                }
            }
        }
    }

    private func sourceExcerpt(_ source: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("所选引用", systemImage: "quote.opening").font(.callout.weight(.semibold))
                Spacer()
                if let page = source.page {
                    Text("第 \(page) 页").font(.caption).foregroundStyle(.secondary)
                }
                CopyTextButton(text: source.text)
            }
            Text(source.text).font(.body).lineSpacing(5).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(17)
        .background(AppPalette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppPalette.accent.opacity(0.16)))
    }

    private func chunkContent(_ chunk: DocumentChunk) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(chunk.page.map { "第 \($0) 页 · 片段 \(chunk.ordinal + 1)" } ?? "片段 \(chunk.ordinal + 1)")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                CopyTextButton(text: chunk.text)
            }
            Text(chunk.text).font(.body).lineSpacing(5).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider().padding(.top, 3)
        }
        .id(chunk.id)
    }

    private func loadChunks() async {
        guard document != nil else { chunks = []; return }
        loading = true
        loadError = nil
        do {
            let result = try await state.chunks(for: documentID)
            guard !Task.isCancelled else { return }
            chunks = result
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
        loading = false
    }
}

struct SourceDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: SearchResult

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("引用来源", systemImage: "doc.text.magnifyingglass").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            DocumentDetailView(documentID: source.documentID, source: source)
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
                            try await state.updateDocument(id: document.id, title: title, tags: tags)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                            saving = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 128)
            }
        }
        .padding(28).frame(width: 480)
        .background(AppPalette.canvas)
        .interactiveDismissDisabled(saving)
    }
}
