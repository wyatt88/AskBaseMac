import AppKit
import AVKit
import Combine
import ImageIO
import SwiftUI
import AskBaseCore

struct MediaPlaybackBounds: Equatable {
    let start: Double
    let end: Double

    init(media: MediaReference, duration: Double) throws {
        guard duration.isFinite, duration > 0,
              (media.startSeconds == nil) == (media.endSeconds == nil) else {
            throw AskBaseError.invalidInput("原文件时长或片段位置无效，请重新索引这份资料。")
        }
        let start = media.startSeconds ?? 0
        let end = media.endSeconds ?? duration
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              start < duration, end <= duration + 0.05 else {
            throw AskBaseError.invalidInput("索引片段超出了原文件时长，请重新索引后再预览。")
        }
        self.start = start
        self.end = min(end, duration)
    }

    var label: String { "\(MediaReference.timestamp(start))–\(MediaReference.timestamp(end))" }
}

struct DecodedPreviewImage {
    let image: CGImage
    let index: Int
    let count: Int
}

enum PreviewImageDecoder {
    static func decode(url: URL, index: Int) throws -> DecodedPreviewImage {
        try Task.checkCancellation()
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary) else {
            throw AskBaseError.invalidInput("无法读取这份本机图片，文件可能已损坏或格式不受系统支持。")
        }
        let count = CGImageSourceGetCount(source)
        guard index >= 0, index < count else {
            throw AskBaseError.invalidInput("索引指定的帧／页不在原图的 \(count) 帧／页中，请重新索引。")
        }
        // This bounds display resolution only; every original frame remains selectable.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else {
            throw AskBaseError.invalidInput("无法解码原图的第 \(index + 1) 帧／页。")
        }
        try Task.checkCancellation()
        return DecodedPreviewImage(image: image, index: index, count: count)
    }
}

