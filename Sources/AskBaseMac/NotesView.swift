import SwiftUI
import AskBaseCore

struct NotesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "笔记", subtitle: "记录自己的理解 · 保存在「\(state.selectedKnowledgeBase?.name ?? "")」") {
                if let id = state.selectedNoteID, let note = state.note(for: id) {
                    Button { state.exportNote(note) } label: {
                        Label("导出笔记", systemImage: "square.and.arrow.up")
                    }
                }
                Button { state.createNote() } label: { Label("新建笔记", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isCreatingNote)
            }
            Divider()
            if state.notes.isEmpty {
                EmptyState(symbol: "square.and.pencil", title: "留下自己的思考",
                           detail: "在这里整理阅读收获、保存观点或起草文字。笔记自动保存到本机，也可以导出为 Markdown。") {
                    Button("新建笔记") { state.createNote() }
                        .buttonStyle(.borderedProminent).disabled(state.isCreatingNote)
                }
            } else {
                HSplitView {
                    List(selection: $state.selectedNoteID) {
                        ForEach(state.notes) { saved in
                            let note = state.note(for: saved.id) ?? saved
                            VStack(alignment: .leading, spacing: 9) {
                                Text(note.title.isEmpty ? "未命名笔记" : note.title)
                                    .font(.callout.weight(.semibold)).lineLimit(2)
                                Text(note.body.isEmpty ? "空白笔记" : note.body)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(note.updatedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .tag(note.id)
                            .contextMenu {
                                Button("导出为 Markdown…") { state.exportNote(note) }
                                Button("删除笔记…", role: .destructive) { state.requestDelete(note) }
                                    .disabled(state.isDeleting)
                            }
                        }
                    }
                    .listStyle(.inset).scrollContentBackground(.hidden)
                    .frame(minWidth: 190, idealWidth: 235, maxWidth: 300)
                    Group {
                        if let id = state.selectedNoteID, let note = state.note(for: id) {
                            NoteEditor(note: note)
                        } else {
                            EmptyState(symbol: "note.text", title: "选择一篇笔记",
                                       detail: "选中左侧笔记开始编辑，或新建一篇。") { EmptyView() }
                        }
                    }
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppPalette.surface)
                }
            }
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: state.notes.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        if state.selectedNoteID == nil { state.selectedNoteID = state.notes.first?.id }
    }
}

struct NoteEditor: View {
    @EnvironmentObject private var state: AppState
    let note: LibraryNote
    @FocusState private var bodyFocused: Bool

    private var saveState: NoteSaveState { state.noteSaveStates[note.id] ?? .saved }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            TextField("笔记标题", text: Binding(
                get: { state.note(for: note.id)?.title ?? "" },
                set: { state.editNote(id: note.id, title: $0) }
            ))
            .font(.system(size: 23, weight: .semibold)).textFieldStyle(.plain)
            .onSubmit { state.saveNoteNow(note.id); bodyFocused = true }
            .accessibilityLabel("笔记标题")
            HStack {
                Text("Markdown / 纯文本").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) { state.requestDelete(note) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).help("删除这篇笔记…").disabled(state.isDeleting)
            }
            Divider()
            ZStack(alignment: .topLeading) {
                if note.body.isEmpty {
                    Text("从这里开始记录…").foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
                }
                TextEditor(text: Binding(
                    get: { state.note(for: note.id)?.body ?? "" },
                    set: { state.editNote(id: note.id, body: $0) }
                ))
                .font(.system(size: 14)).lineSpacing(6).scrollContentBackground(.hidden)
                .focused($bodyFocused)
                .accessibilityLabel("笔记正文")
                .accessibilityIdentifier("noteBody")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if case .failed(let message) = saveState {
                ErrorPanel(title: "笔记未保存", message: message, actionTitle: "重试保存") {
                    state.saveNoteNow(note.id)
                }
            }
            Divider()
            HStack(spacing: 7) {
                if saveState == .saving {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: saveState == .saved ? "checkmark" : "circle.fill")
                        .font(.system(size: saveState == .saved ? 10 : 5))
                        .foregroundStyle(saveState == .saved ? AppPalette.accent : Color.orange)
                }
                Text(saveState.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(note.body.count) 字").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                Button("保存") { state.saveNoteNow(note.id) }
                    .controlSize(.small).disabled(state.noteDrafts[note.id] == nil || saveState == .saving)
            }
            Text("笔记不会自动加入检索索引。").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(26)
    }
}
