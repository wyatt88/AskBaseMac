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
            HStack {
                Text("只检索当前知识库 · 最多返回 \(state.settings.topK) 个片段")
                Spacer()
                Text("无需回答模型")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 30).padding(.bottom, 20)
            Divider()
            results
        }
        .onAppear { queryFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(AppPalette.accent)
            TextField("输入问题、概念或一段描述", text: $state.searchQuery)
                .textFieldStyle(.plain).font(.system(size: 15))
                .focused($queryFocused)
                .onSubmit { if !state.isSearching { state.runSearch() } }
                .accessibilityIdentifier("semanticSearchQuery")
            if state.isSearching {
                Button("取消") { state.cancelSearch() }.controlSize(.regular)
            } else {
                Button("搜索") { state.runSearch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || state.readyDocumentCount == 0)
                    .accessibilityIdentifier("semanticSearchSubmit")
            }
        }
        .padding(13)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            queryFocused ? AppPalette.accent.opacity(0.5) : AppPalette.line, lineWidth: 1
        ))
    }

    @ViewBuilder private var results: some View {
        if state.isSearching {
            VStack(spacing: 17) {
                ProgressView()
                Text("正在检索资料…").foregroundStyle(.secondary)
                Button("取消搜索") { state.cancelSearch() }.buttonStyle(.borderless)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = state.searchError {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ErrorPanel(title: "搜索未完成", message: error)
                    HStack {
                        Button("重试搜索") { state.runSearch() }.buttonStyle(.borderedProminent)
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
                            Text("点击来源核对原文").font(.caption).foregroundStyle(.secondary)
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
                       detail: "把你选择的文件导入当前知识库，完成索引后，就能按内容含义搜索。") {
                Button("导入资料…") { state.chooseImport() }
                    .buttonStyle(.borderedProminent).disabled(!state.canImport)
            }
        } else if state.readyDocumentCount == 0 {
            EmptyState(symbol: "hourglass", title: "资料尚未完成索引",
                       detail: "完成索引后即可搜索。若有资料处理失败，可在资料库查看具体原因并重新索引。") {
                Button("查看资料状态") { state.section = .library }
            }
        } else {
            EmptyState(symbol: "sparkle.magnifyingglass", title: "用一句话，找到相关资料",
                       detail: "描述你想了解的内容。搜索结果会保留文档名称、原文片段，以及 PDF 中的页码。") {
                EmptyView()
            }
        }
    }
}
