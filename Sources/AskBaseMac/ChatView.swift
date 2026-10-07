import SwiftUI
import AskBaseCore

struct ChatView: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "知识问答", subtitle: "让「\(state.selectedKnowledgeBase?.name ?? "")」里的资料参与回答") {
                Button { state.exportConversation() } label: {
                    Label("导出对话", systemImage: "square.and.arrow.up")
                }.disabled(state.messages.isEmpty || state.isAnswering)
                Button {
                    state.selectConversation(nil)
                    composerFocused = true
                } label: { Label("新对话", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            HSplitView {
                history.frame(minWidth: 170, idealWidth: 200, maxWidth: 270)
                VStack(spacing: 0) {
                    conversation
                    if let error = state.chatError {
                        ErrorPanel(title: "本次未能完成回答", message: error, actionTitle: "查看模型设置") {
                            state.section = .settings
                        }
                        .padding(.horizontal, 22).padding(.bottom, 12)
                    }
                    if let notice = state.chatNotice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24).padding(.bottom, 10)
                    }
                    composer
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                .background(AppPalette.surface)
            }
        }
    }

    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本地历史").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(state.conversations.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }.padding(.horizontal, 16).padding(.vertical, 15)
            if state.conversations.isEmpty {
                VStack(spacing: 9) {
                    Text("还没有对话").font(.callout).foregroundStyle(.secondary)
                    Text("提问后会保存在这里").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.top, 25)
                Spacer()
            } else {
                List(selection: Binding(
                    get: { state.selectedConversationID },
                    set: { state.selectConversation($0) }
                )) {
                    ForEach(state.conversations) { conversation in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(conversation.title).font(.callout.weight(.medium)).lineLimit(3)
                                .help(conversation.title)
                            Text(conversation.createdAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 9)
                        .tag(conversation.id)
                        .contextMenu {
                            Button("删除对话…", role: .destructive) { state.requestDelete(conversation) }
                                .disabled(state.isDeleting)
                        }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
            if let id = state.selectedConversationID,
               let conversation = state.conversations.first(where: { $0.id == id }) {
                Divider()
                Button(role: .destructive) { state.requestDelete(conversation) } label: {
                    Label("删除当前对话…", systemImage: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(state.isDeleting)
                .padding(14)
            }
        }
        .background(AppPalette.canvas)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if state.isLoadingMessages {
                    ProgressView("正在读取对话…").padding(50)
                        .frame(maxWidth: .infinity)
                } else if state.messages.isEmpty && state.pendingQuestion == nil {
                    conversationEmptyState.frame(minHeight: 275)
                } else {
                    LazyVStack(alignment: .leading, spacing: 25) {
                        ForEach(state.messages) { message in
                            ChatMessageView(message: message)
                                .id(message.id)
                        }
                        if let question = state.pendingQuestion {
                            UserQuestionView(content: question)
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(state.isCancellingAnswer ? "正在停止生成…" : "正在检索资料并生成回答…")
                                        .font(.callout).foregroundStyle(.secondary)
                                    if let date = state.answerStartedAt { ElapsedLabel(startedAt: date) }
                                }
                                Spacer()
                                Button("停止生成") { state.cancelAnswer() }
                                    .controlSize(.small).disabled(state.isCancellingAnswer)
                            }
                            .padding(15)
                            .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 10))
                        }
                        Color.clear.frame(height: 1).id("conversation-bottom")
                    }
                    .padding(24)
                }
            }
            .onChange(of: state.messages.last?.id) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            .onChange(of: state.pendingQuestion) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder private var conversationEmptyState: some View {
        if state.readyDocumentCount == 0 {
            EmptyState(symbol: "bubble.left.and.text.bubble.right", title: "先为对话准备资料",
                       detail: "导入资料并完成索引后，就可以提问。回答附有检索来源，便于回到原文核对。") {
                Button(state.documents.isEmpty ? "导入资料…" : "查看资料库") {
                    if state.documents.isEmpty { state.chooseImport() }
                    else { state.section = .library }
                }.buttonStyle(.borderedProminent)
                    .disabled(state.documents.isEmpty && !state.canImport)
            }
        } else if state.isCheckingConnections && state.settings.chatModel.isEmpty {
            VStack(spacing: 15) {
                ProgressView()
                Text("正在发现本机回答模型…").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(45)
        } else if state.settings.chatModel.isEmpty {
            EmptyState(symbol: "cpu", title: "选择本机回答模型",
                       detail: "语义搜索已经可以独立使用。到设置中测试 Ollama 连接，再选择实际可用的模型进行问答。") {
                Button("打开模型设置") { state.section = .settings }.buttonStyle(.borderedProminent)
            }
        } else {
            EmptyState(symbol: "quote.bubble", title: "从一个问题开始",
                       detail: "围绕当前知识库提问。点击回答中的引用编号，可以查看资料片段与原始文件。") {
                VStack(spacing: 8) {
                    Label(state.settings.chatModel, systemImage: "cpu").font(.caption)
                        .foregroundStyle(AppPalette.accent).textSelection(.enabled)
                    if state.modelSelectionNotice != nil {
                        Text("已自动选择本机唯一回答模型").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.horizontal, -22)
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text(state.settings.chatModel.isEmpty ? "尚未选择回答模型" : state.settings.chatModel)
                    .lineLimit(1).help(state.settings.chatModel)
                Spacer()
                Button("模型设置") { state.section = .settings }.buttonStyle(.borderless)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.top, 4)

            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if state.chatDraft.isEmpty {
                        Text("向当前知识库提问…")
                            .font(.body).foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $state.chatDraft)
                        .font(.body).scrollContentBackground(.hidden)
                        .focused($composerFocused)
                        .frame(minHeight: 65, maxHeight: 104)
                        .accessibilityLabel("向当前知识库提问")
                        .accessibilityIdentifier("chatQuestion")
                }
                HStack {
                    Text("⌘ ↩ 发送 · 回答请结合原文核对")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if state.isAnswering {
                        Button { state.cancelAnswer() } label: {
                            Label(state.isCancellingAnswer ? "正在停止" : "停止", systemImage: "stop.fill")
                        }.disabled(state.isCancellingAnswer)
                    } else {
                        Button { state.ask() } label: {
                            Label("发送", systemImage: "arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!state.canAsk)
                        .accessibilityIdentifier("chatSend")
                    }
                }
            }
            .padding(12)
            .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(
                composerFocused ? AppPalette.accent.opacity(0.4) : AppPalette.line
            ))
        }
        .padding(.horizontal, 22).padding(.bottom, 18)
    }
}

