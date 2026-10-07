import SwiftUI
import UniformTypeIdentifiers
import AskBaseCore

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if let error = state.startupError {
                startupFailure(error)
            } else if !state.hasStarted {
                VStack(spacing: 18) {
                    ProgressView().controlSize(.large)
                    Text("正在打开本地资料库").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                workspace
            }
        }
        .background(AppPalette.canvas)
        .sheet(item: $state.sheet) { item in
            switch item {
            case .knowledgeBase(let base):
                KnowledgeBaseEditor(existing: base)
            case .source(let source):
                SourceDetailSheet(source: source)
            case .importReport:
                ImportReportSheet()
            case .issue(let issue):
                IssueSheet(issue: issue)
            }
        }
        .alert(
            state.deletion?.title ?? "确认删除",
            isPresented: Binding(
                get: { state.deletion != nil },
                set: { if !$0 { state.deletion = nil } }
            ),
            presenting: state.deletion
        ) { request in
            Button("取消", role: .cancel) { state.deletion = nil }
            Button("永久删除", role: .destructive) { state.confirmDelete(request) }
        } message: { request in
            Text(request.explanation)
        }
    }

    private var workspace: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 232, max: 290)
        } detail: {
            VStack(spacing: 0) {
                if state.importActivity != nil || state.importOutcome != nil || state.isReadingDrop
                    || state.reindexActivity != nil {
                    ImportStatusBar()
                    Divider()
                }
                if let notice = state.notice {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").foregroundStyle(AppPalette.accent)
                        Text(notice).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { state.notice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("关闭提示")
                    }
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(AppPalette.accent.opacity(0.06))
                }
                content
            }
            .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
            .background(AppPalette.canvas)
            .overlay {
                if isDropTargeted, state.canImport {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(AppPalette.canvas.opacity(0.96))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(AppPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        }
                        .overlay {
                            VStack(spacing: 16) {
                                Image(systemName: "tray.and.arrow.down").font(.system(size: 38, weight: .light))
                                Text("松开以导入到「\(state.selectedKnowledgeBase?.name ?? "")」")
                                    .font(.title3.weight(.medium))
                                Text("支持文件和文件夹").font(.callout).foregroundStyle(.secondary)
                            }.foregroundStyle(AppPalette.accent)
                        }
                        .padding(16)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) {
                state.acceptDrop($0)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("AskBase Local").font(.headline)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if state.section == .settings {
            SettingsView()
        } else if state.selectedKnowledgeBase == nil {
            EmptyState(symbol: "books.vertical", title: "为你的资料建一个家",
                       detail: "创建知识库后，再选择要导入的本机文件。每个知识库的资料、对话与笔记分别保存。") {
                Button("新建知识库…") { state.sheet = .knowledgeBase(nil) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            switch state.section {
            case .library: LibraryView()
            case .search: SearchView()
            case .chat: ChatView()
            case .notes: NotesView()
            case .settings: SettingsView()
            }
        }
    }

    private func startupFailure(_ message: String) -> some View {
        VStack(spacing: 22) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 38, weight: .light)).foregroundStyle(.orange)
            Text("暂时无法打开资料库").font(.title2.weight(.semibold))
            ScrollView {
                Text(message).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: 620, maxHeight: 230)
            HStack {
                CopyTextButton(text: message)
                Button("重试") { Task { await state.start() } }.buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(AppPalette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AskBase").font(.system(size: 20, weight: .semibold))
                    Text("LOCAL").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(2.3).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 21).padding(.top, 22).padding(.bottom, 23)

            List {
                Section("知识库") {
                    ForEach(state.snapshot.knowledgeBases) { base in
                        Button {
                            state.selectKnowledgeBase(base.id)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: base.id == state.selectedKnowledgeBaseID ? "folder.fill" : "folder")
                                    .foregroundStyle(base.id == state.selectedKnowledgeBaseID ? AppPalette.accent : .secondary)
                                Text(base.name).lineLimit(1).help(base.name)
                                Spacer(minLength: 4)
                                Text("\(state.snapshot.documents.filter { $0.knowledgeBaseID == base.id }.count)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(base.id == state.selectedKnowledgeBaseID ? AppPalette.accent.opacity(0.1) : Color.clear)
                        .contextMenu {
                            Button("重命名…") { state.sheet = .knowledgeBase(base) }
                            Button("删除知识库…", role: .destructive) { state.requestDelete(base) }
                                .disabled(state.knowledgeBaseIsBusy(base.id) || state.isDeleting)
                        }
                    }
                    Button {
                        state.sheet = .knowledgeBase(nil)
                    } label: {
                        Label("新建知识库", systemImage: "plus").font(.callout)
                            .foregroundStyle(.secondary).padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }

                Section("工作空间") {
                    ForEach(WorkspaceSection.allCases) { section in
                        Button {
                            state.section = section
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: section.symbol).frame(width: 18)
                                Text(section.title)
                                Spacer()
                            }
                            .font(.body.weight(state.section == section ? .medium : .regular))
                            .foregroundStyle(state.section == section ? AppPalette.accent : .primary)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(state.section == section ? AppPalette.accent.opacity(0.1) : Color.clear)
                        .accessibilityAddTraits(state.section == section ? .isSelected : [])
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            if let base = state.selectedKnowledgeBase {
                HStack {
                    Text("管理当前知识库").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("重命名「\(base.name)」…") { state.sheet = .knowledgeBase(base) }
                        Button("删除知识库…", role: .destructive) { state.requestDelete(base) }
                            .disabled(state.knowledgeBaseIsBusy(base.id) || state.isDeleting)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("重命名或删除当前知识库")
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            Divider().padding(.horizontal, 16)
            Button { state.section = .settings } label: {
                VStack(spacing: 10) {
                    ConnectionLine(title: "EG2 检索", available: state.modelStatus?.embeddingAvailable,
                                   checking: state.isCheckingConnections)
                    ConnectionLine(title: "Ollama 回答", available: state.modelStatus?.chatAvailable,
                                   checking: state.isCheckingConnections)
                }
                .padding(.horizontal, 20).padding(.vertical, 17)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).help("查看模型状态与连接设置")
        }
        .background(AppPalette.inset.opacity(0.55))
    }
}
