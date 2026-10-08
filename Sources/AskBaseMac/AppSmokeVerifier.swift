#if DEBUG
import AppKit
import Darwin
import Foundation
import AskBaseCore

/// Explicit debug-only window verification. Never runs in release distributions,
/// never reads another application's windows, and refuses the normal user library.
@MainActor
enum AppSmokeVerifier {
    private static var started = false

    static func runIfRequested(state: AppState) async {
        let args = CommandLine.arguments
        guard !started, let index = args.firstIndex(of: "--ui-smoke-output"), index + 1 < args.count else { return }
        started = true
        let output = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        var checks: [String: Bool] = [:]
        var succeeded = false
        do {
            guard let root = state.rootURL, root.lastPathComponent == "ui-smoke-library",
                  root.deletingLastPathComponent().lastPathComponent.hasPrefix("AskBase-UIVerify-"),
                  state.snapshot.documents.isEmpty, state.snapshot.notes.isEmpty,
                  state.snapshot.conversations.isEmpty else {
                throw AskBaseError.invalidInput("UI smoke requires a fresh explicitly selected AskBase-UIVerify-*/ui-smoke-library.")
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            checks["startup_ready"] = state.hasStarted && state.startupError == nil
            checks["embedding_connected"] = state.modelStatus?.embeddingAvailable == true
            checks["local_answer_model_selected"] = !state.settings.chatModel.isEmpty
            NSApp.windows.first(where: { $0.isVisible && $0.title == "AskBase Local" })?
                .setContentSize(NSSize(width: 1240, height: 820))
            try await settle()
            try capture("01-empty", to: output)
            try await Task.sleep(for: .seconds(2))
            try capture("01-empty-settled", to: output)
            checks["empty_workspace_fits_window"] = true
            if args.contains("--ui-empty-only") {
                await finishVerification(state: state, succeeded: true)
            }
            guard let examples = Bundle.main.resourceURL?.appendingPathComponent("Examples"),
                  let base = state.selectedKnowledgeBase else { throw AskBaseError.storage("Bundled examples unavailable.") }
            state.importDocuments([examples], into: base)
            try await wait(until: { state.importActivity == nil }, timeout: 120)
            checks["native_import_handler_indexed_examples"] = state.readyDocumentCount == 2
            checks["import_has_no_failures"] = state.importOutcome?.report.failures.isEmpty == true
            state.dismissImportOutcome()
            state.notice = nil
            state.selectedDocumentID = state.documents.first(where: { $0.title.contains("北辰") })?.id
            try await settle()
            try capture("02-library", to: output)
            if let id = state.selectedDocumentID {
                checks["detail_loaded_chunks"] = !(try await state.chunks(for: id)).isEmpty
            }
            state.section = .search
            state.searchQuery = "北辰计划的审核截止日是哪天，由谁负责？"
            state.runSearch()
            try await wait(until: { !state.isSearching }, timeout: 120)
            checks["native_search_has_relevant_first_source"] = state.searchResults.first?.title.contains("北辰") == true
            checks["search_no_error"] = state.searchError == nil
            try await settle()
            try capture("03-search", to: output)
            if let source = state.searchResults.first {
                state.sheet = .source(source)
                try await settle()
                try capture("04-source", to: output, sheet: true)
                checks["source_sheet_presented"] = NSApp.windows.contains { $0.attachedSheet != nil }
                state.sheet = nil
                try await settle()
            }
            state.section = .chat
            state.chatDraft = "北辰计划的审核截止日是哪天，由谁负责？"
            state.ask()
            try await wait(until: { !state.isAnswering }, timeout: 300)
            checks["native_chat_no_error"] = state.chatError == nil
            checks["native_chat_saved_two_messages"] = state.messages.count == 2
            let answer = state.messages.last
            checks["native_chat_answer_matches_fixture"] = answer?.content.contains("18") == true
                && answer?.content.contains("林舟") == true
            checks["native_chat_has_sources"] = !(answer?.sources.isEmpty ?? true)
            try await settle()
            try capture("05-chat", to: output)
            state.section = .notes
            state.createNote()
            try await wait(until: { !state.isCreatingNote }, timeout: 10)
            if let id = state.selectedNoteID {
                state.editNote(id: id, title: "我的阅读笔记", body: """
                今天整理了北辰计划的两条关键信息：

                • 文档审核截止日：10 月 18 日
                • 负责人：林舟

                提醒：这是虚构的验收资料，正式使用时应打开引用核对原文。
                """)
                checks["native_note_flushed"] = await state.flushNotes()
                checks["native_note_saved"] = state.note(for: id)?.body.contains("虚构") == true
            }
            try await settle()
            try capture("06-notes", to: output)
            state.section = .settings
            try await settle()
            try capture("07-settings", to: output)
            NSApp.appearance = NSAppearance(named: .aqua)
            state.section = .library
            try await settle()
            try capture("08-library-light", to: output)
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "AskBase Local" }) {
                window.setContentSize(NSSize(width: 1100, height: 740))
                try await settle()
                try capture("09-library-minimum", to: output)
                checks["minimum_workspace_fits_window"] = true
            }
            let report: [String: Any] = [
                "checks": checks, "passed": checks.values.filter { $0 }.count, "total": checks.count,
                "answer": answer?.content ?? "", "model": state.settings.chatModel,
                "capture_method": "AppKit cacheDisplay of the actual app-owned window; debug build",
                "input_method": "native AppState action handlers; not external mouse/keyboard automation",
                "library_isolation": "fresh synthetic library explicitly selected at launch",
                "shutdown_method": "explicit debug-only note flush and process exit; normal application quit not evaluated",
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("ui-verification.json"))
            succeeded = checks.values.allSatisfy { $0 }
        } catch {
            let report: [String: Any] = ["checks": checks, "error": error.localizedDescription]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try? data.write(to: output.appendingPathComponent("ui-verification.json"))
            }
        }
        await finishVerification(state: state, succeeded: succeeded)
    }

    private static func finishVerification(state: AppState, succeeded: Bool) async -> Never {
        // A command-line verification run must finish even when AppKit's
        // deferred termination loop cannot service the delegate's async task.
        // This path is excluded from release builds and still flushes notes.
        let saved = await state.prepareToQuit()
        Darwin.exit(succeeded && saved ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func wait(until condition: () -> Bool, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw AskBaseError.invalidInput("UI verification timed out.") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func settle() async throws { try await Task.sleep(for: .milliseconds(650)) }

    private static func capture(_ name: String, to output: URL, sheet: Bool = false) throws {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "AskBase Local" }),
              let view = (sheet ? window.attachedSheet : window)?.contentView else {
            throw AskBaseError.storage("Expected application window is not visible.")
        }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func firstSplitView(_ item: NSView) -> NSSplitView? {
            if let split = item as? NSSplitView { return split }
            for child in item.subviews {
                if let split = firstSplitView(child) { return split }
            }
            return nil
        }
        if let split = firstSplitView(view) {
            let actual = split.convert(split.bounds, to: view)
            guard view.bounds.insetBy(dx: -1, dy: -1).contains(actual) else {
                throw AskBaseError.storage("Workspace extends outside the window: \(NSStringFromRect(actual)).")
            }
        }
        func describe(_ item: NSView, depth: Int = 0) -> [String] {
            guard depth <= 5 else { return [] }
            return ["\(String(repeating: " ", count: depth))\(type(of: item)) frame=\(NSStringFromRect(item.frame)) bounds=\(NSStringFromRect(item.bounds))"]
                + item.subviews.flatMap { describe($0, depth: depth + 1) }
        }
        let geometry: [String: String] = [
            "windowFrame": NSStringFromRect(window.frame),
            "contentBounds": NSStringFromRect(view.bounds),
            "contentFrame": NSStringFromRect(view.frame),
            "layoutRect": NSStringFromRect(window.contentLayoutRect),
            "viewTree": describe(view).joined(separator: "\n"),
        ]
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name + "-geometry.json"))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw AskBaseError.storage("Unable to allocate window snapshot.")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AskBaseError.storage("Unable to encode window snapshot.")
        }
        try png.write(to: output.appendingPathComponent(name + ".png"))
    }
}
#endif
