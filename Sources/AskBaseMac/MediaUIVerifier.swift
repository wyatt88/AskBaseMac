#if DEBUG
import AVFoundation
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AskBaseCore

/// Synthetic, offline behavior checks. This entry point never opens NSApplication,
/// the installed app, a real model endpoint, or the normal user library.
/// Player preparation is separately opt-in for the coordinated UI smoke run.
@MainActor
enum MediaUIVerifier {
    /// One PNG frame and one two-second audio segment: two import embeddings
    /// plus one query embedding for each file, for a planned four media requests.
    static func makeNativeSmokeFixtures(in directory: URL) throws -> (image: URL, audio: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("AskBase-synthetic-image.png")
        let audioURL = directory.appendingPathComponent("AskBase-synthetic-audio.wav")
        guard let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
                                      bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(
                imageURL as CFURL, UTType.png.identifier as CFString, 1, nil
              ) else { throw AskBaseError.storage("Cannot create native UI image fixture.") }
        context.setFillColor(red: 0.96, green: 0.97, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 44, y: 36, width: 552, height: 104))
        for (text, y) in [("ASKBASE MEDIA TEST", 268.0), ("LOCAL IMAGE 01", 208.0)] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 36, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1),
            ]))
            context.textPosition = CGPoint(x: 44, y: y)
            CTLineDraw(line, context)
        }
        guard let image = context.makeImage() else { throw AskBaseError.storage("Cannot render native UI image fixture.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AskBaseError.storage("Cannot save native UI image fixture.") }
        try makeAudio(at: audioURL)
        return (imageURL, audioURL)
    }

    static func run(includePlayerChecks: Bool = false) async throws -> [String: Bool] {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskBase-MediaUIChecks-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var checks: [String: Bool] = [:]
        let imageURL = temporary.appendingPathComponent("synthetic-frames.tiff")
        try makeImage(at: imageURL)
        let first = try PreviewImageDecoder.decode(url: imageURL, index: 0)
        let second = try PreviewImageDecoder.decode(url: imageURL, index: 1)
        checks["image_selected_frame"] = second.index == 1 && second.count == 2
            && isBlue(second.image) && !isBlue(first.image)
        checks["image_orientation_applied"] = first.image.width == 32 && first.image.height == 20
            && second.image.width == 20 && second.image.height == 32
        do {
            _ = try PreviewImageDecoder.decode(url: imageURL, index: Int.max)
            checks["image_missing_frame_rejected"] = false
        } catch { checks["image_missing_frame_rejected"] = true }

        let audio = MediaReference(kind: .audio, startSeconds: 0.5, endSeconds: 1.5)
        let bounds = try MediaPlaybackBounds(media: audio, duration: 2)
        checks["clip_bounds_preserved"] = bounds.start == 0.5 && bounds.end == 1.5
        do {
            _ = try MediaPlaybackBounds(media: .init(kind: .video, startSeconds: 3, endSeconds: 4), duration: 2)
            checks["invalid_clip_rejected"] = false
        } catch { checks["invalid_clip_rejected"] = true }
        do {
            _ = try MediaPlaybackBounds(media: .init(kind: .audio, startSeconds: .nan, endSeconds: 1), duration: 2)
            checks["nonfinite_clip_rejected"] = false
        } catch { checks["nonfinite_clip_rejected"] = true }
        checks["media_placeholder_not_readable"] = !MediaEvidence.isReadable(text: "音频 · 00:00–00:01", media: audio)
        checks["ocr_evidence_readable"] = MediaEvidence.isReadable(
            text: "合成测试图片中的文字", media: .init(kind: .image, textSource: .ocr)
        )
        checks["empty_ocr_not_readable"] = !MediaEvidence.isReadable(
            text: " \n", media: .init(kind: .image, textSource: .ocr)
        )
        checks["legacy_text_readable"] = MediaEvidence.isReadable(text: "原有文字证据", media: nil)
        checks["unknown_modalities_explained"] = EmbeddingCapabilities(status: ModelStatus(embeddingAvailable: true))
            .mediaUnavailableReason != nil
        checks["text_only_media_unavailable"] = EmbeddingCapabilities(
            status: ModelStatus(embeddingAvailable: true, embeddingModalities: ["text"])
        ).mediaUnavailableReason?.contains("图片、音频、视频") == true
        checks["all_reported_modalities_ready"] = EmbeddingCapabilities(
            status: ModelStatus(embeddingAvailable: true, embeddingModalities: ["text", "image", "audio", "video"])
        ).mediaUnavailableReason == nil
        checks["offline_service_not_ready"] = EmbeddingCapabilities(
            status: ModelStatus(embeddingAvailable: false, embeddingDetail: "合成离线错误",
                                embeddingModalities: ["text", "image", "audio", "video"])
        ).mediaUnavailableReason?.contains("合成离线错误") == true

        let preview = MediaPreviewController()
        await preview.load(media: .init(kind: .image, imageIndex: 1)) { imageURL }
        checks["image_controller_honors_index"] = preview.image != nil && preview.imageIndex == 1 && preview.error == nil
        preview.clear()
        checks["image_clear_releases_preview"] = preview.image == nil && preview.player == nil && !preview.isLoading
        let gate = AsyncStream<URL>.makeStream()
        let delayed = Task {
            await preview.load(media: .init(kind: .image)) {
                var iterator = gate.stream.makeAsyncIterator()
                guard let url = await iterator.next() else { throw CancellationError() }
                return url
            }
        }
        try await wait { preview.isLoading }
        preview.clear()
        gate.continuation.yield(imageURL)
        gate.continuation.finish()
        await delayed.value
        checks["late_preview_does_not_reappear"] = preview.image == nil && preview.player == nil && !preview.isLoading
        await preview.load(media: .init(kind: .image)) { URL(string: "https://invalid.example/image.png")! }
        checks["nonlocal_preview_rejected_without_fetch"] = preview.error != nil && preview.image == nil
        preview.clear()

        checks.merge(try await verifySearchState(in: temporary)) { _, new in new }
        if includePlayerChecks {
            let audioURL = temporary.appendingPathComponent("synthetic-silence.wav")
            try makeAudio(at: audioURL)
            await preview.load(media: audio) { audioURL }
            checks["audio_prepared_without_autoplay"] = preview.player != nil && preview.error == nil
                && preview.player?.rate == 0 && !preview.isPlaying
            checks["audio_positioned_at_clip_start"] = abs((preview.player?.currentTime().seconds ?? -1) - 0.5) < 0.02
            checks["audio_stops_at_clip_end_configured"] = preview.player?.currentItem?.forwardPlaybackEndTime.seconds == 1.5
            let previousPlayer = preview.player
            preview.seek(to: 1.5)
            try await wait { !preview.isSeeking }
            preview.togglePlayback()
            if let previousPlayer { preview.stopPlayback(for: previousPlayer) }
            try await wait { !preview.isSeeking }
            checks["detached_preview_cannot_resume_replay"] = previousPlayer != nil
                && previousPlayer?.rate == 0 && !preview.isPlaying
            preview.setWholeFile(true)
            try await wait { !preview.isSeeking }
            checks["whole_file_explicit_and_paused"] = preview.isWholeFile && preview.playbackStart == 0
                && abs(preview.playbackEnd - 2) < 0.02 && preview.player?.rate == 0
            preview.setWholeFile(false)
            try await wait { !preview.isSeeking }
            checks["clip_restored_without_autoplay"] = !preview.isWholeFile && preview.playbackStart == 0.5
                && preview.playbackEnd == 1.5 && preview.player?.rate == 0
            await preview.load(media: .init(kind: .image, imageIndex: 1)) { imageURL }
            checks["switch_source_releases_player"] = previousPlayer != nil && previousPlayer?.rate == 0
                && previousPlayer?.currentItem == nil && preview.player == nil && preview.image != nil
            preview.clear()
        }
        return checks
    }

    private static func verifySearchState(in temporary: URL) async throws -> [String: Bool] {
        let provider = DeferredUIEmbedder()
        let root = temporary.appendingPathComponent("library")
        let engine = try KnowledgeEngine(root: root, embeddingClient: provider, chatClient: OfflineUIChat())
        let base = try await engine.snapshot().knowledgeBases[0]
        let otherBase = try await engine.createKnowledgeBase(name: "另一合成知识库")
        let textURL = temporary.appendingPathComponent("synthetic.txt")
        try "合成文字资料，只供离线界面检查。".write(to: textURL, atomically: true, encoding: .utf8)
        // Prepare text directly so these state checks do not invoke media extraction or OCR.
        let prepared = try DocumentImporter.prepare(
            url: textURL, knowledgeBaseID: base.id, originalsRoot: engine.root.appendingPathComponent("Originals")
        )
        let store = try LibraryStore(root: root)
        try store.upsertDocument(prepared.document)
        var chunks = prepared.chunks
        for index in chunks.indices {
            chunks[index].embedding = DeferredUIEmbedder.vector
            chunks[index].encoderSignature = DeferredUIEmbedder.signature
        }
        try store.replaceChunks(documentID: prepared.document.id, chunks: chunks)
        let state = AppState(verificationEngine: engine)
        defer {
            UserDefaults.standard.removeObject(forKey: "AskBaseLocal.selectedKnowledgeBase.\(engine.root.standardizedFileURL.path)")
        }
        await state.start()
        state.selectKnowledgeBase(base.id)
        var checks: [String: Bool] = [:]
        state.searchQuery = "合成文字资料"
        state.runSearch()
        await state.verificationSearchTask?.value
        checks["text_search_retains_results"] = state.searchError == nil && state.searchResults.count == 1
            && state.searchedInput == .text("合成文字资料")
        let source = state.searchResults.first
        let original = try await state.originalURL(for: prepared.document.id)
        checks["preview_uses_engine_original_url"] = original == (try await engine.originalURL(documentID: prepared.document.id))

        let firstURL = temporary.appendingPathComponent("first-media.unlisted")
        let secondURL = temporary.appendingPathComponent("second-media")
        try Data("Synthetic selection; the fake health call fails before media extraction.".utf8).write(to: firstURL)
        try Data("Another synthetic selection.".utf8).write(to: secondURL)
        await provider.deferHealth()
        state.selectSearchMedia(firstURL)
        state.runSearch()
        let cancelledTask = state.verificationSearchTask
        try await wait { await provider.waitingIDs.count == 1 }
        let cancelledID = await provider.waitingIDs[0]
        checks["media_query_method_visible"] = state.searchedInput == .media(firstURL) && state.searchedQuery.isEmpty
        state.cancelSearch()
        checks["search_cancellation_pending_visible"] = state.isSearching && state.isCancellingSearch
        await provider.fail(id: cancelledID, message: "合成取消后的迟到错误")
        await cancelledTask?.value
        checks["media_cancel_retains_selection"] = !state.isSearching && !state.isCancellingSearch
            && !state.hasSearched && state.searchError == nil && state.searchMediaURL == firstURL
            && state.searchNotice?.contains("取消") == true

        state.runSearch()
        let oldTask = state.verificationSearchTask
        try await wait { await provider.waitingIDs.count == 1 }
        let oldID = await provider.waitingIDs[0]
        state.selectSearchMedia(secondURL)
        state.runSearch()
        let newTask = state.verificationSearchTask
        try await wait { await provider.waitingIDs.count == 2 }
        let newID = await provider.waitingIDs.last!
        await provider.fail(id: oldID, message: "旧查询错误")
        await oldTask?.value
        checks["late_old_query_cannot_replace_selection"] = state.isSearching && state.searchError == nil
            && state.searchedInput == .media(secondURL) && state.searchMediaURL == secondURL
        await provider.fail(id: newID, message: "新查询错误")
        await newTask?.value
        checks["current_media_error_reported"] = state.searchError?.contains("新查询错误") == true && !state.isSearching
        checks["file_name_never_sent_as_text"] = await provider.textQueries == ["合成文字资料"]
        checks["no_real_media_encoding_in_state_checks"] = await provider.mediaCalls == 0

        state.useTextSearch()
        checks["return_to_text_keeps_text_draft"] = state.searchMediaURL == nil && state.searchQuery == "合成文字资料"
            && state.searchedInput == nil && state.searchError == nil
        state.runSearch()
        await state.verificationSearchTask?.value
        checks["text_search_after_media_retains_results"] = state.searchError == nil && state.searchResults.count == 1

        state.selectSearchMedia(firstURL)
        state.runSearch()
        let switchingTask = state.verificationSearchTask
        try await wait { await provider.waitingIDs.count == 1 }
        let switchingID = await provider.waitingIDs[0]
        state.selectedDocumentID = prepared.document.id
        if let source { state.sheet = .source(source) }
        state.selectKnowledgeBase(otherBase.id)
        await provider.fail(id: switchingID, message: "前一知识库迟到错误")
        await switchingTask?.value
        checks["switch_library_clears_old_search_and_source"] = state.searchResults.isEmpty && state.searchMediaURL == nil
            && state.searchedInput == nil && state.searchError == nil && state.selectedDocumentID == nil
            && state.sheet == nil && !state.isSearching
        do {
            _ = try await state.originalURL(for: prepared.document.id)
            checks["previous_library_preview_rejected"] = false
        } catch { checks["previous_library_preview_rejected"] = true }
        state.selectKnowledgeBase(base.id)
        state.selectedDocumentID = prepared.document.id
        if let source { state.sheet = .source(source) }
        try await engine.deleteDocument(id: prepared.document.id)
        await state.refresh()
        checks["deleted_source_selection_cleared"] = state.sheet == nil && state.selectedDocumentID == nil
            && state.searchResults.isEmpty
        do {
            _ = try await state.originalURL(for: prepared.document.id)
            checks["deleted_original_preview_rejected"] = false
        } catch { checks["deleted_original_preview_rejected"] = true }
        return checks
    }

    private static func wait(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else { throw AskBaseError.invalidInput("Offline media UI check timed out.") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func makeImage(at url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2, nil) else {
            throw AskBaseError.storage("Cannot create synthetic image.")
        }
        for index in 0..<2 {
            guard let context = CGContext(data: nil, width: 32, height: 20, bitsPerComponent: 8,
                                          bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw AskBaseError.storage("Cannot allocate synthetic image.")
            }
            context.setFillColor(red: index == 0 ? 1 : 0, green: 0, blue: index == 1 ? 1 : 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 20))
            guard let image = context.makeImage() else { throw AskBaseError.storage("Cannot encode synthetic image.") }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyOrientation: index == 0 ? 1 : 6,
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw AskBaseError.storage("Cannot save synthetic image.") }
    }

    private static func isBlue(_ image: CGImage) -> Bool {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        return bytes[2] > 200 && bytes[0] < 50
    }

    private static func makeAudio(at url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount: UInt32 = 8_000 * 2 * 2
        data.append(contentsOf: "RIFF".utf8); append(UInt32(36) + byteCount)
        data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000)); append(UInt32(16_000))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8); append(byteCount)
        data.append(Data(count: Int(byteCount)))
        try data.write(to: url)
    }
}

