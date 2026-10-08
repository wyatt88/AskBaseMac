import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Offline media preparation. Callers retain a stable original and persist the
/// returned references; only encoded, bounded segment bytes go to the encoder.
public enum MediaProcessor {
    /// EXIF-oriented sRGB JPEG <=1024 px, uniform absolute video sampling,
    /// local CPU OCR, and PCM16/16kHz/mono intervals of 20 ms through 10 s.
    public static let recipe = "eg2-media-v1"
    private static let segmentSeconds = 10.0
    private static let imageDimension = 1024
    private static let sampleRate: Int32 = 16_000
    private static let minimumAudioDuration = CMTime(value: 320, timescale: 16_000)

    /// A document-level reference and every page/frame or ten-second interval.
    /// Container recognition uses bytes and native parsers, never an extension
    /// alone. Payload decoding errors also remain explicit in `segment`.
    public static func inspect(url: URL) async throws -> MediaPlan? {
        try Task.checkCancellation()
        let file = try StagedFile(url)
        defer { file.remove() }
        if let source = imageSource(file.url) {
            let count = try imageCount(source)
            var references: [MediaReference] = []
            for index in 0..<count {
                try Task.checkCancellation()
                // Validate each page independently without retaining full-sized
                // images or silently accepting a corrupt later page.
                try autoreleasepool { _ = try thumbnail(source, index: index) }
                references.append(MediaReference(kind: .image, imageIndex: index, recipe: recipe))
            }
            try Task.checkCancellation()
            return MediaPlan(reference: MediaReference(kind: .image, recipe: recipe),
                             segments: references)
        }
        if file.hint?.isImage == true {
            throw failure("图片已识别，但内容损坏或 ImageIO 无法解码。")
        }

        let asset = makeAsset(file.url)
        defer { asset.cancelLoading() }
        return try await withTaskCancellationHandler {
            do {
                guard let info = try await assetInfo(asset, recognized: file.hint != nil) else {
                    try Task.checkCancellation()
                    return nil
                }
                var segments: [MediaReference] = []
                var start = CMTime.zero
                let step = CMTime(seconds: segmentSeconds, preferredTimescale: 1)
                if info.kind == .audio, info.duration < minimumAudioDuration {
                    throw failure("音频不足 20 毫秒（320 个 16 kHz 采样），无法满足编码器的最短输入。")
                }
                while start < info.duration {
                    try Task.checkCancellation()
                    var end = CMTimeMinimum(CMTimeAdd(start, step), info.duration)
                    let remaining = CMTimeSubtract(info.duration, end)
                    if remaining > .zero, remaining < minimumAudioDuration {
                        // Move this boundary back instead of dropping/padding a
                        // tiny tail or exceeding the ten-second model budget.
                        end = CMTimeSubtract(info.duration, minimumAudioDuration)
                    }
                    guard end > start else { throw failure("媒体时间轴无法继续分段。") }
                    let range = CMTimeRange(start: start, end: end)
                    segments.append(MediaReference(
                        kind: info.kind, startSeconds: start.seconds, endSeconds: end.seconds,
                        frameTimes: info.kind == .video ? frameTimes(in: range) : nil,
                        audioIncluded: info.kind == .audio || info.hasAudio(in: range),
                        recipe: recipe
                    ))
                    start = end
                }
                return MediaPlan(
                    reference: MediaReference(
                        kind: info.kind, startSeconds: 0, endSeconds: info.duration.seconds,
                        audioIncluded: !info.audio.isEmpty, recipe: recipe
                    ),
                    segments: segments
                )
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            asset.cancelLoading()
        }
    }

    /// Prepare just one recorded position. Audio buffers are bounded by the
    /// model's ten-second input, independently of source file size or duration.
    public static func segment(url: URL, reference: MediaReference) async throws -> PreparedMediaSegment {
        try Task.checkCancellation()
        guard reference.isValid, reference.recipe == nil || reference.recipe == recipe else {
            throw failure("媒体引用无效，或预处理配方不兼容；请重新建立媒体分段。")
        }
        if reference.kind != .image {
            guard let start = reference.startSeconds, let end = reference.endSeconds,
                  end - start <= segmentSeconds else {
                throw failure("单次模型输入的音视频片段必须不超过 10 秒。")
            }
            if let times = reference.frameTimes, times.count > 8 {
                throw failure("单次模型输入的视频片段必须包含 1–8 个采样位置。")
            }
        }
        let file = try StagedFile(url)
        defer { file.remove() }
        var preparedReference = reference
        preparedReference.recipe = recipe
        // Recompute OCR provenance instead of trusting a previous text label.
        preparedReference.textSource = nil
        if reference.kind == .image {
            guard let source = imageSource(file.url) else { throw failure("无法解码引用的图片。") }
            let count = try imageCount(source)
            guard reference.imageIndex != nil || count == 1 else {
                throw failure("多页或多帧图片必须提供 imageIndex，不能只索引第一页。")
            }
            let index = reference.imageIndex ?? 0
            guard index < count else { throw failure("图片引用的帧／页不存在。") }
            let image = try thumbnail(source, index: index)
            let bytes = try autoreleasepool { try jpeg(image) }
            let text = try await recognizeText(image)
            try Task.checkCancellation()
            preparedReference.imageIndex = index
            preparedReference.audioIncluded = false
            preparedReference.textSource = text == nil ? nil : .ocr
            return PreparedMediaSegment(reference: preparedReference,
                                        input: MediaEmbeddingInput(kind: .image, images: [bytes]), text: text)
        }

        let asset = makeAsset(file.url)
        defer { asset.cancelLoading() }
        return try await withTaskCancellationHandler {
            do {
                guard let info = try await assetInfo(asset, recognized: true),
                      info.kind == reference.kind,
                      let start = reference.startSeconds, let end = reference.endSeconds,
                      end <= info.duration.seconds else {
                    throw failure("媒体种类或引用时间范围与原文件不符。")
                }
                let range = CMTimeRange(start: time(start), end: time(end))
                if reference.kind == .audio {
                    let bytes = try await audioWAV(asset: asset, info: info, range: range)
                    try Task.checkCancellation()
                    preparedReference.audioIncluded = true
                    return PreparedMediaSegment(
                        reference: preparedReference,
                        input: MediaEmbeddingInput(kind: .audio, audio: bytes)
                    )
                }

                let times = reference.frameTimes ?? frameTimes(in: range)
                let frames = try await videoFrames(asset, times: times)
                let hasAudio = info.hasAudio(in: range)
                // A present but undecodable audio track must throw. It cannot
                // silently turn a failed audiovisual segment into silent video.
                let audio = hasAudio ? try await audioWAV(asset: asset, info: info, range: range) : nil
                try Task.checkCancellation()
                preparedReference.frameTimes = times
                preparedReference.audioIncluded = hasAudio
                preparedReference.textSource = frames.text == nil ? nil : .ocr
                return PreparedMediaSegment(
                    reference: preparedReference,
                    input: MediaEmbeddingInput(kind: .video, images: frames.images,
                                               audio: audio, timestamps: times), text: frames.text
                )
            } catch {
                try Task.checkCancellation()
                if error is AskBaseError { throw error }
                throw failure("媒体片段解码失败：\(error.localizedDescription)")
            }
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private static func failure(_ message: String) -> AskBaseError { .importFailed(message) }
    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }

    private static func imageSource(_ url: URL) -> CGImageSource? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ), let identifier = CGImageSourceGetType(source),
              UTType(identifier as String)?.conforms(to: .image) == true else { return nil }
        return source
    }

