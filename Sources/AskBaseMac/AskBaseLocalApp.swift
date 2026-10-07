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
            _state = StateObject(wrappedValue: AppState(
                root: URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
            ))
        } else {
            let state = AppState()
            state.preventStartup(message: "启动参数无效。请使用 --library-path <绝对路径> 指定独立资料库目录，每次只指定一次。为避免打开错误的资料库，本次未打开任何数据库。")
            _state = StateObject(wrappedValue: state)
        }
    }

    var body: some Scene {
        Window("AskBase Local", id: "main") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 740)
                .tint(AppPalette.accent)
                .task {
                    appDelegate.state = state
                    await state.start()
                    #if DEBUG
                    await AppSmokeVerifier.runIfRequested(state: state)
                    #endif
                }
        }
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { AskBaseCommands(state: state) }
    }
}

@MainActor
final class AskBaseAppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    private var awaitingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        guard !awaitingTermination else { return .terminateLater }
        awaitingTermination = true
        Task {
            let saved = await state.prepareToQuit()
            if !saved {
                state.section = .notes
                state.selectedNoteID = state.noteDrafts.keys.first
                let alert = NSAlert()
                alert.messageText = "有笔记尚未保存"
                alert.informativeText = "修改仍保留在编辑器中。请处理保存错误后再退出，以免丢失内容。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "返回编辑")
                alert.runModal()
            }
            awaitingTermination = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
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
                .disabled(!state.hasStarted)
            Button("导入资料…") { state.chooseImport() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!state.canImport)
            Button("新建笔记") { state.createNote() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(state.selectedKnowledgeBaseID == nil || state.isCreatingNote)
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