@MainActor
final class MediaPreviewController: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var imageIndex = 0
    @Published private(set) var imageCount = 0
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = false
    @Published private(set) var isSeeking = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isWholeFile = false
    @Published private(set) var currentSeconds = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var selectedBounds: MediaPlaybackBounds?
    @Published private(set) var error: String?

    private var generation = UUID()
    private var seekToken = UUID()
    private var imageURL: URL?
    private var imageTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var itemObservation: NSKeyValueObservation?
    private var failedPlaybackObserver: NSObjectProtocol?
    private var endedPlaybackObserver: NSObjectProtocol?

    var playbackStart: Double { isWholeFile ? 0 : selectedBounds?.start ?? 0 }
    var playbackEnd: Double { isWholeFile ? duration : selectedBounds?.end ?? duration }
    var atEnd: Bool { playbackEnd > 0 && currentSeconds >= playbackEnd - 0.03 }

    func load(media: MediaReference, resolveURL: () async throws -> URL) async {
        clear()
        let request = generation
        isLoading = true
        do {
            let url = try await resolveURL()
            try Task.checkCancellation()
            guard generation == request else { return }
            guard url.isFileURL else { throw AskBaseError.invalidInput("预览只接受经过验证的本机原文件。") }
            if media.kind == .image {
                let decoded = try await Self.decodeImage(url: url, index: media.imageIndex ?? 0)
                try Task.checkCancellation()
                guard generation == request else { return }
                imageURL = url
                apply(decoded)
            } else {
                let asset = AVURLAsset(url: url, options: [
                    AVURLAssetPreferPreciseDurationAndTimingKey: true,
                    AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
                ])
                let playable = try await asset.load(.isPlayable)
                let assetDuration = try await asset.load(.duration)
                try Task.checkCancellation()
                guard generation == request else { return }
                guard playable else {
                    throw AskBaseError.invalidInput("macOS 无法播放此文件的编码。可在 Finder 中检查原文件或转换编码后重新导入。")
                }
                let bounds = try MediaPlaybackBounds(media: media, duration: assetDuration.seconds)
                duration = assetDuration.seconds
                selectedBounds = bounds
                isWholeFile = media.startSeconds == nil
                currentSeconds = bounds.start
                let item = AVPlayerItem(asset: asset)
                let playback = AVPlayer(playerItem: item)
                playback.actionAtItemEnd = .pause
                player = playback
                configurePlaybackBounds()
                observe(playback, item: item)
                let positioned = await playback.seek(
                    to: CMTime(seconds: bounds.start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero
                )
                try Task.checkCancellation()
                guard generation == request, player === playback else { return }
                guard positioned else { throw AskBaseError.invalidInput("无法定位所选片段，请重新读取原文件。") }
                // Loading, selecting a source and seeking never start playback.
                playback.pause()
            }
            isLoading = false
        } catch {
            guard generation == request else { return }
            clear()
            if !(error is CancellationError), !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    func selectImage(at index: Int) {
        guard let url = imageURL, index >= 0, index < imageCount else { return }
        imageTask?.cancel()
        let request = UUID()
        generation = request
        image = nil
        isLoading = true
        error = nil
        imageTask = Task {
            do {
                let decoded = try await Self.decodeImage(url: url, index: index)
                try Task.checkCancellation()
                guard generation == request else { return }
                apply(decoded)
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            guard generation == request else { return }
            isLoading = false
            imageTask = nil
        }
    }

    func togglePlayback() {
        guard let player, !isLoading, !isSeeking, error == nil else { return }
        if isPlaying || player.rate != 0 {
            player.pause()
            isPlaying = false
        } else if atEnd {
            seek(to: playbackStart, playAfterSeeking: true)
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double, playAfterSeeking: Bool = false) {
        guard let player, seconds.isFinite, error == nil else { return }
        let position = min(max(seconds, playbackStart), playbackEnd)
        player.pause()
        isPlaying = false
        isSeeking = true
        currentSeconds = position
        seekToken = UUID()
        let token = seekToken
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            Task { @MainActor in
                guard let self, let player, self.player === player, self.seekToken == token else { return }
                self.isSeeking = false
                if !finished {
                    self.error = "未能定位到这个时间，请重新读取预览。"
                } else if playAfterSeeking {
                    player.play()
                    self.isPlaying = true
                }
            }
        }
    }

    func setWholeFile(_ wholeFile: Bool) {
        guard player != nil, isWholeFile != wholeFile else { return }
        player?.pause()
        isPlaying = false
        isWholeFile = wholeFile
        configurePlaybackBounds()
        seek(to: playbackStart)
    }

    /// Window detachment can precede SwiftUI disappearance. Invalidate a pending
    /// replay seek synchronously so its completion cannot restart a closed view.
    func stopPlayback(for attachedPlayer: AVPlayer) {
        attachedPlayer.pause()
        attachedPlayer.currentItem?.cancelPendingSeeks()
        guard player === attachedPlayer else { return }
        let token = UUID()
        seekToken = token
        // AppKit may detach the native view during a SwiftUI update.
        Task { @MainActor [weak self, weak attachedPlayer] in
            guard let self, let attachedPlayer, self.player === attachedPlayer,
                  self.seekToken == token else { return }
            self.isPlaying = false
            self.isSeeking = false
        }
    }

    func clear() {
        generation = UUID()
        seekToken = UUID()
        imageTask?.cancel()
        imageTask = nil
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemObservation?.invalidate()
        itemObservation = nil
        if let failedPlaybackObserver { NotificationCenter.default.removeObserver(failedPlaybackObserver) }
        failedPlaybackObserver = nil
        if let endedPlaybackObserver { NotificationCenter.default.removeObserver(endedPlaybackObserver) }
        endedPlaybackObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        image = nil
        imageURL = nil
        imageIndex = 0
        imageCount = 0
        isLoading = false
        isSeeking = false
        isPlaying = false
        isWholeFile = false
        currentSeconds = 0
        duration = 0
        selectedBounds = nil
        error = nil
    }

    private static func decodeImage(url: URL, index: Int) async throws -> DecodedPreviewImage {
        let task = Task.detached(priority: .userInitiated) {
            try PreviewImageDecoder.decode(url: url, index: index)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func apply(_ decoded: DecodedPreviewImage) {
        image = NSImage(cgImage: decoded.image, size: .zero)
        imageIndex = decoded.index
        imageCount = decoded.count
    }

    private func configurePlaybackBounds() {
        player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: playbackEnd, preferredTimescale: 600)
        player?.currentItem?.reversePlaybackEndTime = CMTime(seconds: playbackStart, preferredTimescale: 600)
    }

    private func observe(_ playback: AVPlayer, item: AVPlayerItem) {
        timeObserver = playback.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self, weak playback] time in
            Task { @MainActor in
                guard let self, let playback, self.player === playback, !self.isSeeking,
                      time.seconds.isFinite else { return }
                self.currentSeconds = min(max(time.seconds, self.playbackStart), self.playbackEnd)
                if time.seconds >= self.playbackEnd {
                    playback.pause()
                }
                self.isPlaying = playback.rate != 0
            }
        }
        itemObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.player?.currentItem === item, item.status == .failed else { return }
                self.player?.pause()
                self.isPlaying = false
                self.error = item.error?.localizedDescription ?? "系统无法解码此媒体。"
            }
        }
        failedPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.player?.currentItem === item else { return }
                self.player?.pause()
                self.isPlaying = false
                self.error = item.error?.localizedDescription ?? "原文件播放中断，请重新读取预览。"
            }
        }
        endedPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.player?.currentItem === item else { return }
                self.player?.pause()
                self.isPlaying = false
                self.currentSeconds = self.playbackEnd
            }
        }
    }
}

