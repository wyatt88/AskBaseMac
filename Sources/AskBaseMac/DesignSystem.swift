import AppKit
import SwiftUI
import AskBaseCore

enum AppPalette {
    static let accent = adaptive(
        light: NSColor(red: 0.10, green: 0.43, blue: 0.38, alpha: 1),
        dark: NSColor(red: 0.43, green: 0.77, blue: 0.68, alpha: 1)
    )
    static let canvas = adaptive(
        light: NSColor(red: 0.97, green: 0.966, blue: 0.95, alpha: 1),
        dark: NSColor(red: 0.105, green: 0.115, blue: 0.115, alpha: 1)
    )
    static let surface = adaptive(
        light: NSColor(red: 0.997, green: 0.995, blue: 0.985, alpha: 1),
        dark: NSColor(red: 0.145, green: 0.155, blue: 0.155, alpha: 1)
    )
    static let inset = adaptive(
        light: NSColor(red: 0.945, green: 0.943, blue: 0.926, alpha: 1),
        dark: NSColor(red: 0.125, green: 0.135, blue: 0.135, alpha: 1)
    )
    static let line = Color.primary.opacity(0.08)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 26, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 23)
    }
}

struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 66, height: 66)
                .background(AppPalette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 390)
            actions.padding(.top, 5)
        }
        .padding(30)
        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusPill: View {
    var label: String
    var color: Color = AppPalette.accent
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
            } else {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.085), in: Capsule())
        .fixedSize()
    }
}

struct DocumentStatusLabel: View {
    let status: DocumentStatus
    var reindexing = false
    var queued = false

    var body: some View {
        if reindexing {
            StatusPill(label: "正在重建", color: .secondary, symbol: "arrow.triangle.2.circlepath")
        } else if queued {
            StatusPill(label: "等待重建", color: .secondary, symbol: "clock")
        } else {
            switch status {
            case .ready: StatusPill(label: status.label)
            case .indexing: StatusPill(label: status.label, color: .secondary)
            case .failed: StatusPill(label: status.label, color: .orange, symbol: "exclamationmark.circle")
            }
        }
    }
}

struct TagLabel: View {
    let text: String

    var body: some View {
        Text(text).font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(AppPalette.inset, in: RoundedRectangle(cornerRadius: 5))
            .lineLimit(1)
            .help(text)
    }
}

struct ErrorPanel: View {
    var title = "暂时无法完成"
    let message: String
    var actionTitle: String? = nil
    var isActionDisabled = false
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                CopyTextButton(text: message)
            }
            ScrollView {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 28, maxHeight: 115)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small).disabled(isActionDisabled)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.17)))
    }
}

struct CopyTextButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("复制完整文字")
        .onChange(of: text) { _, _ in copied = false }
    }
}

struct SourceCard: View {
    let source: SearchResult
    let number: Int
    var compact = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: compact ? 7 : 12) {
                HStack(alignment: .top, spacing: 10) {
                    Text("[\(number)]").font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(AppPalette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.title).font(compact ? .callout.weight(.medium) : .headline)
                            .foregroundStyle(.primary).lineLimit(2)
                        if let page = source.page {
                            Text("第 \(page) 页").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.caption)
                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                Text(source.text)
                    .font(compact ? .caption : .body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(compact ? 2 : 4)
                    .lineLimit(compact ? 2 : 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !compact {
                    HStack {
                        Text("查看来源与原文件").foregroundStyle(AppPalette.accent)
                        Spacer()
                        if source.score.isFinite {
                            Text("排序分数 \(source.score.formatted(.number.precision(.fractionLength(3))))")
                                .foregroundStyle(.tertiary)
                                .help("检索排序分数，不代表答案正确的概率。")
                        }
                    }.font(.caption)
                }
            }
            .padding(compact ? 12 : 19)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(AppPalette.line))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("来源 \(number)，\(source.sourceLabel)")
        .accessibilityHint("打开引用全文和原始文件")
    }
}

struct ElapsedLabel: View {
    let startedAt: Date
    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分 \(seconds % 60) 秒")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct ConnectionLine: View {
    let title: String
    let available: Bool?
    var checking = false
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(checking ? Color.secondary.opacity(0.4) :
                        available == true ? AppPalette.accent :
                        available == false ? Color.orange : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(title)
            Spacer(minLength: 8)
            Text(checking ? "检测中" : available == true ? "已连接" : available == false ? "未就绪" : "未检测")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

extension LibraryDocument {
    var displayFileType: String {
        let ext = (fileName as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "文件" : ext
    }
    var fileSymbol: String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "md", "markdown": "doc.plaintext"
        case "swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "c", "cpp", "h", "java", "sh":
            "chevron.left.forwardslash.chevron.right"
        default: "doc.text"
        }
    }
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
