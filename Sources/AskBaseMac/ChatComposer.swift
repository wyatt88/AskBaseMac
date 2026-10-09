import AppKit
import SwiftUI

/// One TextKit coordinate system for the draft, insertion point and placeholder.
struct ChatComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var canSubmit: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ChatComposerScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let editor = ChatComposerTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .labelColor
        editor.insertionPointColor = NSColor(AppPalette.accent)
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("向当前知识库提问")
        editor.setAccessibilityIdentifier("chatQuestion")
        editor.setAccessibilityPlaceholderValue(editor.placeholder)
        editor.delegate = context.coordinator
        editor.onFocusChange = { [weak coordinator = context.coordinator] focused in
            guard let coordinator, !coordinator.isUpdatingView else { return }
            coordinator.parent.focused = focused
        }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ChatComposerTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.isUpdatingView = true
        defer { coordinator.isUpdatingView = false }
        editor.canSubmit = canSubmit
        editor.onSubmit = onSubmit
        // Pre-edit text may differ from the binding before an IME commits it.
        // Only an actual binding change may replace that text during a redraw.
        let draftChanged = coordinator.lastBoundText != text
        coordinator.lastBoundText = text
        if draftChanged && editor.string != text {
            if editor.hasMarkedText() {
                editor.unmarkText()
                editor.inputContext?.discardMarkedText()
            }
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            editor.undoManager?.removeAllActions()
            editor.needsDisplay = true
        }
        editor.focusWhenAttached = focused
        if focused, let window = editor.window, window.firstResponder !== editor {
            window.makeFirstResponder(editor)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposer
        var isUpdatingView = false
        var lastBoundText: String?

        init(_ parent: ChatComposer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingView, let editor = notification.object as? ChatComposerTextView else { return }
            lastBoundText = editor.string
            parent.text = editor.string
            editor.needsDisplay = true
        }
    }
}

private final class ChatComposerScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let editor = documentView as? NSTextView else { return }
        // The entire empty writing area remains clickable, including below the first line.
        editor.minSize = NSSize(width: 0, height: contentSize.height)
        let size = NSSize(width: contentSize.width, height: max(editor.frame.height, contentSize.height))
        if editor.frame.size != size { editor.setFrameSize(size) }
    }
}

final class ChatComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var canSubmit = false
    var onFocusChange: ((Bool) -> Void)?
    var focusWhenAttached = false
    var placeholder = "向当前知识库提问…" {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let insertsNewline = !event.modifierFlags.intersection([.shift, .option, .control]).isEmpty
        if isReturn && !insertsNewline && !hasMarkedText() {
            // The IME consumes its confirming Return through super. Never also send it.
            if !event.isARepeat && canSubmit { onSubmit?() }
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusWhenAttached { window?.makeFirstResponder(self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let textContainer else { return }
        let storage = NSTextStorage(string: placeholder, attributes: [
            .font: font ?? NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default,
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: textContainer.containerSize)
        container.lineFragmentPadding = textContainer.lineFragmentPadding
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: textContainerOrigin)
    }
}
