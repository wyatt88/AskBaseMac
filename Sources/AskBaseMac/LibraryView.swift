import SwiftUI
import AskBaseCore

struct LibraryView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "资料库", subtitle: subtitle) {
                if !state.documents.isEmpty {
                    Menu {
                        Button("重建全部索引（\(state.documents.count) 份）") {
                            state.reindexDocuments(state.documents)
                        }
                        let failed = state.documents.filter { $0.status == .failed }
                        Button("重试失败资料（\(failed.count) 份）") {
                            state.reindexDocuments(failed)
                        }.disabled(failed.isEmpty)
                    } label: {
                        Label("重新索引", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .fixedSize()
                    .disabled(state.importActivity != nil || state.reindexActivity != nil || state.isDeleting)
                    .help("模型版本改变后，可按顺序重建本库的全部索引")
                }
                Button { state.chooseImport() } label: {
                    Label(state.isChoosingFiles ? "选择中…" : "导入资料…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.canImport)
                .help("选择文件或文件夹，也可以直接拖入窗口（⌘I）")
            }
            EmbeddingCapabilityNote(capabilities: state.embeddingCapabilities)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.bottom, 15)
            if state.documents.isEmpty {
                Divider()
                EmptyState(symbol: "tray.and.arrow.down", title: "从第一份资料开始",
                           detail: "选择文本、图片、音频、视频或文件夹。不设大小、数量或总时长配额，按内容识别并检查模型能力。文字和 OCR 可用于问答；其他媒体可搜索并回到原件核对。") {
                    VStack(spacing: 11) {
                        Button("选择文件或文件夹…") { state.chooseImport() }
                            .buttonStyle(.borderedProminent).disabled(!state.canImport)
                        Text("仅导入你选择的资料").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            } else {
                filters
                Divider()
                HSplitView {
                    documentList
                        .frame(minWidth: 300, idealWidth: 350, maxWidth: 480)
                    Group {
                        if let id = state.selectedDocumentID {
                            DocumentDetailView(documentID: id)
                                .id(id)
                        } else {
                            EmptyState(symbol: "doc.text.magnifyingglass", title: "选择一份资料",
                                       detail: "在此查看文字和图片、播放音视频片段、整理标签，或打开保存在本机的原始文件。") {
                                EmptyView()
                            }
                        }
                    }
                    .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppPalette.surface)
                }
            }
        }
        .onChange(of: state.filteredDocuments.map(\.id)) { _, ids in
            if let selected = state.selectedDocumentID, !ids.contains(selected) {
                state.selectedDocumentID = nil
            }
        }
    }

    private var subtitle: String {
        let base = state.selectedKnowledgeBase?.name ?? ""
        guard !state.documents.isEmpty else { return base }
        return "\(base) · \(state.documents.count) 份资料 · \(state.readyDocumentCount) 份可检索"
    }

    private var filters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选名称或标签", text: $state.libraryFilter)
                    .textFieldStyle(.plain).accessibilityLabel("筛选资料名称或标签")
                if !state.libraryFilter.isEmpty {
                    Button { state.libraryFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("清除筛选")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(AppPalette.line))
            .frame(minWidth: 150, maxWidth: .infinity)

            Toggle(isOn: $state.favoritesOnly) {
                Label("收藏", systemImage: state.favoritesOnly ? "star.fill" : "star")
            }
            .toggleStyle(.button).help("只显示收藏的资料")
            Picker("标签", selection: $state.tagFilter) {
                Text("全部标签").tag("")
                ForEach(state.allTags, id: \.self) { tag in Text(tag).tag(tag) }
            }
            .labelsHidden().frame(width: 120)
            Picker("排序", selection: $state.documentSort) {
                ForEach(DocumentSort.allCases) { sort in Text(sort.rawValue).tag(sort) }
            }
            .labelsHidden().frame(width: 104)
        }
        .padding(.horizontal, 28).padding(.bottom, 18)
    }

    private var documentList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(state.filteredDocuments.count) 份资料").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if state.favoritesOnly || !state.tagFilter.isEmpty || !state.libraryFilter.isEmpty {
                    Button("清除筛选") {
                        state.libraryFilter = ""
                        state.favoritesOnly = false
                        state.tagFilter = ""
                    }.font(.caption).buttonStyle(.borderless)
                }
            }.padding(.horizontal, 17).padding(.vertical, 13)
            if state.filteredDocuments.isEmpty {
                EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "没有匹配的资料",
                           detail: "试试其他名称，或清除收藏和标签筛选。") { EmptyView() }
            } else {
                List(selection: $state.selectedDocumentID) {
                    ForEach(state.filteredDocuments) { document in
                        DocumentRow(document: document)
                            .tag(document.id)
                            .padding(.vertical, 9)
                            .contextMenu {
                                Button("打开原始文件") { state.openOriginal(document.id) }
                                Button(document.isFavorite ? "取消收藏" : "收藏") { state.toggleFavorite(document) }
                                    .disabled(state.changingDocumentIDs.contains(document.id))
                                Button(document.status == .failed ? "重试索引" : "重建索引") { state.reindex(document) }
                                    .disabled(document.status == .indexing || state.reindexActivity != nil || state.importActivity != nil)
                                Divider()
                                Button("删除资料…", role: .destructive) { state.requestDelete(document) }
                                    .disabled(document.status == .indexing || state.reindexingDocumentIDs.contains(document.id) || state.isDeleting)
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppPalette.canvas)
    }
}

struct DocumentRow: View {
    @EnvironmentObject private var state: AppState
    let document: LibraryDocument

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: document.fileSymbol)
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 37, height: 43)
                .background(AppPalette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 5) {
                    Text(document.title).font(.body.weight(.medium)).lineLimit(2).help(document.title)
                    Spacer(minLength: 3)
                    Button { state.toggleFavorite(document) } label: {
                        Image(systemName: document.isFavorite ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(document.isFavorite ? AppPalette.accent : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(document.isFavorite ? "取消收藏" : "收藏")
                    .disabled(state.changingDocumentIDs.contains(document.id))
                }
                HStack(spacing: 6) {
                    Text(document.displayFileType)
                    Text("·")
                    Text(document.formattedSize)
                }.font(.caption).foregroundStyle(.secondary)
                if let media = document.media {
                    if MediaEvidence.position(for: media) != media.kind.label {
                        Text(MediaEvidence.position(for: media)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let label = media.textSource?.label {
                        Label(label, systemImage: "text.viewfinder").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    DocumentStatusLabel(status: document.status,
                                        reindexing: state.reindexActivity?.currentDocumentID == document.id,
                                        queued: state.reindexingDocumentIDs.contains(document.id))
                    Spacer(minLength: 4)
                    Button { state.reindex(document) } label: {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(document.status == .indexing || state.importActivity != nil || state.reindexActivity != nil)
                    .help(document.status == .failed ? "重试这份资料的索引" : "重新索引这份资料")
                }
                if !document.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(document.tags.prefix(2)), id: \.self) { TagLabel(text: $0) }
                        if document.tags.count > 2 {
                            Text("+\(document.tags.count - 2)").font(.caption).foregroundStyle(.secondary)
                                .help(document.tags.joined(separator: "、"))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}