private struct MediaPreviewIdentity: Equatable {
    let documentID: String
    let knowledgeBaseID: String?
    let updatedAt: Date
    let media: MediaReference
    let retry: Int
    let selectionRevision: Int
}

struct MediaPreviewView: View {
    @EnvironmentObject private var state: AppState
    let document: LibraryDocument
    let media: MediaReference
    var selectionRevision = 0
    @StateObject private var preview = MediaPreviewController()
    @State private var retry = 0
    #if DEBUG
    @State private var probeID = UUID()
    #endif

    private var identity: MediaPreviewIdentity {
        MediaPreviewIdentity(documentID: document.id, knowledgeBaseID: state.selectedKnowledgeBaseID,
                             updatedAt: document.updatedAt, media: media, retry: retry,
                             selectionRevision: selectionRevision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("本机原件 · \(media.kind.label)", systemImage: media.kind.symbol)
                .font(.callout.weight(.semibold))
            if preview.isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在读取\(MediaEvidence.position(for: media))…").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 80)
            } else if let error = preview.error {
                ErrorPanel(title: "无法预览原件", message: error, actionTitle: "重新读取") { retry += 1 }
            } else if let image = preview.image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .accessibilityLabel("\(document.title)，原图第 \(preview.imageIndex + 1) 帧／页")
                if preview.imageCount > 1 {
                    HStack(spacing: 9) {
                        Button { preview.selectImage(at: preview.imageIndex - 1) } label: {
                            Image(systemName: "chevron.left")
                        }.disabled(preview.imageIndex == 0).help("上一帧／页")
                        Text("第 \(preview.imageIndex + 1) / \(preview.imageCount) 帧／页")
                            .font(.caption).monospacedDigit()
                        Button { preview.selectImage(at: preview.imageIndex + 1) } label: {
                            Image(systemName: "chevron.right")
                        }.disabled(preview.imageIndex + 1 >= preview.imageCount).help("下一帧／页")
                        Spacer(minLength: 0)
                        if preview.imageIndex != (media.imageIndex ?? 0) {
                            Button("回到所选帧") { preview.selectImage(at: media.imageIndex ?? 0) }
                        }
                    }.controlSize(.small)
                }
            } else if let player = preview.player {
                LocalMediaPlayerView(player: player) { [weak preview] attachedPlayer in
                    preview?.stopPlayback(for: attachedPlayer)
                }
                    .frame(height: media.kind == .video ? 230 : 52)
                    .overlay {
                        if media.kind == .audio {
                            Label("本机音频", systemImage: "waveform")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(AppPalette.inset)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                playbackControls
            }
        }
        .padding(15)
        .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppPalette.line))
        .task(id: identity) {
            await preview.load(media: media) { try await state.originalURL(for: document.id) }
        }
        .onAppear {
            #if DEBUG
            MediaPreviewProbe.attach(id: probeID, documentID: document.id, controller: preview)
            #endif
        }
        .onDisappear {
            preview.clear()
            #if DEBUG
            MediaPreviewProbe.detach(id: probeID)
            #endif
        }
        .accessibilityIdentifier("localMediaPreview")
    }

    private var playbackControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            Picker("播放范围", selection: Binding(
                get: { preview.isWholeFile }, set: { preview.setWholeFile($0) }
            )) {
                Text("所选片段").tag(false)
                Text("完整文件").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(preview.isSeeking)
            Text(preview.isWholeFile
                 ? "完整文件模式 · 可播放全部 \(MediaReference.timestamp(preview.duration))"
                 : "所选片段 \(preview.selectedBounds?.label ?? media.positionLabel) · 到终点自动停止")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button { preview.togglePlayback() } label: {
                    Label(preview.isPlaying ? "暂停" : preview.atEnd ? "重新播放" : "播放",
                          systemImage: preview.isPlaying ? "pause.fill" : "play.fill")
                }
                .controlSize(.small)
                .disabled(preview.isSeeking)
                .accessibilityIdentifier("mediaPlayPause")
                Slider(value: Binding(
                    get: { preview.currentSeconds },
                    set: { preview.seek(to: $0) }
                ), in: preview.playbackStart...max(preview.playbackStart, preview.playbackEnd))
                .accessibilityLabel("播放位置")
                Text(MediaReference.timestamp(preview.currentSeconds))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(preview.isSeeking ? "正在定位…" : "点击播放开始；切换片段或拖动定位后保持暂停。")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

private struct LocalMediaPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let stopPlayback: (AVPlayer) -> Void

    func makeNSView(context: Context) -> PreviewPlayerView {
        let view = PreviewPlayerView()
        // The bounded native SwiftUI controls above are the only playback controls.
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.stopPlayback = stopPlayback
        view.player = player
        return view
    }

    func updateNSView(_ view: PreviewPlayerView, context: Context) {
        if view.player !== player {
            view.stopAttachedPlayback()
            view.player = player
        }
        view.stopPlayback = stopPlayback
    }

    static func dismantleNSView(_ view: PreviewPlayerView, coordinator: ()) {
        view.stopAttachedPlayback()
        view.stopPlayback = nil
        view.player = nil
    }
}

