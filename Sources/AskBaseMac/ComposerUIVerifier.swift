#if DEBUG
import AppKit
import Foundation

/// Native checks on the composer already mounted by ChatView.
/// AppSmokeVerifier must select .chat in its fresh, isolated library before calling.
/// No AppState actions, model requests, general-pasteboard writes, or helper editor.
@MainActor
enum ComposerUIVerifier {
    static func run(in window: NSWindow) async throws -> [String: Bool] {
        try requireIsolatedLaunch()
        let editor = try await mountedComposer(in: window)
        guard !editor.hasMarkedText(), let scroll = editor.enclosingScrollView,
              scroll.documentView === editor, editor.isEditable, editor.isSelectable,
              let storage = editor.textStorage else {
            throw VerificationError("Composer must be editable, attached to its scroll view, and have no existing IME composition.")
        }

        let snapshot = Snapshot(editor: editor, scroll: scroll, window: window, storage: storage)
        let probe = ProbeDelegate()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var checks: [String: Bool] = [:]

        // There are deliberately NO suspension points while the view is modified:
        // a SwiftUI update must not replace the submit spy or the isolated delegate.
        // Suppressing the real delegate also leaves the AppState draft untouched.
        try withRestoredState(editor: editor, scroll: scroll, window: window, snapshot: snapshot, probe: probe) {
            var submissions: [String] = []
            var focusChanges: [Bool] = []
            editor.onSubmit = { submissions.append(editor.string) }
            editor.onFocusChange = { focusChanges.append($0) }
            checks["mounted_in_requested_window"] = editor.window === window && window.isVisible
            checks["submit_callback_was_connected"] = snapshot.onSubmit != nil
            checks["focus_callback_was_connected"] = snapshot.onFocusChange != nil
            checks["native_undo_manager_isolated"] = editor.undoManager === probe.isolatedUndo
            guard checks["native_undo_manager_isolated"] == true else {
                throw VerificationError("NSTextView did not accept the isolated undo manager; no input was injected.")
            }

            let resigned = window.makeFirstResponder(nil)
            let acquired = window.makeFirstResponder(editor)
            checks["focus_acquired"] = resigned && acquired && window.firstResponder === editor
                && focusChanges.last == true
            guard window.firstResponder === editor else {
                throw VerificationError("Mounted composer could not become first responder.")
            }

            @MainActor func reset(_ text: String, selection: NSRange? = nil, canSubmit: Bool = true) {
                editor.unmarkText()
                editor.breakUndoCoalescing()
                probe.isolatedUndo.removeAllActions()
                // removeAllActions also reenables registration on NSUndoManager.
                if probe.isolatedUndo.isUndoRegistrationEnabled { probe.isolatedUndo.disableUndoRegistration() }
                editor.string = text
                editor.typingAttributes = snapshot.typingAttributes
                editor.setSelectedRange(selection ?? NSRange(location: (text as NSString).length, length: 0))
                editor.canSubmit = canSubmit
                submissions.removeAll()
                probe.changeCount = 0
                layout(editor, in: window)
            }
            @MainActor func key(_ flags: NSEvent.ModifierFlags = [], code: UInt16 = 36,
                     characters: String = "\r", repeatKey: Bool = false) throws {
                let event = try keyEvent(in: window, flags: flags, code: code,
                                         characters: characters, repeatKey: repeatKey)
                editor.keyDown(with: event)
            }

            reset("")
            editor.placeholder = "原生输入框验证占位符"
            checks["placeholder_not_in_text_storage"] = editor.string.isEmpty
                && editor.attributedString().length == 0 && editor.selectedRange() == NSRange(location: 0, length: 0)
            inspectLowerWritingArea(editor: editor, scroll: scroll, window: window,
                                    prefix: "empty", checks: &checks)
            let emptyCaret = caretRect(editor, in: window)
            try key(code: 7, characters: "x")
            layout(editor, in: window)
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            let firstCharacterCaret = caretRect(editor, in: window)
            checks["native_character_input"] = editor.string == "x" && submissions.isEmpty && probe.changeCount > 0
            checks["empty_and_typed_caret_share_origin"] = emptyCaret.height > 0 && firstCharacterCaret.height > 0
                && abs(emptyCaret.minX - firstCharacterCaret.minX) <= 1
                && abs(emptyCaret.minY - firstCharacterCaret.minY) <= 1
            if let container = editor.textContainer {
                checks["caret_uses_text_container_inset"] =
                    abs(firstCharacterCaret.minX - editor.textContainerOrigin.x - container.lineFragmentPadding) <= 1
            } else {
                checks["caret_uses_text_container_inset"] = false
            }
            reset("短行")
            inspectLowerWritingArea(editor: editor, scroll: scroll, window: window,
                                    prefix: "single_line", checks: &checks)

            let question = "原生测试问题 😀"
            reset(question)
            let returnSelection = editor.selectedRange()
            try key()
            checks["return_submits_once"] = submissions == [question]
            checks["return_preserves_text_and_selection"] = editor.string == question
                && editor.selectedRange() == returnSelection
            checks["return_keeps_focus"] = window.firstResponder === editor

            reset(question)
            try key(.command)
            checks["command_return_submits_once"] = submissions == [question] && editor.string == question

            reset(question)
            try key(code: 76, characters: "\u{3}")
            checks["keypad_enter_submits_once"] = submissions == [question] && editor.string == question

            reset(question)
            try key(repeatKey: true)
            checks["held_return_does_not_resubmit"] = submissions.isEmpty && editor.string == question

            for (name, flags) in [("return", NSEvent.ModifierFlags()), ("command_return", .command)] {
                reset(question, canSubmit: false)
                let before = editor.selectedRange()
                try key(flags)
                checks["disabled_" + name + "_does_not_submit"] = submissions.isEmpty
                    && editor.string == question && editor.selectedRange() == before
            }
            reset("", canSubmit: false)
            try key()
            checks["empty_disabled_return_does_not_insert_newline"] = submissions.isEmpty && editor.string.isEmpty

            for (name, flags) in [("shift_return", NSEvent.ModifierFlags.shift), ("option_return", .option)] {
                reset("前后", selection: NSRange(location: 1, length: 0))
                try key(flags)
                checks[name + "_inserts_newline_at_cursor"] = editor.string == "前\n后"
                    && editor.selectedRange() == NSRange(location: 2, length: 0) && submissions.isEmpty
            }
            reset("前后", selection: NSRange(location: 1, length: 0), canSubmit: false)
            try key(.shift)
            checks["disabled_submission_still_allows_editing"] = editor.string == "前\n后" && submissions.isEmpty

            // A marked range exercises NSTextInputClient state, not a real input
            // method's candidate UI. Do not label this an end-to-end Chinese IME test.
            for (name, flags) in [("return", NSEvent.ModifierFlags()), ("command_return", .command)] {
                reset("前后", selection: NSRange(location: 1, length: 0))
                editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                let marked = editor.hasMarkedText() && editor.markedRange() == NSRange(location: 1, length: 2)
                checks["ime_" + name + "_marked_text_established"] = marked
                try key(flags)
                checks["ime_" + name + "_does_not_submit"] = marked && submissions.isEmpty
                checks["ime_" + name + "_preserves_surrounding_text"] =
                    editor.string.hasPrefix("前") && editor.string.hasSuffix("后")
                editor.unmarkText()
            }
            reset("")
            editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.insertText("已确认", replacementRange: editor.markedRange())
            let committed = !editor.hasMarkedText() && editor.string == "已确认"
            try key()
            checks["return_after_explicit_ime_commit_submits_once"] = committed && submissions == ["已确认"]

            // AppKit's paste ingestion API with a private pasteboard: the user's
            // clipboard (including lazy/promised types) is never overwritten.
            let pasted = "第一行\n第二行 😀\n第三行"
            pasteboard.setString(pasted, forType: .string)
            reset("前旧内容后", selection: NSRange(location: 1, length: 3))
            let read = editor.readSelection(from: pasteboard, type: .string)
            checks["multiline_paste_replaces_selection"] = read && editor.string == "前" + pasted + "后"
                && submissions.isEmpty && !editor.hasMarkedText()
            checks["multiline_paste_places_caret_after_utf16_text"] =
                editor.selectedRange() == NSRange(location: 1 + (pasted as NSString).length, length: 0)

            reset("A😀中文Z", selection: NSRange(location: 1, length: ("😀中文" as NSString).length))
            try key(code: 7, characters: "x")
            checks["typing_replaces_unicode_selection"] = editor.string == "AxZ"
                && editor.selectedRange() == NSRange(location: 2, length: 0) && submissions.isEmpty
            try key(code: 123, characters: "\u{F702}")
            checks["left_arrow_moves_cursor"] = editor.selectedRange() == NSRange(location: 1, length: 0)
            try key(.shift, code: 124, characters: "\u{F703}")
            checks["shift_right_extends_selection"] = editor.selectedRange() == NSRange(location: 1, length: 1)

            reset("前旧内容后", selection: NSRange(location: 1, length: 3))
            verifyUndo(editor: editor, undo: probe.isolatedUndo, checks: &checks) {
                _ = editor.readSelection(from: pasteboard, type: .string)
            }
            checks["undo_redo_never_submits"] = submissions.isEmpty

            let longText = (1...80).map { "第 \($0) 行：用于验证原生长文本滚动与光标可见性 😀。" }.joined(separator: "\n")
            reset("")
            editor.insertText(longText, replacementRange: NSRange(location: NSNotFound, length: 0))
            layout(editor, in: window)
            let length = (longText as NSString).length
            let viewportHeight = scroll.contentView.bounds.height
            checks["long_text_preserved"] = editor.string == longText && submissions.isEmpty
            checks["long_text_exceeds_viewport"] = viewportHeight > 0 && editor.bounds.height > viewportHeight + 1
            let widthBefore = editor.bounds.width
            editor.setSelectedRange(NSRange(location: length, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            layout(editor, in: window)
            let bottomOrigin = scroll.contentView.bounds.origin.y
            checks["long_text_end_scrolls_into_view"] = bottomOrigin > 0
                && caretIsVisible(editor, in: window)
            try key(.shift)
            layout(editor, in: window)
            checks["long_text_newline_keeps_caret_visible"] = editor.string == longText + "\n"
                && caretIsVisible(editor, in: window) && submissions.isEmpty
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            layout(editor, in: window)
            checks["long_text_start_scrolls_back_into_view"] =
                scroll.contentView.bounds.origin.y < bottomOrigin && caretIsVisible(editor, in: window)
            checks["long_text_does_not_expand_horizontally"] = !editor.isHorizontallyResizable
                && editor.textContainer?.widthTracksTextView == true
                && abs(editor.bounds.width - widthBefore) <= 1
                && editor.bounds.width <= scroll.contentSize.width + 1
            inspectScrollLimits(editor: editor, scroll: scroll, checks: &checks)

            // Leave the viewport at the bottom before both clear paths. Reset uses
            // the same .string assignment as updateNSView, without sizeToFit or
            // manually scrolling to zero: those would conceal a stale-height bug.
            reset("", canSubmit: false)
            inspectClearedViewport(editor: editor, scroll: scroll, window: window,
                                   prefix: "programmatic_clear", checks: &checks)
            editor.insertText(longText, replacementRange: NSRange(location: NSNotFound, length: 0))
            layout(editor, in: window)
            editor.setSelectedRange(NSRange(location: length, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            editor.setSelectedRange(NSRange(location: 0, length: length))
            try key(code: 51, characters: "\u{7F}")
            layout(editor, in: window)
            checks["native_delete_clears_long_selection"] = editor.string.isEmpty && submissions.isEmpty
            inspectClearedViewport(editor: editor, scroll: scroll, window: window,
                                   prefix: "native_delete", checks: &checks)

            reset("焦点切换后继续编辑")
            focusChanges.removeAll()
            let lost = window.makeFirstResponder(nil)
            let gotBack = window.makeFirstResponder(editor)
            checks["focus_loss_and_regain_reported"] = lost && gotBack && focusChanges == [false, true]
                && window.firstResponder === editor && editor.string == "焦点切换后继续编辑"
        }

        // A fresh NSTextView reports upstream for its empty {0, 0} selection.
        // AppKit normalizes setSelectedRanges(..., affinity: .upstream, ...) to
        // downstream there, even when asked to restore the original affinity.
        // Empty text has no wrapped-line side to preserve. Retain exact affinity
        // checks for every nonempty draft and exact attributed text/ranges always.
        let emptyCaretNormalized = snapshot.text.length == 0 && editor.string.isEmpty
            && snapshot.selectedRanges == [NSValue(range: NSRange(location: 0, length: 0))]
            && editor.selectionAffinity == .downstream
        checks["original_text_and_selection_restored"] = editor.attributedString().isEqual(to: snapshot.text)
            && editor.selectedRanges == snapshot.selectedRanges
            && (editor.selectionAffinity == snapshot.affinity || emptyCaretNormalized) && !editor.hasMarkedText()
        checks["original_focus_restored"] = window.firstResponder === snapshot.firstResponder
        checks["original_delegate_and_undo_restored"] = editor.delegate === snapshot.delegate
            && editor.undoManager === snapshot.undo
            && snapshot.undo?.canUndo == snapshot.couldUndo && snapshot.undo?.canRedo == snapshot.couldRedo
            && snapshot.undo?.groupingLevel == snapshot.undoGroupingLevel
            && snapshot.undo?.isUndoRegistrationEnabled == snapshot.undoRegistrationEnabled
        checks["original_composer_settings_restored"] = editor.canSubmit == snapshot.canSubmit
            && editor.placeholder == snapshot.placeholder
            && editor.minSize == snapshot.minSize
            && NSDictionary(dictionary: editor.typingAttributes).isEqual(to: snapshot.typingAttributes)
        checks["original_scroll_position_restored"] =
            abs(scroll.contentView.bounds.origin.x - snapshot.scrollOrigin.x) <= 1
            && abs(scroll.contentView.bounds.origin.y - snapshot.scrollOrigin.y) <= 1
        return checks
    }

    private static func verifyUndo(editor: ChatComposerTextView, undo: UndoManager,
                                   checks: inout [String: Bool], edit: @MainActor () -> Void) {
        let original = editor.string
        undo.enableUndoRegistration()
        defer { undo.disableUndoRegistration() }
        undo.beginUndoGrouping()
        edit()
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        let edited = editor.string
        let registered = undo.canUndo && edited != original
        if undo.canUndo { undo.undo() }
        checks["native_paste_undo_restores_text"] = registered && editor.string == original
        let canRedo = undo.canRedo
        if canRedo { undo.redo() }
        checks["native_paste_redo_restores_text"] = registered && canRedo && editor.string == edited
    }

    private static func withRestoredState(
        editor: ChatComposerTextView, scroll: NSScrollView, window: NSWindow,
        snapshot: Snapshot, probe: ProbeDelegate, body: @MainActor () throws -> Void
    ) rethrows {
        editor.delegate = probe
        defer {
            // Restore while the probe still owns callbacks/undo, including on throw.
            editor.unmarkText()
            editor.breakUndoCoalescing()
            editor.textStorage?.setAttributedString(snapshot.text)
            editor.placeholder = snapshot.placeholder
            editor.canSubmit = snapshot.canSubmit
            editor.minSize = snapshot.minSize
            editor.frame = snapshot.frame
            window.makeFirstResponder(snapshot.firstResponder)
            editor.setSelectedRanges(snapshot.selectedRanges, affinity: snapshot.affinity, stillSelecting: false)
            editor.selectionGranularity = snapshot.granularity
            editor.typingAttributes = snapshot.typingAttributes
            layout(editor, in: window)
            scroll.contentView.scroll(to: snapshot.scrollOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
            probe.isolatedUndo.removeAllActions()
            editor.delegate = snapshot.delegate
            editor.onSubmit = snapshot.onSubmit
            editor.onFocusChange = snapshot.onFocusChange
            editor.needsDisplay = true
        }
        try body()
    }

    private static func keyEvent(in window: NSWindow, flags: NSEvent.ModifierFlags, code: UInt16,
                                 characters: String, repeatKey: Bool) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: repeatKey, keyCode: code
        ) else { throw VerificationError("AppKit could not construct the native keyDown event.") }
        return event
    }

    private static func layout(_ editor: NSTextView, in window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        editor.enclosingScrollView?.tile()
        if let container = editor.textContainer { editor.layoutManager?.ensureLayout(for: container) }
    }

    private static func inspectLowerWritingArea(
        editor: NSTextView, scroll: NSScrollView, window: NSWindow,
        prefix: String, checks: inout [String: Bool]
    ) {
        let clip = scroll.contentView
        let viewport = clip.bounds
        checks[prefix + "_editor_covers_viewport"] = viewport.width > 0 && viewport.height > 0
            && abs(editor.frame.width - viewport.width) <= 1
            && editor.frame.height >= viewport.height - 1
            && abs(editor.minSize.height - viewport.height) <= 1
        // Points are in the writable lower strip, away from an overlay scroller.
        // hitTest takes coordinates in the receiver's SUPERview, while
        // characterIndexForInsertion takes coordinates local to the text view.
        let y = clip.isFlipped ? viewport.maxY - 4 : viewport.minY + 4
        let points = [viewport.minX + 8, viewport.midX, viewport.maxX - 24].map {
            NSPoint(x: $0, y: y)
        }
        guard let root = window.contentView, viewport.width > 48, viewport.height > 8 else {
            checks[prefix + "_lower_strip_hits_editor"] = false
            checks[prefix + "_lower_strip_maps_to_text_end"] = false
            return
        }
        checks[prefix + "_lower_strip_hits_editor"] = points.allSatisfy { point in
            guard let hit = root.hitTest(clip.convert(point, to: root.superview)) else { return false }
            return hit === editor || hit.isDescendant(of: editor)
        }
        checks[prefix + "_lower_strip_maps_to_text_end"] = points.allSatisfy { point in
            editor.characterIndexForInsertion(at: editor.convert(point, from: clip))
                == (editor.string as NSString).length
        }
        // Geometry and insertion hit testing deliberately avoid mouseDown's
        // nested tracking loop, which could process a SwiftUI update mid-spy.
        // This is not a claim that a physical mouse click was dispatched.
    }

    private static func inspectScrollLimits(
        editor: NSTextView, scroll: NSScrollView, checks: inout [String: Bool]
    ) {
        let clip = scroll.contentView
        for (name, offset) in [("minimum", CGFloat(-100_000)), ("maximum", CGFloat(100_000))] {
            var proposed = clip.bounds
            proposed.origin = NSPoint(x: offset, y: offset)
            let constrained = clip.constrainBoundsRect(proposed)
            clip.scroll(to: constrained.origin)
            scroll.reflectScrolledClipView(clip)
            let visible = scroll.documentVisibleRect
            checks["long_text_scroll_" + name + "_stays_in_document"] =
                visible.width > 0 && visible.height > 0
                && editor.bounds.insetBy(dx: -1, dy: -1).contains(visible)
                && abs(visible.minX - editor.bounds.minX) <= 1
            let expectedY = offset < 0 ? editor.bounds.minY : editor.bounds.maxY - visible.height
            checks["long_text_scroll_" + name + "_reaches_edge"] = abs(visible.minY - expectedY) <= 1
        }
    }

    private static func inspectClearedViewport(
        editor: NSTextView, scroll: NSScrollView, window: NSWindow,
        prefix: String, checks: inout [String: Bool]
    ) {
        layout(editor, in: window)
        let viewport = scroll.contentView.bounds
        checks[prefix + "_shrinks_document_to_viewport"] = editor.string.isEmpty
            && abs(editor.frame.height - viewport.height) <= 1
        checks[prefix + "_returns_scroll_to_origin"] = editor.string.isEmpty
            && abs(viewport.minY - editor.frame.minY) <= 1
            && caretIsVisible(editor, in: window)
        inspectLowerWritingArea(editor: editor, scroll: scroll, window: window, prefix: prefix, checks: &checks)
    }

    private static func caretRect(_ editor: NSTextView, in window: NSWindow) -> NSRect {
        let screenRect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        return editor.convert(window.convertFromScreen(screenRect), from: nil)
    }

    private static func caretIsVisible(_ editor: NSTextView, in window: NSWindow) -> Bool {
        let rect = caretRect(editor, in: window)
        return rect.height > 0 && editor.visibleRect.insetBy(dx: -1, dy: -1).contains(
            NSPoint(x: rect.minX, y: rect.midY)
        )
    }

    private static func mountedComposer(in window: NSWindow) async throws -> ChatComposerTextView {
        @MainActor func descendants(of view: NSView) -> [ChatComposerTextView] {
            let here = (view as? ChatComposerTextView).map { [$0] } ?? []
            return here + view.subviews.flatMap { descendants(of: $0) }
        }
        for _ in 0..<40 {
            try Task.checkCancellation()
            if let root = window.contentView {
                root.layoutSubtreeIfNeeded()
                let matches = descendants(of: root).filter {
                    $0.window === window && !$0.isHiddenOrHasHiddenAncestor
                }
                guard matches.count <= 1 else { throw VerificationError("Multiple mounted composers make the target ambiguous.") }
                if let editor = matches.first { return editor }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw VerificationError("ChatComposerTextView was not mounted in the requested window; select ChatView before running.")
    }

    private static func requireIsolatedLaunch() throws {
        let args = CommandLine.arguments
        let flags = args.indices.filter { args[$0] == "--library-path" }
        guard args.contains("--ui-composer-only"), args.contains("--ui-smoke-output"),
              flags.count == 1, let index = flags.first, index + 1 < args.count,
              (args[index + 1] as NSString).isAbsolutePath else {
            throw VerificationError("Composer verification requires --ui-composer-only, --ui-smoke-output, and one explicit --library-path.")
        }
        let root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard root.lastPathComponent == "ui-smoke-library",
              root.deletingLastPathComponent().lastPathComponent.hasPrefix("AskBase-UIVerify-") else {
            throw VerificationError("Refusing composer verification outside AskBase-UIVerify-*/ui-smoke-library.")
        }
        // AppSmokeVerifier additionally checks the opened AppState root and empty
        // documents/notes/conversations. A path name alone cannot prove freshness.
    }

    @MainActor
    private final class ProbeDelegate: NSObject, NSTextViewDelegate {
        let isolatedUndo = UndoManager()
        var changeCount = 0

        override init() {
            super.init()
            isolatedUndo.groupsByEvent = false
            isolatedUndo.disableUndoRegistration()
        }

        func undoManager(for view: NSTextView) -> UndoManager? { isolatedUndo }
        func textDidChange(_ notification: Notification) { changeCount += 1 }
    }

    @MainActor
    private struct Snapshot {
        let text: NSAttributedString
        let selectedRanges: [NSValue]
        let affinity: NSSelectionAffinity
        let granularity: NSSelectionGranularity
        let typingAttributes: [NSAttributedString.Key: Any]
        let frame: NSRect
        let minSize: NSSize
        let scrollOrigin: NSPoint
        let firstResponder: NSResponder?
        let delegate: NSTextViewDelegate?
        let undo: UndoManager?
        let couldUndo: Bool?
        let couldRedo: Bool?
        let undoGroupingLevel: Int?
        let undoRegistrationEnabled: Bool?
        let canSubmit: Bool
        let placeholder: String
        let onSubmit: (() -> Void)?
        let onFocusChange: ((Bool) -> Void)?

        init(editor: ChatComposerTextView, scroll: NSScrollView, window: NSWindow, storage: NSTextStorage) {
            text = NSAttributedString(attributedString: storage)
            selectedRanges = editor.selectedRanges
            affinity = editor.selectionAffinity
            granularity = editor.selectionGranularity
            typingAttributes = editor.typingAttributes
            frame = editor.frame
            minSize = editor.minSize
            scrollOrigin = scroll.contentView.bounds.origin
            firstResponder = window.firstResponder
            delegate = editor.delegate
            undo = editor.undoManager
            couldUndo = undo?.canUndo
            couldRedo = undo?.canRedo
            undoGroupingLevel = undo?.groupingLevel
            undoRegistrationEnabled = undo?.isUndoRegistrationEnabled
            canSubmit = editor.canSubmit
            placeholder = editor.placeholder
            onSubmit = editor.onSubmit
            onFocusChange = editor.onFocusChange
        }
    }

    private struct VerificationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
