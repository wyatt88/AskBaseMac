import AppKit
import SwiftUI
import AskBaseCore

@main
struct AskBaseLocalApp: App {
    @NSApplicationDelegateAdaptor(AskBaseAppDelegate.self) private var appDelegate
    @StateObject private var state: AppState

    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let flags = arguments.indices.filter { arguments[$0] == "--library-path" }
        if flags.isEmpty {
            _state = StateObject(wrappedValue: AppState())
        } else if flags.count == 1, let index = flags.first, index + 1 < arguments.count,
                  (arguments[index + 1] as NSString).isAbsolutePath {
            #if DEBUG
            let manageModels = arguments.contains("--manage-models")
            #else
            let manageModels = false
            #endif
            _state = StateObject(wrappedValue: AppState(
                root: URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL,
                manageModels: manageModels
            ))
        } else {
            let state = AppState()
            state.preventStartup(message: "启动参数无效。请使用 --library-path <绝对路径> 指定独立资料库目录，每次只指定一次。为避免打开错误的资料库，本次未打开任何数据库。")
            _state = StateObject(wrappedValue: state)
        }
    }

    var body: some Scene {
        Window("AskBase Local", id: "main") {
            LifecycleRootView(appDelegate: appDelegate)
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 740)
                .tint(AppPalette.accent)
        }
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { AskBaseCommands(state: state) }
    }
}

private struct LifecycleRootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    let appDelegate: AskBaseAppDelegate

    var body: some View {
        RootView()
            .onAppear {
                appDelegate.state = state
                appDelegate.showMainWindow = { openWindow(id: "main") }
            }
            .task {
                appDelegate.state = state
                await state.start()
                #if DEBUG
                if !Task.isCancelled { await AppSmokeVerifier.runIfRequested(state: state) }
                #endif
            }
    }
}

@MainActor
final class AskBaseAppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    var showMainWindow: (() -> Void)?
    private var awaitingTermination = false
    private var cleanupCompleted = false
    private var quitTask: Task<Void, Never>?
    private var quitPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !awaitingTermination
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if cleanupCompleted { return .terminateNow }
        guard let state else { return .terminateNow }
        guard !awaitingTermination else { return .terminateCancel }
        awaitingTermination = true
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 210),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "正在退出 AskBase Local"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: QuitProgressView(state: state) { [weak self] in
            self?.quitTask?.cancel()
        })
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        quitPanel = panel
        quitTask = Task {
            let saved = await state.prepareToQuit()
            if !saved, let failure = state.quitFailure {
                if state.hasUnsavedNotes {
                    state.section = .notes
                    state.selectedNoteID = state.noteDrafts.keys.first
                }
                let alert = NSAlert()
                alert.messageText = "退出尚未完成"
                alert.informativeText = failure
                alert.alertStyle = .warning
                alert.addButton(withTitle: "返回应用")
                await alert.beginSheetModal(for: panel)
            }
            if !saved { showMainWindow?() }
            // Keep the in-progress guard set while closing the progress panel;
            // closing the last window must not start a second cleanup task.
            panel.orderOut(nil)
            panel.close()
            quitPanel = nil
            quitTask = nil
            awaitingTermination = false
            if saved {
                cleanupCompleted = true
                sender.terminate(nil)
            }
        }
        // Keep AppKit's ordinary event loop running while Swift tasks cancel,
        // save notes and receive pipe events. terminateLater enters a nested
        // termination loop that can prevent these main-actor tasks from running.
        // Re-enter termination only once cleanup has completed successfully.
        return .terminateCancel
    }
}

private struct QuitProgressView: View {
    @ObservedObject var state: AppState
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(state.quitProgress.isEmpty ? "正在准备退出…" : state.quitProgress)
                    .font(.headline)
            }
            Text(state.modelRuntime.ownershipSummary)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消退出", action: cancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 210)
    }
}

struct AskBaseCommands: Commands {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("显示 AskBase Local") { openWindow(id: "main") }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("新建知识库…") { state.sheet = .knowledgeBase(nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!state.hasStarted || state.isPreparingToQuit)
            Button("导入资料…") { state.chooseImport() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!state.canImport)
            Button("新建笔记") { state.createNote() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(state.selectedKnowledgeBaseID == nil || state.isCreatingNote || state.isPreparingToQuit)
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                openWindow(id: "main")
                state.section = .settings
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存笔记") {
                if let id = state.selectedNoteID { state.saveNoteNow(id) }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(state.section != .notes || state.selectedNoteID == nil)
            Button("导出为 Markdown…") {
                if state.section == .notes, let id = state.selectedNoteID, let note = state.note(for: id) {
                    state.exportNote(note)
                } else if state.section == .chat {
                    state.exportConversation()
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled((state.section != .notes || state.selectedNoteID == nil)
                      && (state.section != .chat || state.messages.isEmpty))
        }
        CommandMenu("前往") {
            Button("资料库") { state.section = .library }.keyboardShortcut("1", modifiers: .command)
            Button("语义搜索") { state.section = .search }.keyboardShortcut("2", modifiers: .command)
            Button("知识问答") { state.section = .chat }.keyboardShortcut("3", modifiers: .command)
            Button("笔记") { state.section = .notes }.keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("刷新资料库") { Task { await state.refresh() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!state.hasStarted)
        }
    }
}
