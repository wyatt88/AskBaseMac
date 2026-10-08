import AppKit
import SwiftUI
import AskBaseCore

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var draft = AppSettings()
    @State private var saving = false
    @State private var error: String?
    @State private var savedNotice: String?

    private var endpointsMatch: Bool {
        draft.embeddingBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) == state.settings.embeddingBaseURL
            && draft.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) == state.settings.ollamaBaseURL
    }
    private var isBusy: Bool { saving || state.isSavingSettings || state.isCheckingConnections }
    private var selectableModels: [String] { endpointsMatch ? state.availableChatModels : [] }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置", subtitle: "连接本机模型，管理检索与回答") {
                if draft != state.settings {
                    Button("保存") { save(test: false) }
                        .disabled(isBusy || state.settingsAreLocked)
                }
                Button { save(test: true) } label: {
                    HStack(spacing: 7) {
                        if isBusy { ProgressView().controlSize(.mini) }
                        Text(isBusy ? "正在检测…" : "保存并测试连接")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || state.settingsAreLocked)
                .accessibilityIdentifier("testModelConnections")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if state.settingsAreLocked {
                        Label("任务正在使用模型，完成或停止后可修改设置。", systemImage: "clock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error { ErrorPanel(title: "设置未能保存", message: error) }
                    if let error = state.modelSelectionError {
                        ErrorPanel(title: "回答模型尚未配置", message: error)
                    }
                    if let savedNotice {
                        Label(savedNotice, systemImage: "checkmark.circle")
                            .font(.callout).foregroundStyle(AppPalette.accent)
                    }
                    embeddingSettings
                    chatSettings
                    retrievalSettings
                    storageSettings
                    if let checked = state.connectionCheckedAt, endpointsMatch {
                        Text("最近检测：\(checked.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(28)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { draft = state.settings }
        .onChange(of: state.settings) { old, new in
            if draft == old || saving { draft = new }
        }
    }

    private var embeddingSettings: some View {
        settingsGroup("语义检索", symbol: "magnifyingglass") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("EmbeddingGemma 2").font(.body.weight(.medium))
                    Spacer()
                    connectionBadge(available: state.modelStatus?.embeddingAvailable)
                }
                endpointField("服务地址", text: $draft.embeddingBaseURL)
                Text("为文本、图片、音频和视频生成检索向量；可用模态以当前服务实际报告为准。默认本机端口为 8871。")
                    .font(.callout).foregroundStyle(.secondary)
                if endpointsMatch, let status = state.modelStatus {
                    connectionDetail(status.embeddingDetail, available: status.embeddingAvailable)
                    EmbeddingCapabilityNote(capabilities: state.embeddingCapabilities)
                } else {
                    Text(endpointsMatch ? "模型能力尚未检测，尚不能确认图片、音频和视频是否可用。"
                         : "地址已更改，保存并测试后更新连接状态与媒体能力。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("媒体导入和文件查询会处理全部片段；不设文件大小、数量或总时长配额。格式、编码或模型能力不支持时，会说明具体原因。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("图片和视频可能包含本机 OCR 文字。本应用不录音，也不提供语音转写；纯媒体语义索引请到搜索中查看或播放核对。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chatSettings: some View {
        settingsGroup("知识问答", symbol: "bubble.left.and.bubble.right") {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("Ollama").font(.body.weight(.medium))
                    Spacer()
                    connectionBadge(available: state.modelStatus?.chatAvailable)
                }
                endpointField("服务地址", text: $draft.ollamaBaseURL)
                if endpointsMatch, let status = state.modelStatus {
                    connectionDetail(status.chatDetail, available: status.chatAvailable)
                }
                Divider()
                HStack(alignment: .center, spacing: 18) {
                    Text("回答模型").frame(width: 75, alignment: .leading)
                    Picker("回答模型", selection: $draft.chatModel) {
                        Text("尚未选择").tag("")
                        if !draft.chatModel.isEmpty, !selectableModels.contains(draft.chatModel) {
                            Text("\(draft.chatModel)（未验证）").tag(draft.chatModel)
                        }
                        ForEach(selectableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                    .disabled(selectableModels.isEmpty || isBusy || state.settingsAreLocked)
                    .accessibilityIdentifier("chatModelPicker")
                }
                if let selection = state.modelSelectionNotice, endpointsMatch {
                    Label(selection, systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(AppPalette.accent)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if selectableModels.isEmpty {
                    Text("测试连接后，这里会显示 Ollama 实际返回的模型。若仅有一个模型且尚未选择，会自动保存并用于问答。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !draft.chatModel.isEmpty, !selectableModels.contains(draft.chatModel) {
                    Text("已保存的模型不在当前服务返回的列表中，请重新选择。")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Text("模型基于真实文字或 OCR 在本机生成回答；没有文字的媒体请到搜索中查看或播放。首次加载较大模型可能需要等待。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var retrievalSettings: some View {
        settingsGroup("检索偏好", symbol: "line.3.horizontal.decrease.circle") {
            VStack(alignment: .leading, spacing: 14) {
                Stepper(value: $draft.topK, in: 1...12) {
                    HStack {
                        Text("每次检索的片段数")
                        Spacer()
                        Text("\(draft.topK)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }.disabled(isBusy || state.settingsAreLocked)
                Text("搜索和问答共用此设置。修改嵌入模型或编码版本后，需要到资料库重新索引。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var storageSettings: some View {
        settingsGroup("本地存储", symbol: "internaldrive") {
            VStack(alignment: .leading, spacing: 13) {
                Text("资料副本、索引、对话与笔记保存在这台 Mac 上。只有你选择的文件或文件夹会被导入。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let root = state.rootURL {
                    Text(root.path).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([root])
                    }.controlSize(.small)
                }
                Text("模型接口仅接受 localhost、127.0.0.1 或 ::1。")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func endpointField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 18) {
            Text(label).frame(width: 75, alignment: .leading)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(isBusy || state.settingsAreLocked)
        }
    }

    private func connectionBadge(available: Bool?) -> some View {
        StatusPill(
            label: state.isCheckingConnections ? "检测中"
                : !endpointsMatch ? "待检测"
                : available == true ? "已连接" : available == false ? "未就绪" : "未检测",
            color: endpointsMatch && available == true ? AppPalette.accent : .secondary
        )
    }

    @ViewBuilder private func connectionDetail(_ message: String, available: Bool) -> some View {
        if available {
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ErrorPanel(title: "服务尚未就绪", message: message)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, symbol: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            content().frame(maxWidth: .infinity, alignment: .leading).padding(15)
        } label: {
            Label(title, systemImage: symbol).font(.headline).padding(.bottom, 5)
        }
    }

    private func save(test: Bool) {
        guard !isBusy else { return }
        saving = true
        error = nil
        savedNotice = nil
        Task {
            defer { saving = false }
            do {
                try await state.applySettings(draft, testConnections: test)
                draft = state.settings
                savedNotice = test ? "设置已保存，连接检测已完成。" : "设置已保存。"
            } catch { self.error = error.localizedDescription }
        }
    }
}
