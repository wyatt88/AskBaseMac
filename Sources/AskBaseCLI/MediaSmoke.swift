import AskBaseCore
import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Real model integration checks, always against generated media in an isolated
/// temporary library. This is not a quality benchmark for private user media.
enum MediaSmoke {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskBase-Media-Smoke-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        var checks: [String: Bool] = [:]
        var observations: [String: Any] = [:]
        let red = try image(root.appendingPathComponent("red-circle"), words: nil)
        let poster = try image(root.appendingPathComponent("schedule.png"),
                               words: "ASKBASE PROJECT\nDeadline: October 18\nBudget: 30000 dollars")
        let sound = try audio(root.appendingPathComponent("tone.wav"), duration: 20.25)
        let movie = try await video(root.appendingPathComponent("silent.mov"), duration: 10.25)
        let combined = try await combine(movie: movie, audio: sound, output: root.appendingPathComponent("with-audio.mov"))
        let text = root.appendingPathComponent("reference.txt")
        try "Synthetic reference: AskBase project deadline is October 18. The budget is 30000 dollars."
            .write(to: text, atomically: true, encoding: .utf8)
        let engine = try KnowledgeEngine(root: root.appendingPathComponent("library"))
        let base = try await engine.snapshot().knowledgeBases[0]
        let status = await engine.modelStatus()
        checks["four_modalities_ready"] = Set(status.embeddingModalities) == Set(["text", "image", "audio", "video"])
        let report = try await engine.importDocuments(urls: [red, poster, sound, movie, combined, text], knowledgeBaseID: base.id)
        observations["import_failures"] = report.failures
        checks["six_documents_ready"] = report.imported.count == 6 && report.failures.isEmpty
        let snapshot = try await engine.snapshot()
        checks["all_documents_committed_ready"] = snapshot.documents.count == 6 && snapshot.documents.allSatisfy { $0.status == .ready }
        var allChunks: [DocumentChunk] = []
        for document in snapshot.documents {
            allChunks += try await engine.documentChunks(documentID: document.id)
        }
        checks["finite_normalized_768d_vectors"] = !allChunks.isEmpty && allChunks.allSatisfy {
            validEmbedding($0.embedding) && $0.dimensions == 768 && !$0.encoderSignature.isEmpty
        }
        checks["shared_text_space"] = Set(allChunks.map(\.encoderSignature)).count == 1
        checks["media_signature_and_recipe"] = allChunks.filter { $0.media != nil }.allSatisfy {
            !($0.media?.encoderSignature ?? "").isEmpty && $0.media?.recipe == MediaProcessor.recipe
        }
        let byName = Dictionary(uniqueKeysWithValues: snapshot.documents.map { ($0.fileName, $0) })
        if let audioDoc = byName["tone.wav"] {
            let chunks = try await engine.documentChunks(documentID: audioDoc.id)
            checks["audio_three_segments_with_tail"] = chunks.count == 3
                && chunks.compactMap { $0.media?.startSeconds } == [0, 10, 20]
                && abs((chunks.last?.media?.endSeconds ?? 0) - 20.25) < 0.001
            checks["audio_not_presented_as_transcript"] = chunks.allSatisfy { $0.media?.textSource == nil }
            observations["audio_ranges"] = chunks.map { [$0.media?.startSeconds ?? -1, $0.media?.endSeconds ?? -1] }
        } else { checks["audio_three_segments_with_tail"] = false }
        for (name, hasAudio) in [("silent.mov", false), ("with-audio.mov", true)] {
            if let document = byName[name] {
                let chunks = try await engine.documentChunks(documentID: document.id)
                checks["\(name)_two_segments_with_tail"] = chunks.count == 2
                    && chunks.first?.media?.startSeconds == 0
                    && chunks.last?.media?.startSeconds == 10
                    && abs((chunks.last?.media?.endSeconds ?? 0) - 10.25) < 0.001
                checks["\(name)_audio_presence"] = chunks.allSatisfy { $0.media?.audioIncluded == hasAudio }
                checks["\(name)_frame_provenance"] = chunks.allSatisfy {
                    $0.media?.isValid == true && !($0.media?.frameTimes ?? []).isEmpty
                }
                observations["\(name)_frames"] = chunks.compactMap { $0.media?.frameTimes }
            } else { checks["\(name)_two_segments_with_tail"] = false }
        }
        if let posterDoc = byName["schedule.png"] {
            let chunks = try await engine.documentChunks(documentID: posterDoc.id)
            checks["real_ocr_text_labeled"] = chunks.contains {
                $0.media?.textSource == .ocr && $0.text.contains("October") && $0.text.contains("30000")
            }
            observations["poster_ocr"] = chunks.map(\.text)
        } else { checks["real_ocr_text_labeled"] = false }