    private static func imageCount(_ source: CGImageSource) throws -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 0, CGImageSourceGetStatus(source) == .statusComplete else {
            throw failure("图片已识别，但文件不完整或没有可解码的帧／页。")
        }
        return count
    }

    private static func thumbnail(_ source: CGImageSource, index: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: imageDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary), CGImageSourceGetStatusAtIndex(source, index) == .statusComplete else {
            throw failure("图片第 \(index + 1) 帧／页损坏，无法解码。")
        }
        try Task.checkCancellation()
        return image
    }

    private static func jpeg(_ image: CGImage, canvas: CGSize? = nil) throws -> Data {
        try Task.checkCancellation()
        // Normalize alpha and color space before encoding, also covering video
        // frames and images that do not carry a usable embedded color profile.
        let scale = min(1, Double(imageDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(canvas?.width ?? (Double(image.width) * scale).rounded(.down)))
        let height = max(1, Int(canvas?.height ?? (Double(image.height) * scale).rounded(.down)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { throw failure("无法建立图片预处理缓冲区。") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let fit = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawnWidth = Double(image.width) * fit, drawnHeight = Double(image.height) * fit
        context.draw(image, in: CGRect(x: (Double(width) - drawnWidth) / 2,
                                      y: (Double(height) - drawnHeight) / 2,
                                      width: drawnWidth, height: drawnHeight))
        guard let normalized = context.makeImage() else { throw failure("无法生成标准图片。") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw failure("无法建立 JPEG 编码器。") }
        CGImageDestinationAddImage(destination, normalized, [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImagePropertyOrientation: 1,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw failure("JPEG 编码失败。") }
        try Task.checkCancellation()
        return data as Data
    }

    /// Vision operates only on the bounded, already-oriented thumbnail. Every
    /// advertised compute stage must offer a CPU; never fall back to a GPU or
    /// download a model. Unsupported OCR leaves the native media input useful.
    private static func recognizeText(_ image: CGImage) async throws -> String? {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.015
        return try await withTaskCancellationHandler {
            do {
                let devices = try request.supportedComputeStageDevices
                guard !devices.isEmpty else { return nil }
                for (stage, choices) in devices {
                    guard let cpu = choices.first(where: {
                        if case .cpu = $0 { return true }
                        return false
                    }) else { return nil }
                    request.setComputeDevice(cpu, for: stage)
                }
                let languages = try request.supportedRecognitionLanguages()
                request.recognitionLanguages = ["zh-Hans", "en-US"].filter(languages.contains)
                try Task.checkCancellation()
                try autoreleasepool {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                }
                try Task.checkCancellation()
                let lines = (request.results ?? []).compactMap { observation -> String? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                }
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
            } catch {
                try Task.checkCancellation()
                return nil
            }
        } onCancel: {
            request.cancel()
        }
    }

    private struct AudioTrack {
        let track: AVAssetTrack
        let range: CMTimeRange
    }

    private struct AssetInfo {
        let kind: MediaKind
        let duration: CMTime
        let audio: [AudioTrack]

        func hasAudio(in range: CMTimeRange) -> Bool {
            audio.contains { CMTimeRangeGetIntersection($0.range, otherRange: range).duration > .zero }
        }
    }

    private static func makeAsset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            // Block QuickTime reference movies, playlists, aliases and any
            // other media reference outside this one container, including LAN.
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
    }

    private static func assetInfo(_ asset: AVURLAsset, recognized: Bool) async throws -> AssetInfo? {
        var recognizedTracks = false
        do {
            try Task.checkCancellation()
            let tracks = try await asset.load(.tracks)
            let videos = tracks.filter { $0.mediaType == .video }
            let audios = tracks.filter { $0.mediaType == .audio }
            guard !videos.isEmpty || !audios.isEmpty else {
                if recognized { throw failure("媒体容器已识别，但没有可读取的音视频轨道。") }
                return nil
            }
            recognizedTracks = true
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds.isFinite, duration > .zero,
                  try await asset.load(.isReadable) else {
                throw failure("音视频时长无效、文件损坏或编码不受 AVFoundation 支持。")
            }
            var audio: [AudioTrack] = []
            for track in audios {
                try Task.checkCancellation()
                let range = try await track.load(.timeRange)
                guard range.isValid, range.start.isNumeric, range.duration.isNumeric else {
                    throw failure("音轨时间轴无效。")
                }
                audio.append(AudioTrack(track: track, range: range))
            }
            return AssetInfo(kind: videos.isEmpty ? .audio : .video, duration: duration, audio: audio)
        } catch {
            try Task.checkCancellation()
            if error is AskBaseError { throw error }
            if recognized || recognizedTracks {
                throw failure("媒体已识别，但文件损坏、引用外部资源或编码不受支持：\(error.localizedDescription)")
            }
            return nil
        }
    }

    private static func frameTimes(in range: CMTimeRange) -> [Double] {
        let start = range.start.seconds
        let duration = range.duration.seconds
        let count = max(1, min(8, Int(ceil(duration))))
        // Absolute source playback positions at bin centers avoid requesting
        // EOF, even for a tail shorter than one frame. Held frames are allowed:
        // these are sampling positions, not packet presentation timestamps.
        return (0..<count).map { start + duration * (Double($0) + 0.5) / Double(count) }
    }

    private static func videoFrames(
        _ asset: AVURLAsset, times: [Double]
    ) async throws -> (images: [Data], text: String?) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: imageDimension, height: imageDimension)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }
        return try await withTaskCancellationHandler {
            var images: [Data] = []
            var canvas: CGSize?
            var text: [String] = []
            var seenText = Set<String>()
            for seconds in times {
                try Task.checkCancellation()
                let result = try await generator.image(at: time(seconds))
                if canvas == nil {
                    let scale = min(1, Double(imageDimension) / Double(max(result.image.width, result.image.height)))
                    canvas = CGSize(width: max(1, (Double(result.image.width) * scale).rounded(.down)),
                                    height: max(1, (Double(result.image.height) * scale).rounded(.down)))
                }
                let bytes = try autoreleasepool { try jpeg(result.image, canvas: canvas) }
                images.append(bytes)
                if let recognized = try await recognizeText(result.image), seenText.insert(recognized).inserted {
                    text.append(recognized)
                }
            }
            try Task.checkCancellation()
            return (images, text.isEmpty ? nil : text.joined(separator: "\n"))
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    private static func audioWAV(asset: AVURLAsset, info: AssetInfo, range: CMTimeRange) async throws -> Data {
        try Task.checkCancellation()
        let first = CMTimeConvertScale(range.start, timescale: sampleRate, method: .roundTowardPositiveInfinity).value
        let last = CMTimeConvertScale(range.end, timescale: sampleRate, method: .roundTowardPositiveInfinity).value
        let frames = last - first
        guard frames >= 320, frames <= Int64(sampleRate) * Int64(segmentSeconds) else {
            throw failure("音频模型输入必须包含 320–160000 个 16 kHz 采样（20 毫秒至 10 秒）。")
        }
        var pcm = Data(count: Int(frames) * 2)
        let activeTracks = info.audio.filter { CMTimeRangeGetIntersection($0.range, otherRange: range).duration > .zero }
        // A real gap in an audio-only timeline is silence, not a missing tail.
        if activeTracks.isEmpty { return wav(pcm) }
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderAudioMixOutput(audioTracks: activeTracks.map(\.track), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw failure("无法创建 16 kHz 单声道 PCM 音轨解码器。") }
        reader.add(output)
        reader.timeRange = range
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard reader.startReading() else {
                try Task.checkCancellation()
                throw failure("音轨解码无法开始：\(reader.error?.localizedDescription ?? "未知错误")")
            }
            var copiedFrames = 0
            while true {
                try Task.checkCancellation()
                let hasSample = try autoreleasepool { () throws -> Bool in
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    let count = CMSampleBufferGetNumSamples(sample)
                    if count == 0 { return true }
                    guard let description = CMSampleBufferGetFormatDescription(sample),
                          let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                          format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == Double(sampleRate),
                          format.mChannelsPerFrame == 1, format.mBitsPerChannel == 16,
                          format.mFormatFlags & kAudioFormatFlagIsFloat == 0,
                          format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                          let block = CMSampleBufferGetDataBuffer(sample) else {
                        throw failure("音轨解码器返回了非预期的 PCM 格式。")
                    }
                    let position = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard position.isNumeric else { throw failure("解码后的音频缺少有效时间戳。") }
                    let offset = CMTimeConvertScale(CMTimeSubtract(position, range.start),
                                                    timescale: sampleRate, method: .roundHalfAwayFromZero).value
                    // Clamp preroll and the final decoder block to this segment.
                    // Copy only this intersection, never the complete source.
                    let sourceStart = max(Int64(0), -offset)
                    let destinationStart = max(Int64(0), offset)
                    let length = min(Int64(count) - sourceStart, frames - destinationStart)
                    if length <= 0 { return true }
                    guard sourceStart <= Int64(Int.max / 2), length <= Int64(Int.max / 2),
                          sourceStart + length <= Int64(CMBlockBufferGetDataLength(block) / 2) else {
                        throw failure("音轨 PCM 缓冲区不完整。")
                    }
                    let status = pcm.withUnsafeMutableBytes { buffer in
                        CMBlockBufferCopyDataBytes(
                            block, atOffset: Int(sourceStart) * 2, dataLength: Int(length) * 2,
                            destination: buffer.baseAddress!.advanced(by: Int(destinationStart) * 2)
                        )
                    }
                    guard status == kCMBlockBufferNoErr else { throw failure("读取音轨 PCM 数据失败。") }
                    copiedFrames += Int(length)
                    return true
                }
                if !hasSample { break }
            }
            try Task.checkCancellation()
            guard reader.status == .completed else {
                throw failure("音轨解码失败：\(reader.error?.localizedDescription ?? "解码器未正常结束")")
            }
            guard copiedFrames > 0 else {
                throw failure("时间范围内存在音轨，但未能解码任何音频；没有将其视为无声视频。")
            }
            return wav(pcm)
        } onCancel: {
            reader.cancelReading()
        }
    }

    private static func wav(_ pcm: Data) -> Data {
        // Canonical little-endian PCM16 RIFF/WAVE; the bounded segment cannot
        // approach RIFF's 32-bit byte-size field limit.
        var result = Data()
        func append(_ value: UInt32, bytes: Int) {
            for index in 0..<bytes { result.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
        }
        result.append(contentsOf: "RIFF".utf8); append(UInt32(pcm.count) + 36, bytes: 4)
        result.append(contentsOf: "WAVEfmt ".utf8); append(16, bytes: 4)
        append(1, bytes: 2); append(1, bytes: 2)
        append(UInt32(sampleRate), bytes: 4); append(UInt32(sampleRate) * 2, bytes: 4)
        append(2, bytes: 2); append(16, bytes: 2)
        result.append(contentsOf: "data".utf8); append(UInt32(pcm.count), bytes: 4)
        result.append(pcm)
        return result
    }

    /// Hints recognize common damaged headers and assist native format sniffing
    /// for extensionless inputs. This is not a format allowlist: ImageIO and
    /// AVFoundation still probe files with no recognized signature.
    private struct ContentHint {
        let fileExtension: String
        let isImage: Bool

        static func read(_ data: Data) -> ContentHint? {
            let bytes = [UInt8](data)
            func matches(_ signature: [UInt8], at offset: Int = 0) -> Bool {
                offset >= 0 && offset + signature.count <= bytes.count &&
                bytes[offset..<(offset + signature.count)].elementsEqual(signature)
            }
            func text(_ value: String, at offset: Int = 0) -> Bool { matches(Array(value.utf8), at: offset) }
            func image(_ ext: String) -> ContentHint { ContentHint(fileExtension: ext, isImage: true) }
            func av(_ ext: String) -> ContentHint { ContentHint(fileExtension: ext, isImage: false) }
            if matches([0xFF, 0xD8, 0xFF]) { return image("jpg") }
            if matches([137, 80, 78, 71, 13, 10, 26, 10]) { return image("png") }
            if text("GIF87a") || text("GIF89a") { return image("gif") }
            if matches([0x49, 0x49, 42, 0]) || matches([0x4D, 0x4D, 0, 42]) ||
                matches([0x49, 0x49, 43, 0]) || matches([0x4D, 0x4D, 0, 43]) { return image("tiff") }
            if matches([0, 0, 1, 0]) || matches([0, 0, 2, 0]) { return image("ico") }
            if text("icns") { return image("icns") }
            if text("8BPS") { return image("psd") }
            if matches([0x76, 0x2F, 0x31, 1]) { return image("exr") }
            if matches([0, 0, 0, 12, 0x6A, 0x50, 32, 32, 13, 10, 135, 10]) ||
                matches([0xFF, 0x4F, 0xFF, 0x51]) { return image("jp2") }
            if text("BM"), bytes.count >= 14, matches([0, 0, 0, 0], at: 6) { return image("bmp") }
            if text("RIFF") || text("RIFX") || text("RF64") {
                if text("WEBP", at: 8) { return image("webp") }
                if text("WAVE", at: 8) { return av("wav") }
                if text("AVI ", at: 8) { return av("avi") }
            }
            if text("FORM"), text("AIFF", at: 8) || text("AIFC", at: 8) { return av("aiff") }
            if text("caff") { return av("caf") }
            if text("fLaC") { return av("flac") }
            if text(".snd") { return av("au") }
            if text("OggS") { return av("ogg") }
            if text("#!AMR") { return av("amr") }
            if text("ID3") { return av("mp3") }
            // UTF-16/32 LE BOMs share the MPEG sync prefix. They are ordinary
            // documents, not evidence of a damaged audio container.
            if matches([0xFF, 0xFE]) { return nil }
            if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
                return av(bytes[1] & 0xF6 == 0xF0 ? "aac" : "mp3")
            }
            if matches([0x1A, 0x45, 0xDF, 0xA3]) { return av("mkv") }
            if text("FLV") { return av("flv") }
            if matches([0, 0, 1, 0xBA]) || matches([0, 0, 1, 0xB3]) { return av("mpg") }
            // ISO BMFF/QuickTime may put free/wide boxes before ftyp or moov.
            var offset = 0
            while offset + 8 <= bytes.count {
                let length = bytes[offset..<(offset + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                if text("ftyp", at: offset + 4) {
                    let brand = String(decoding: bytes.dropFirst(offset + 8).prefix(4), as: UTF8.self)
                    if ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif", "avis"].contains(brand) {
                        return image(brand == "avif" || brand == "avis" ? "avif" : "heic")
                    }
                    return av(brand == "qt  " ? "mov" : (brand == "M4A " ? "m4a" : "mp4"))
                }
                if text("moov", at: offset + 4) || text("mdat", at: offset + 4) { return av("mov") }
                guard length >= 8, length <= UInt64(bytes.count - offset),
                      text("free", at: offset + 4) || text("wide", at: offset + 4) ||
                        text("skip", at: offset + 4) else { break }
                offset += Int(length)
            }
            return nil
        }
    }

    /// A descriptor-anchored private snapshot prevents a final-component
    /// symlink from being followed by a framework that reopens paths. APFS
    /// cloning avoids re-copying a large managed original for every segment.
    /// Immutable caller snapshots can also be hard-linked after inode checking;
    /// only a filesystem supporting neither path needs a streaming disk copy.
    private struct StagedFile {
        let directory: URL
        let url: URL
        let hint: ContentHint?

        init(_ source: URL) throws {
            try Task.checkCancellation()
            guard source.isFileURL, source.host == nil || source.host == "" || source.host == "localhost",
                  !source.path.utf8.contains(0) else { throw failure("媒体输入必须是本机普通文件。") }
            let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw failure("无法打开媒体文件；请检查权限，且不要选择符号链接。") }
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? input.close() }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
                throw failure("媒体输入必须是普通文件，不支持目录、设备或管道。")
            }
            hint = ContentHint.read(try input.read(upToCount: 65_536) ?? Data())
            let originalExtension = source.pathExtension
            let safeHint = originalExtension.utf8.count <= 24 && originalExtension.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            } ? originalExtension : ""
            let ext = hint?.fileExtension ?? safeHint
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AskBase-Media-\(getpid())-\(UUID().uuidString)", isDirectory: true)
            url = directory.appendingPathComponent(ext.isEmpty ? "source" : "source.\(ext)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            var complete = false
            defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
            if fclonefileat(fd, AT_FDCWD, url.path, 0) != 0 {
                // The destination belongs to this newly created private folder.
                _ = unlink(url.path)
                if link(source.path, url.path) == 0 {
                    let linkedFD = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard linkedFD >= 0 else { throw failure("媒体输入在暂存期间被替换，不能读取符号链接。") }
                    defer { Darwin.close(linkedFD) }
                    var linked = stat()
                    guard fstat(linkedFD, &linked) == 0, linked.st_mode & S_IFMT == S_IFREG,
                          linked.st_dev == before.st_dev, linked.st_ino == before.st_ino else {
                        throw failure("媒体输入在暂存期间被替换，请使用稳定副本重试。")
                    }
                    // link() itself legitimately updates the inode's ctime.
                    before.st_ctimespec = linked.st_ctimespec
                } else {
                    let outputFD = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    guard outputFD >= 0 else { throw failure("无法创建媒体暂存文件。") }
                    let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
                    defer { try? output.close() }
                    try input.seek(toOffset: 0)
                    while let part = try input.read(upToCount: 1_048_576), !part.isEmpty {
                        try Task.checkCancellation()
                        try output.write(contentsOf: part)
                    }
                }
            }
            var after = stat()
            guard fstat(fd, &after) == 0, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw failure("预处理期间媒体文件发生变化，请使用稳定副本重试。")
            }
            try Task.checkCancellation()
            complete = true
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