/// Window close can precede SwiftUI disappearance. Stop the exact attached player
/// without changing the application's production termination behavior.
private final class PreviewPlayerView: AVPlayerView {
    var stopPlayback: ((AVPlayer) -> Void)?
    private var closeObserver: NSObjectProtocol?

    func stopAttachedPlayback() {
        guard let player else { return }
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        stopPlayback?(player)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if let newWindow {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: newWindow, queue: .main
            ) { [weak self] _ in
                self?.stopAttachedPlayback()
            }
        } else if window != nil {
            stopAttachedPlayback()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}

#if DEBUG
/// The smoke verifier reads the controller belonging to the actual presented
/// SwiftUI view. Weak references never keep a dismissed preview alive.
@MainActor
enum MediaPreviewProbe {
    private struct Entry {
        let documentID: String
        weak var controller: MediaPreviewController?
    }
    private static var entries: [UUID: Entry] = [:]

    static func attach(id: UUID, documentID: String, controller: MediaPreviewController) {
        entries[id] = Entry(documentID: documentID, controller: controller)
    }

    static func detach(id: UUID) { entries[id] = nil }

    static func controller(for documentID: String) -> MediaPreviewController? {
        entries.values.first { $0.documentID == documentID && $0.controller != nil }?.controller
    }
}
#endif