struct UserQuestionView: View {
    let content: String

    var body: some View {
        HStack {
            Spacer(minLength: 32)
            VStack(alignment: .leading, spacing: 8) {
                Text("你").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(content).font(.body).lineSpacing(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: 610, alignment: .leading)
            .background(AppPalette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct ChatMessageView: View {
    @EnvironmentObject private var state: AppState
    let message: ChatMessage

    var body: some View {
        if message.role == "user" {
            UserQuestionView(content: message.content)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(AppPalette.accent)
                    Text("AskBase").font(.callout.weight(.semibold))
                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    CopyTextButton(text: message.content)
                }
                CitationText(content: message.content, sources: message.sources) { source in
                    state.sheet = .source(source)
                }
                if !message.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("检索依据 · \(message.sources.count)").font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 9)], alignment: .leading, spacing: 9) {
                            ForEach(Array(message.sources.enumerated()), id: \.offset) { index, source in
                                SourceCard(source: source, number: index + 1, compact: true) {
                                    state.sheet = .source(source)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

struct CitationText: View {
    let content: String
    let sources: [SearchResult]
    let open: (SearchResult) -> Void

    var body: some View {
        Text(attributedContent)
            .font(.body).lineSpacing(5).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(AppPalette.accent)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "askbase-source", let host = url.host,
                      let number = Int(host), number > 0, number <= sources.count else { return .discarded }
                open(sources[number - 1])
                return .handled
            })
    }

    private var attributedContent: AttributedString {
        var linked = content
        if let regex = try? NSRegularExpression(pattern: #"(?<!!)\[(\d+)\](?!\()"#) {
            for match in regex.matches(in: content, range: NSRange(content.startIndex..., in: content)).reversed() {
                guard let numberRange = Range(match.range(at: 1), in: content),
                      let number = Int(content[numberRange]), number > 0, number <= sources.count,
                      let range = Range(match.range, in: linked) else { continue }
                linked.replaceSubrange(range, with: "[\\[\(number)\\]](askbase-source://\(number))")
            }
        }
        var rendered = (try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(content)
        let otherLinks = rendered.runs.compactMap { run in
            run.link != nil && run.link?.scheme != "askbase-source" ? run.range : nil
        }
        for range in otherLinks { rendered[range].link = nil }
        return rendered
    }
}