        let textResults = try await engine.search(query: "red circle on a white background", knowledgeBaseID: base.id)
        checks["text_query_returns_media"] = textResults.contains { $0.media != nil }
        observations["text_query_results"] = textResults.map { ["source": $0.sourceLabel, "score": $0.score] }
        let imageResults = try await engine.search(mediaURL: red, knowledgeBaseID: base.id)
        checks["image_query_self_match_first"] = imageResults.first?.documentID == byName["red-circle"]?.id
        let audioResults = try await engine.search(mediaURL: sound, knowledgeBaseID: base.id)
        checks["audio_query_returns_audio_source"] = audioResults.contains { $0.documentID == byName["tone.wav"]?.id }
        let videoResults = try await engine.search(mediaURL: movie, knowledgeBaseID: base.id)
        checks["video_query_returns_video_source"] = videoResults.contains { $0.documentID == byName["silent.mov"]?.id }
        observations["media_query_results"] = [
            "image": imageResults.map(\.sourceLabel), "audio": audioResults.map(\.sourceLabel), "video": videoResults.map(\.sourceLabel),
        ]
        checks["queries_do_not_import_files"] = try await engine.snapshot().documents.count == 6
        let isolated = try await engine.createKnowledgeBase(name: "Empty isolated base")
        checks["knowledge_base_isolation"] = try await engine.search(query: "circle", knowledgeBaseID: isolated.id).isEmpty
        let duplicate = try await engine.importDocuments(urls: [sound], knowledgeBaseID: base.id)
        checks["media_duplicate_skipped"] = duplicate.skipped.count == 1 && duplicate.imported.isEmpty
        if let document = byName["with-audio.mov"] {
            let before = try await engine.documentChunks(documentID: document.id)
            try await engine.reindex(documentID: document.id)
            let after = try await engine.documentChunks(documentID: document.id)
            checks["media_reindex_complete"] = after.count == before.count
                && after.map(\.media) == before.map(\.media)
                && after.allSatisfy { validEmbedding($0.embedding) }
            let copy = try await engine.originalURL(documentID: document.id)
            try await engine.deleteDocument(id: document.id)
            let remaining = try await engine.search(query: "movie", knowledgeBaseID: base.id)
            checks["deleted_media_not_retrieved"] = !remaining.contains { $0.documentID == document.id }
            checks["managed_copy_removed_original_retained"] = !FileManager.default.fileExists(atPath: copy.path)
                && FileManager.default.fileExists(atPath: combined.path)
        }
        let reopened = try KnowledgeEngine(root: root.appendingPathComponent("library"))
        checks["media_positions_persist_after_reopen"] = try await reopened.snapshot().documents.filter { $0.media != nil }.count == 4
        try await engine.deleteKnowledgeBase(id: base.id)
        checks["media_base_delete_cascades"] = try await engine.snapshot().documents.isEmpty
        try AskBaseCLI.printJSON([
            "protocol": "MM03-P1", "checks": checks,
            "passed": checks.values.filter { $0 }.count, "total": checks.count,
            "seconds": Date().timeIntervalSince(started), "observations": observations,
            "test_data": "Generated shapes, poster, tones and color video; isolated temporary library removed on exit.",
            "limits": "Engineering and synthetic self-retrieval only; no speech transcription or natural-media quality benchmark.",
        ])
        if checks.values.contains(false) { throw AskBaseError.storage("多模态集成验收有未通过项目。") }
    }

    private static func missing(_ what: String) -> AskBaseError { .storage("无法构造合成验收媒体：\(what)") }

    private static func image(_ url: URL, words: String?) throws -> URL {
        guard let context = CGContext(data: nil, width: 960, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw missing("image context") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
        if let words {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 48, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            for (index, line) in words.components(separatedBy: "\n").enumerated() {
                let text = NSAttributedString(string: line, attributes: attributes)
                context.textPosition = CGPoint(x: 60, y: 490 - index * 110)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
        } else {
            context.setFillColor(CGColor(red: 0.9, green: 0.03, blue: 0.02, alpha: 1))
            context.fillEllipse(in: CGRect(x: 300, y: 140, width: 360, height: 360))
        }
        guard let cg = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw missing("PNG destination")
        }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { throw missing("PNG encode") }
        return url
    }

    private static func audio(_ url: URL, duration: Double) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let channels = buffer.floatChannelData else { throw missing("PCM buffer") }
        let frames = Int(duration * 48_000)
        var offset = 0
        while offset < frames {
            try Task.checkCancellation()
            let count = min(4096, frames - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let value = Float(0.25 * sin(Double(offset + index) * 440 * 2 * .pi / 48_000))
                channels[0][index] = value; channels[1][index] = value
            }
            try file.write(from: buffer); offset += count
        }
        return url
    }

    private static func video(_ url: URL, duration: Double) async throws -> URL {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        guard writer.canAdd(input) else { throw missing("video writer input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? missing("video writer") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(duration * 4) {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? missing("video encoder timeout") }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else { throw missing("video pool") }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
                throw missing("video frame")
            }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let address = CVPixelBufferGetBaseAddress(pixel) {
                let rowBytes = CVPixelBufferGetBytesPerRow(pixel), bytes = address.assumingMemoryBound(to: UInt8.self)
                for row in 0..<240 {
                    for column in 0..<320 {
                        let index = row * rowBytes + column * 4
                        bytes[index] = frame >= 40 ? 255 : 0
                        bytes[index + 1] = 0; bytes[index + 2] = frame >= 40 ? 0 : 255; bytes[index + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 4)) else {
                throw writer.error ?? missing("video frame append")
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 48_000))
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? missing("video finish") }
        return url
    }

    private static func combine(movie: URL, audio: URL, output: URL) async throws -> URL {
        let movieAsset = AVURLAsset(url: movie), audioAsset = AVURLAsset(url: audio)
        let pictureTracks = try await movieAsset.loadTracks(withMediaType: .video)
        let soundTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let duration = try await movieAsset.load(.duration)
        let composition = AVMutableComposition()
        guard let pictureSource = pictureTracks.first, let soundSource = soundTracks.first,
              let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw missing("composition tracks")
        }
        let range = CMTimeRange(start: .zero, duration: duration)
        try picture.insertTimeRange(range, of: pictureSource, at: .zero)
        try sound.insertTimeRange(range, of: soundSource, at: .zero)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw missing("composition export")
        }
        export.outputURL = output; export.outputFileType = .mov
        await withCheckedContinuation { continuation in export.exportAsynchronously { continuation.resume() } }
        guard export.status == .completed else { throw export.error ?? missing("composition export failed") }
        return output
    }
}
