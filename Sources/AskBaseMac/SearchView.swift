import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "语义搜索", subtitle: "按含义查找「\(state.selectedKnowledgeBase?.name ?? "")」中的资料") {
                StatusPill(
                    label: state.isCheckingConnections ? "正在检测 EG2"
                        : state.modelStatus?.embeddingAvailable == true ? "EG2 已连接"
                        : state.modelStatus == nil ? "EG2 未检测" : "EG2 未就绪",
                    color: state.modelStatus?.embeddingAvailable == true ? AppPalette.accent : .secondary
                )
            }
            searchField.padding(.horizontal, 28).padding(.bottom, 15)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("只检索当前知识库 · 最多返回 \(state.settings.topK) 个片段")
                    Spacer()
                    Text("无需回答模型")
                }
                if let input = state.searchedInput, state.hasSearched || state.isSearching {
                    Text("本次\(input.methodLabel)：\(input.summary)")
                        .lineLimit(2).help(input.summary).textSelection(.enabled)
                }
                if let notice = state.searchNotice {
                    Text(notice).accessibilityIdentifier("searchNotice")
                }
                EmbeddingCapabilityNote(capabilities: state.embeddingCapabilities)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 30).padding(.bottom, 20)
            Divider()
            results
        }
        .onAppear { queryFocused = true }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                Text(state.searchMediaURL == nil ? "查询方式：文字" : "查询方式：媒体文件")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if state.searchMediaURL != nil {
                    Button("改用文字搜索") {
                        state.useTextSearch()
                        queryFocused = true
                    }
                    .controlSize(.small)
                    .disabled(state.isSearching || state.isChoosingSearchMedia)
                }
                Spacer(minLength: 0)
                Button {
                    queryFocused = false
                    state.chooseMediaSearch()
                } label: {
                    Label(state.isChoosingSearchMedia ? "正在选择…" : "用媒体搜索…", systemImage: "photo.on.rectangle")
                }
                .controlSize(.small)
                .disabled(!state.canChooseSearchMedia)
                .help("选择本机图片、音频或视频，按文件内容检索")
                .accessibilityIdentifier("chooseMediaSearch")
            }
            HStack(spacing: 13) {
                Image(systemName: state.searchMediaURL == nil ? "magnifyingglass" : "paperclip")
                    .font(.title3).foregroundStyle(AppPalette.accent)
                if let url = state.searchMediaURL {
                    Text(url.lastPathComponent).font(.system(size: 15))
                        .lineLimit(2).help(url.lastPathComponent).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("mediaSearchFileName")
                } else {
                    TextField("输入问题、概念或一段描述", text: $state.searchQuery)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        .focused($queryFocused)
                        .onSubmit { state.runSearch() }
                        .accessibilityIdentifier("semanticSearchQuery")
                }
                if state.isSearching {
                    Button(state.isCancellingSearch ? "正在停止…" : "取消") { state.cancelSearch() }
                        .controlSize(.regular).disabled(state.isCancellingSearch)
                } else {
                    Button(state.searchMediaURL == nil ? "搜索" : "按媒体内容搜索") { state.runSearch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.canSearch)
                        .accessibilityIdentifier("semanticSearchSubmit")
                }
            }
            .padding(13)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                queryFocused ? AppPalette.accent.opacity(0.5) : AppPalette.line, lineWidth: 1
            ))
            if state.searchMediaURL != nil {
                Text("按媒体内容处理全部片段。此查询文件不会导入资料库。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var results: some View {
        if state.isSearching {
            VStack(spacing: 17) {
                ProgressView()
                Text(state.isCancellingSearch ? "正在停止搜索…"
                     : state.searchMediaURL == nil ? "正在检索资料…" : "正在读取媒体并检索全部片段…")
                    .foregroundStyle(.secondary)
                Button("取消搜索") { state.cancelSearch() }.buttonStyle(.borderless)
                    .disabled(state.isCancellingSearch)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = state.searchError {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ErrorPanel(title: "搜索未完成", message: error)
                    HStack {
                        Button("重试搜索") { state.runSearch() }.buttonStyle(.borderedProminent).disabled(!state.canSearch)
                        Button("前往资料库重新索引") { state.section = .library }
                        Button("模型设置") { state.section = .settings }
                    }
                }.padding(28)
            }
        } else if state.hasSearched {
            if state.searchResults.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "未找到可用的资料片段",
                           detail: "换一种描述再试，或检查相关资料是否已导入并完成索引。") {
                    Button("查看资料库") { state.section = .library }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(state.searchResults.count) 个相关片段").font(.callout.weight(.medium))
                            Spacer()
                            Text("点击来源查看原文或播放媒体").font(.caption).foregroundStyle(.secondary)
                        }.padding(.bottom, 4)
                        ForEach(Array(state.searchResults.enumerated()), id: \.element.id) { index, source in
                            SourceCard(source: source, number: index + 1) {
                                state.sheet = .source(source)
                            }
                        }
                        Text("排序分数用于比较检索结果，不是事实置信度。")
                            .font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                    }
                    .padding(28)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
            }
        } else if state.documents.isEmpty {
            EmptyState(symbol: "doc.text.magnifyingglass", title: "先添加要查找的资料",
                       detail: "导入文本、图片、音频或视频。完成索引后，可用文字描述或本机媒体文件搜索；媒体能力以当前模型报告为准。") {
                Button("导入资料…") { state.chooseImport() }
                    .buttonStyle(.borderedProminent).disabled(!state.canImport)
            }
        } else if state.readyDocumentCount == 0 {
            EmptyState(symbol: "hourglass", title: "资料尚未完成索引",
                       detail: "完成索引后即可搜索。若有资料处理失败，可在资料库查看具体原因并重新索引。") {
                Button("查看资料状态") { state.section = .library }
            }
        } else {
            EmptyState(symbol: "sparkle.magnifyingglass",
                       title: state.searchMediaURL == nil ? "用文字或媒体，找到相关资料" : "媒体查询文件已保留",
                       detail: "输入描述，或选择图片、音频、视频作为查询。结果保留原文、OCR 文字、页码或媒体时间；点击来源查看原图或播放片段。") {
                EmptyView()
            }
        }
    }
}