private actor DeferredUIEmbedder: EmbeddingProviding {
    static let signature = "offline-media-ui-verifier"
    static var vector: [Float] { [1] + Array(repeating: 0, count: 767) }
    private var shouldDeferHealth = false
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<EmbeddingHealth, Error>] = [:]
    private(set) var textQueries: [String] = []
    private(set) var mediaCalls = 0
    var waitingIDs: [Int] { waiting.keys.sorted() }

    func deferHealth() { shouldDeferHealth = true }
    func health() async throws -> EmbeddingHealth {
        if shouldDeferHealth {
            nextID += 1
            let id = nextID
            return try await withCheckedThrowingContinuation { waiting[id] = $0 }
        }
        return EmbeddingHealth(encoderSignature: Self.signature, modalities: ["text", "image", "audio", "video"],
                               mediaEncoderSignature: "offline-media")
    }
    func fail(id: Int, message: String) {
        waiting.removeValue(forKey: id)?.resume(throwing: AskBaseError.modelUnavailable(message))
    }
    func embed(_ texts: [String], inputType: String) async throws -> EmbeddingBatch {
        textQueries += texts
        return EmbeddingBatch(vectors: texts.map { _ in Self.vector }, signature: Self.signature)
    }
    func embedMedia(_ input: MediaEmbeddingInput, inputType: String) async throws -> EmbeddingBatch {
        mediaCalls += 1
        throw AskBaseError.modelUnavailable("Synthetic state checks must stop before media extraction.")
    }
}

private struct OfflineUIChat: ChatProviding {
    func models() async throws -> [String] { [] }
    func answer(model: String, question: String, sources: [SearchResult], history: [ChatMessage]) async throws -> String {
        throw AskBaseError.invalidInput("Offline UI checks never request answers.")
    }
}
#endif
