import SwiftUI
import AskBaseCore

struct KnowledgeBaseEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let existing: KnowledgeBase?
    @State private var name: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(existing: KnowledgeBase?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(existing == nil ? "新建知识库" : "重命名知识库", systemImage: "folder")
                .font(.title2.weight(.semibold))
            Text(existing == nil ? "按主题或项目整理资料，对话和笔记也会保存在这个知识库中。" : "名称会显示在侧栏，不影响已导入的资料。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                Text("名称").font(.callout.weight(.medium))
                TextField("知识库名称", text: $name).textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { save() }
                    .accessibilityIdentifier("knowledgeBaseName")
                Text("\(name.count) / 128").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let error { ErrorPanel(title: "无法保存", message: error) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(existing == nil ? "创建" : "保存") { save() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 128)
            }
        }
        .padding(28).frame(width: 440)
        .background(AppPalette.canvas)
        .interactiveDismissDisabled(saving)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard !saving, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 128 else { return }
        saving = true
        error = nil
        Task {
            do {
                try await state.saveKnowledgeBase(name: name, existing: existing)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}

struct IssueSheet: View {
    @Environment(\.dismiss) private var dismiss
    let issue: AppIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(issue.title, systemImage: "exclamationmark.circle")
                .font(.title2.weight(.semibold))
            ScrollView {
                Text(issue.message).font(.body).lineSpacing(4).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                CopyTextButton(text: issue.message)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(26).frame(width: 620, height: 440)
        .background(AppPalette.canvas)
    }
}

struct ImportStatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            if let activity = state.reindexActivity {
                ProgressView(value: Double(activity.processed), total: Double(activity.total))
                    .progressViewStyle(.circular).controlSize(.small).frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.isCancellingReindex ? "正在停止索引重建…" : "正在重建「\(activity.currentTitle)」")
                        .font(.callout.weight(.medium)).lineLimit(1).help(activity.currentTitle)
                    Text("已处理 \(activity.processed) / \(activity.total) 份 · \(activity.succeeded) 份成功 · \(activity.failures.count) 份需处理")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ElapsedLabel(startedAt: activity.startedAt)
                Button("停止") { state.cancelReindex() }
                    .controlSize(.small).disabled(state.isCancellingReindex)
            } else if let activity = state.importActivity {
                ProgressView().controlSize(.small).frame(width: 19)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.isCancellingImport ? "正在停止导入…" : "正在导入到「\(activity.knowledgeBaseName)」")
                        .font(.callout.weight(.medium))
                    Text(progressText(activity)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                ElapsedLabel(startedAt: activity.startedAt)
                Button("停止") { state.cancelImport() }
                    .controlSize(.small).disabled(state.isCancellingImport)
            } else if state.isReadingDrop {
                ProgressView().controlSize(.small)
                Text("正在读取拖入的文件地址…").font(.callout)
                Spacer()
            } else if let outcome = state.importOutcome {
                Image(systemName: outcome.error != nil || !outcome.report.failures.isEmpty
                      ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(outcome.error != nil || !outcome.report.failures.isEmpty
                                     ? Color.orange : AppPalette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(outcome.title).font(.callout.weight(.medium))
                    Text(outcome.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("查看详情") { state.sheet = .importReport }.controlSize(.small)
                Button { state.dismissImportOutcome() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("收起导入结果")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 11)
        .background(AppPalette.surface)
    }

    private func progressText(_ activity: ImportActivity) -> String {
        let documents = state.importedDocumentsInProgress
        let ready = documents.filter { $0.status == .ready }.count
        let failed = documents.filter { $0.status == .failed }.count
        let indexing = documents.first { $0.status == .indexing }
        if let indexing {
            return "已索引 \(ready) 份 · 正在处理 \(indexing.fileName)" + (failed > 0 ? " · \(failed) 份需处理" : "")
        }
        if !documents.isEmpty { return "已索引 \(ready) 份 · \(failed) 份需处理 · 正在继续" }
        return "\(activity.selectedCount) 个所选项目 · 正在检查连接与读取文件"
    }
}

struct ImportReportSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let outcome = state.importOutcome {
                VStack(alignment: .leading, spacing: 6) {
                    Text(outcome.title).font(.title2.weight(.semibold))
                    Text("「\(outcome.knowledgeBaseName)」 · \(outcome.summary)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let error = outcome.error {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        reportSection("需处理", symbol: "exclamationmark.circle", color: .orange,
                                      items: outcome.report.failures)
                        reportSection("已跳过", symbol: "arrow.turn.down.right", color: .secondary,
                                      items: outcome.report.skipped)
                        reportSection("已索引", symbol: "checkmark.circle", color: AppPalette.accent,
                                      items: outcome.report.imported.map(\.fileName))
                        if outcome.report.imported.isEmpty && outcome.report.failures.isEmpty
                            && outcome.report.skipped.isEmpty {
                            Text("本次没有写入新的资料。").foregroundStyle(.secondary)
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    CopyTextButton(text: outcome.plainText)
                    Spacer()
                    if !outcome.report.failures.isEmpty {
                        Button("前往资料库") {
                            state.section = .library
                            dismiss()
                        }
                    }
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text("没有待查看的导入结果。")
                Button("关闭") { dismiss() }
            }
        }
        .padding(26).frame(width: 690, height: 540)
        .background(AppPalette.canvas)
    }

    @ViewBuilder private func reportSection(_ title: String, symbol: String, color: Color,
                                           items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("\(title) · \(items.count)", systemImage: symbol)
                    .font(.headline).foregroundStyle(color)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item).font(.body).lineSpacing(3).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
            }
        }
    }
}
