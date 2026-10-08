import AVFoundation
import CoreGraphics
import CoreText
import CoreVideo
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import XCTest
@testable import AskBaseCore

final class MediaProcessorTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AskBaseMediaTests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }

    func testImageIsContentDetectedOrientedAndBoundedJPEGWithoutInventedText() async throws {
        let source = try imageFile("snapshot", type: .jpeg, width: 1600, height: 800, orientation: 6)
        let plan = try await inspected(source)
        XCTAssertEqual(plan.reference.kind, .image)
        XCTAssertTrue(plan.reference.isValid)
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertEqual(plan.segments[0].imageIndex, 0)
        let result = try await MediaProcessor.segment(url: source, reference: plan.segments[0])
        let image = try decodedJPEG(XCTUnwrap(result.input.images?.first))
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 1024)
        XCTAssertEqual(result.reference.recipe, "eg2-media-v1")
        XCTAssertNil(result.text)
        XCTAssertNil(result.reference.textSource)
        XCTAssertNil(result.input.audio)
        XCTAssertNil(result.input.timestamps)
        XCTAssertTrue(result.reference.isValid)
        let misleading = temporary.appendingPathComponent("image-with-video-extension.mp4")
        try FileManager.default.copyItem(at: source, to: misleading)
        let other = try await MediaProcessor.inspect(url: misleading)
        XCTAssertEqual(other?.reference.kind, .image)
    }

    func testEveryTIFFPageIsPreparedAndMissingPageIndexIsRejected() async throws {
        let source = try imageFile("multipage", type: .tiff, pages: 3)
        let plan = try await inspected(source)
        XCTAssertEqual(plan.segments.map(\.imageIndex), [0, 1, 2])
        var bytes: [Data] = []
        for reference in plan.segments {
            let result = try await MediaProcessor.segment(url: source, reference: reference)
            XCTAssertEqual(result.reference.imageIndex, reference.imageIndex)
            XCTAssertTrue(result.reference.isValid)
            XCTAssertEqual(result.input.images?.count, 1)
            bytes.append(try XCTUnwrap(result.input.images?.first))
        }
        XCTAssertEqual(Set(bytes).count, 3, "Each page must retain its own artwork")
        await assertFails {
            _ = try await MediaProcessor.segment(url: source, reference: plan.reference)
        }
        await assertFails {
            _ = try await MediaProcessor.segment(url: source,
                                                reference: MediaReference(kind: .image, imageIndex: 3))
        }
    }

    func testLocalOCRLabelsOnlyGenuinelyRecognizedImageText() async throws {
        let url = temporary.appendingPathComponent("text-snapshot")
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1000, height: 200, bitsPerComponent: 8, bytesPerRow: 4000,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 200))
        drawText("NATIVE OCR EVIDENCE 12345", in: context, size: 52, x: 32, y: 80)
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let plan = try await inspected(url)
        let result = try await MediaProcessor.segment(url: url, reference: XCTUnwrap(plan.segments.first))
        let text = try XCTUnwrap(result.text)
        XCTAssertTrue(text.contains("NATIVE OCR"), text)
        XCTAssertTrue(text.contains("12345"), text)
        XCTAssertEqual(result.reference.textSource, .ocr)
        XCTAssertEqual(result.reference.recipe, MediaProcessor.recipe)
        XCTAssertTrue(result.input.isValid)
        _ = try decodedJPEG(XCTUnwrap(result.input.images?.first))
    }

    func testEveryAnimatedGIFFrameIsIncluded() async throws {
        let source = try imageFile("animation", type: .gif, pages: 4)
        let plan = try await inspected(source)
        XCTAssertEqual(plan.segments.map(\.imageIndex), [0, 1, 2, 3])
        var bytes = Set<Data>()
        for reference in plan.segments {
            let result = try await MediaProcessor.segment(url: source, reference: reference)
            bytes.insert(try XCTUnwrap(result.input.images?.first))
        }
        XCTAssertEqual(bytes.count, 4)
    }

    func testAudioCoversTenSecondBoundariesAndShortTailWithRealPCM16WAV() async throws {
        let original = try audioFile("original.wav", duration: 20.025)
        let source = temporary.appendingPathComponent("snapshot")
        try FileManager.default.copyItem(at: original, to: source)
        let plan = try await inspected(source)
        XCTAssertEqual(plan.reference.kind, .audio)
        XCTAssertTrue(plan.reference.isValid)
        XCTAssertEqual(plan.segments.count, 3)
        XCTAssertEqual(plan.segments.map(\.startSeconds), [0, 10, 20])
        XCTAssertEqual(try XCTUnwrap(plan.segments.last?.endSeconds), 20.025, accuracy: 0.000001)
        for (index, reference) in plan.segments.enumerated() {
            XCTAssertTrue(reference.isValid)
            let result = try await MediaProcessor.segment(url: source, reference: reference)
            XCTAssertEqual(result.reference.startSeconds, reference.startSeconds)
            XCTAssertEqual(result.reference.endSeconds, reference.endSeconds)
            XCTAssertEqual(result.reference.audioIncluded, true)
            XCTAssertEqual(result.reference.recipe, "eg2-media-v1")
            XCTAssertNil(result.input.images)
            XCTAssertNil(result.input.timestamps)
            XCTAssertNil(result.text)
            XCTAssertNil(result.reference.textSource)
            try assertWAV(XCTUnwrap(result.input.audio), frames: index == 2 ? 400 : 160_000)
        }
        let misleading = temporary.appendingPathComponent("sound.png")
        try FileManager.default.copyItem(at: original, to: misleading)
        let other = try await MediaProcessor.inspect(url: misleading)
        XCTAssertEqual(other?.reference.kind, .audio, "An image extension must not hide actual audio")
    }

    func testAudioExactMultipleDoesNotAddAnEmptySegmentAndOneSampleTailSurvives() async throws {
        let exact = try audioFile("exact.wav", duration: 20, rate: 16_000)
        let exactPlan = try await inspected(exact)
        XCTAssertEqual(exactPlan.segments.count, 2)
        XCTAssertEqual(exactPlan.segments.last?.endSeconds, 20)
        let oneSample = try audioFile("one-sample-tail.wav", duration: 10 + 1.0 / 16_000, rate: 16_000)
        let tailPlan = try await inspected(oneSample)
        XCTAssertEqual(tailPlan.segments.count, 2)
        let tail = try await MediaProcessor.segment(url: oneSample, reference: XCTUnwrap(tailPlan.segments.last))
        XCTAssertEqual(tail.reference.endSeconds, 10 + 1.0 / 16_000)
        XCTAssertEqual(try XCTUnwrap(tail.reference.endSeconds) - XCTUnwrap(tail.reference.startSeconds),
                       0.02, accuracy: 0.000001)
        try assertWAV(XCTUnwrap(tail.input.audio), frames: 320)
    }

    func testSub20msAudioRemaindersShiftBoundariesWithoutGapsOrOverBudgetSegments() async throws {
        for duration in [10.005, 20.001] {
            let source = try audioFile("tail-\(duration).wav", duration: duration)
            let plan = try await inspected(source)
            var previousEnd = 0.0
            var totalFrames = 0
            for reference in plan.segments {
                let start = try XCTUnwrap(reference.startSeconds), end = try XCTUnwrap(reference.endSeconds)
                XCTAssertEqual(start, previousEnd, accuracy: 0.000000001)
                XCTAssertLessThanOrEqual(end - start, 10)
                XCTAssertGreaterThanOrEqual(end - start + 0.000000001, 0.02)
                let result = try await MediaProcessor.segment(url: source, reference: reference)
                let frames = Int(((end - start) * 16_000).rounded())
                try assertWAV(XCTUnwrap(result.input.audio), frames: frames)
                totalFrames += frames
                previousEnd = end
            }
            XCTAssertEqual(previousEnd, duration, accuracy: 0.000000001)
            XCTAssertEqual(totalFrames, Int((duration * 16_000).rounded()))
        }
    }

    func testEntireAudioBelow20msReportsEncoderMinimumAndExact20msWorks() async throws {
        let short = try audioFile("very-short.wav", duration: 0.005)
        do {
            _ = try await MediaProcessor.inspect(url: short)
            XCTFail("Below-minimum complete audio must fail clearly instead of losing its samples")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("20 毫秒"), "\(error)")
        }
        let minimum = try audioFile("minimum.wav", duration: 0.02, rate: 16_000)
        let plan = try await inspected(minimum)
        let result = try await MediaProcessor.segment(url: minimum, reference: XCTUnwrap(plan.segments.first))
        try assertWAV(XCTUnwrap(result.input.audio), frames: 320)
    }

    func testSilentExtensionlessVideoUsesAbsoluteRecordedTimesAndIncludesTail() async throws {
        let original = try await videoFile("silent.mov", duration: 10.25)
        let source = temporary.appendingPathComponent("snapshot")
        try FileManager.default.copyItem(at: original, to: source)
        let plan = try await inspected(source)
        XCTAssertEqual(plan.reference.kind, .video)
        XCTAssertEqual(plan.reference.audioIncluded, false)
        XCTAssertTrue(plan.reference.isValid)
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0].frameTimes?.count, 8)
        XCTAssertEqual(plan.segments[1].frameTimes, [10.125])
        XCTAssertEqual(plan.segments[1].startSeconds, 10)
        XCTAssertEqual(plan.segments[1].endSeconds, 10.25)
        for (index, reference) in plan.segments.enumerated() {
            XCTAssertTrue(reference.isValid)
            let times = try XCTUnwrap(reference.frameTimes)
            if times.count > 2 {
                for pair in zip(times.dropFirst(), times.dropLast()) {
                    XCTAssertEqual(pair.0 - pair.1, 1.25, accuracy: 0.000001)
                }
            }
            let result = try await MediaProcessor.segment(url: source, reference: reference)
            XCTAssertEqual(result.input.kind, .video)
            XCTAssertEqual(result.input.timestamps, reference.frameTimes)
            XCTAssertEqual(result.reference.frameTimes, reference.frameTimes)
            XCTAssertEqual(result.input.images?.count, reference.frameTimes?.count)
            XCTAssertEqual(result.reference.audioIncluded, false)
            XCTAssertNil(result.input.audio)
            XCTAssertNil(result.text)
            XCTAssertNil(result.reference.textSource)
            XCTAssertTrue(result.reference.isValid)
            let image = try decodedJPEG(XCTUnwrap(result.input.images?.last))
            let color = try centerColor(image)
            if index == 0 { XCTAssertGreaterThan(color.red, color.blue + 0.5) }
            else { XCTAssertGreaterThan(color.blue, color.red + 0.5) }
        }
        let misleading = temporary.appendingPathComponent("movie.wav")
        try FileManager.default.copyItem(at: source, to: misleading)
        let mislabeledPlan = try await MediaProcessor.inspect(url: misleading)
        XCTAssertEqual(mislabeledPlan?.reference.kind, .video)
    }

    func testVideoWithAudioIncludesDecodedWAVForTheSameTimeRange() async throws {
        let movie = try await videoFile("picture.mov", duration: 2.25)
        let sound = try audioFile("sound.wav", duration: 2.25)
        let source = try await combine(movie: movie, audio: sound, name: "audiovisual.mov", duration: 2.25)
        let snapshot = temporary.appendingPathComponent("snapshot")
        try FileManager.default.copyItem(at: source, to: snapshot)
        let plan = try await inspected(snapshot)
        XCTAssertEqual(plan.reference.kind, .video)
        XCTAssertEqual(plan.reference.audioIncluded, true)
        let reference = try XCTUnwrap(plan.segments.first)
        let result = try await MediaProcessor.segment(url: snapshot, reference: reference)
        XCTAssertEqual(result.reference.audioIncluded, true)
        XCTAssertEqual(result.input.images?.count, 3)
        XCTAssertEqual(result.input.timestamps, reference.frameTimes)
        try assertWAV(XCTUnwrap(result.input.audio), frames: 36_000)
    }

    func testVideoThumbnailOCRProvidesReadableEvidenceWithoutATranscript() async throws {
        let url = try await videoFile("text-video.mov", duration: 0.5, text: "FRAME123")
        let plan = try await inspected(url)
        let result = try await MediaProcessor.segment(url: url, reference: XCTUnwrap(plan.segments.first))
        let text = try XCTUnwrap(result.text)
        XCTAssertTrue(text.contains("FRAME123"), text)
        XCTAssertEqual(result.reference.textSource, .ocr)
        XCTAssertEqual(result.reference.audioIncluded, false)
        XCTAssertTrue(result.input.isValid)
        XCTAssertTrue(result.reference.isValid)
    }

    func testVideoOutlastingItsAudioDoesNotMistakeASilentTailForFailure() async throws {
        let movie = try await videoFile("long-picture.mov", duration: 10.25)
        let sound = try audioFile("short-sound.wav", duration: 0.25)
        let source = try await combine(movie: movie, audio: sound, name: "short-audio.mov", duration: 0.25)
        let plan = try await inspected(source)
        XCTAssertEqual(plan.reference.audioIncluded, true)
        XCTAssertEqual(plan.segments.map(\.audioIncluded), [true, false])
        let tail = try await MediaProcessor.segment(url: source, reference: XCTUnwrap(plan.segments.last))
        XCTAssertEqual(tail.reference.audioIncluded, false)
        XCTAssertNil(tail.input.audio)
        XCTAssertEqual(tail.input.timestamps, [10.125])
    }

    func testUndecodablePresentAudioIsNeverReportedAsSilentVideo() async throws {
        let movie = try await videoFile("picture.mov", duration: 0.5)
        let sound = try audioFile("sound.wav", duration: 0.5)
        let source = try await combine(movie: movie, audio: sound, name: "bad-audio.mov", duration: 0.5)
        let goodPlan = try await inspected(source)
        XCTAssertEqual(goodPlan.reference.audioIncluded, true)
        var bytes = try Data(contentsOf: source)
        // Corrupt only the audio sample-description codec in a native-written
        // self-contained movie. The video samples and hdlr audio track remain.
        let range = try XCTUnwrap(bytes.range(of: Data("sowt".utf8)) ??
                                  bytes.range(of: Data("lpcm".utf8)))
        bytes.replaceSubrange(range, with: Data("zzzz".utf8))
        try bytes.write(to: source)
        await assertFails {
            _ = try await MediaProcessor.segment(url: source, reference: XCTUnwrap(goodPlan.segments.first))
        }
    }

    func testOrdinaryDocumentsRemainNonMediaDespiteMisleadingExtensions() async throws {
        for name in ["README", "plain.mp4", "plain.wav", "plain.jpg", "plain.heic"] {
            let url = try write(name, Data("普通文字资料，不是媒体。\nhttps://example.invalid/not-a-resource".utf8))
            let plan = try await MediaProcessor.inspect(url: url)
            XCTAssertNil(plan, name)
        }
        for (index, encoding) in [String.Encoding.utf16, .utf16LittleEndian, .utf32, .utf32LittleEndian].enumerated() {
            let text = try XCTUnwrap("中文资料 English".data(using: encoding))
            let url = try write("unicode-\(index)", text)
            let plan = try await MediaProcessor.inspect(url: url)
            XCTAssertNil(plan, "A Unicode BOM must not be mistaken for MPEG audio sync")
        }
        let empty = try write("empty", Data())
        let unknown = try write("unknown", Data([1, 2, 3, 4, 0, 255]))
        let emptyPlan = try await MediaProcessor.inspect(url: empty)
        let unknownPlan = try await MediaProcessor.inspect(url: unknown)
        XCTAssertNil(emptyPlan)
        XCTAssertNil(unknownPlan)
    }

    func testRecognizableCorruptImageAudioAndVideoThrowClearErrors() async throws {
        let fixtures: [Data] = [
            Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 16]),
            Data([137, 80, 78, 71, 13, 10, 26, 10]),
            Data("RIFF".utf8) + Data([255, 255, 0, 0]) + Data("WAVEfmt ".utf8),
            Data([0, 0, 0, 24]) + Data("ftypisom".utf8),
            Data("GIF89a".utf8),
        ]
        for (index, bytes) in fixtures.enumerated() {
            let url = try write("corrupt-\(index)", bytes)
            await assertFails { _ = try await MediaProcessor.inspect(url: url) }
        }
    }

    func testRemoteSymlinkDirectoryFIFOAndMissingInputsAreRejected() async throws {
        let image = try imageFile("source.png")
        let symlink = temporary.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: image)
        let pipe = temporary.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let urls = [
            try XCTUnwrap(URL(string: "https://example.invalid/media.wav")),
            try XCTUnwrap(URL(string: "file://example.invalid/tmp/media.wav")),
            symlink, temporary!, pipe, temporary.appendingPathComponent("missing"),
        ]
        for url in urls {
            await assertFails { _ = try await MediaProcessor.inspect(url: url) }
            await assertFails {
                _ = try await MediaProcessor.segment(url: url, reference: MediaReference(kind: .image))
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }

    func testInvalidReferenceKindRangeRecipeAndFrameBudgetAreRejected() async throws {
        let audio = try audioFile("sound.wav", duration: 1)
        let invalid = [
            MediaReference(kind: .audio, startSeconds: 0, endSeconds: 11),
            MediaReference(kind: .audio, startSeconds: 0, endSeconds: 2),
            MediaReference(kind: .audio, startSeconds: .nan, endSeconds: 1),
            MediaReference(kind: .audio, startSeconds: 0, endSeconds: .infinity),
            MediaReference(kind: .audio, startSeconds: 0, endSeconds: 1, recipe: "future-recipe"),
            MediaReference(kind: .video, startSeconds: 0, endSeconds: 1, frameTimes: [0.5, 0.5]),
            MediaReference(kind: .video, startSeconds: 0, endSeconds: 1, frameTimes: [1]),
            MediaReference(kind: .video, startSeconds: 0, endSeconds: 1,
                           frameTimes: (0..<9).map { Double($0) / 10 }),
            MediaReference(kind: .image, imageIndex: -1),
            MediaReference(kind: .image, imageIndex: 0),
        ]
        for reference in invalid {
            await assertFails { _ = try await MediaProcessor.segment(url: audio, reference: reference) }
        }
    }

    func testCancellationPropagatesBeforeInspectAndBeforeSegment() async throws {
        let source = try imageFile("source.png")
        let before = try stagingDirectories()
        let inspect = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaProcessor.inspect(url: source)
        }
        do { _ = try await inspect.value; XCTFail("Cancelled inspection must throw") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let segment = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaProcessor.segment(url: source, reference: MediaReference(kind: .image))
        }
        do { _ = try await segment.value; XCTFail("Cancelled preparation must throw") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(try stagingDirectories(), before)
    }

    func testCancellationDuringMultipageInspectionCleansPrivateStaging() async throws {
        let source = try imageFile("many-pages.tiff", type: .tiff, width: 320, height: 240, pages: 256)
        let before = try stagingDirectories()
        let task = Task.detached { try await MediaProcessor.inspect(url: source) }
        defer { task.cancel() }
        var sawStaging = false
        for _ in 0..<1000 {
            if !(try stagingDirectories()).subtracting(before).isEmpty {
                sawStaging = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation after staging must reach the page loop") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(sawStaging, "Cancellation must occur after native preparation starts")
        XCTAssertEqual(try stagingDirectories(), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testSuccessfulAndFailedPreparationCleanPrivateStaging() async throws {
        let before = try stagingDirectories()
        let source = try audioFile("sound.wav", duration: 0.25)
        let plan = try await inspected(source)
        _ = try await MediaProcessor.segment(url: source, reference: XCTUnwrap(plan.segments.first))
        let corrupt = try write("bad", Data("GIF89a".utf8))
        await assertFails { _ = try await MediaProcessor.inspect(url: corrupt) }
        XCTAssertEqual(try stagingDirectories(), before)
    }

    func testCancellationDuringVideoPreparationPropagatesAndCleansStaging() async throws {
        let url = try await videoFile("cancel-video.mov", duration: 10)
        let plan = try await inspected(url)
        let reference = try XCTUnwrap(plan.segments.first)
        let before = try stagingDirectories()
        let task = Task.detached { try await MediaProcessor.segment(url: url, reference: reference) }
        defer { task.cancel() }
        var sawStaging = false
        for _ in 0..<1000 {
            if !(try stagingDirectories()).subtracting(before).isEmpty {
                sawStaging = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        // Give asset loading a chance to reach asynchronous frame generation.
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled video preparation must throw") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(sawStaging)
        XCTAssertEqual(try stagingDirectories(), before)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func inspected(_ url: URL) async throws -> MediaPlan {
        let plan = try await MediaProcessor.inspect(url: url)
        let unwrapped = try XCTUnwrap(plan)
        XCTAssertEqual(unwrapped.reference.recipe, MediaProcessor.recipe)
        XCTAssertTrue(unwrapped.segments.allSatisfy { $0.recipe == MediaProcessor.recipe })
        return unwrapped
    }

    private func drawText(_ text: String, in context: CGContext, size: CGFloat, x: CGFloat, y: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }

    private func imageFile(
        _ name: String, type: UTType = .png, width: Int = 160, height: Int = 96,
        orientation: Int = 1, pages: Int = 1
    ) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, pages, nil
        ))
        for index in 0..<pages {
            try autoreleasepool {
                let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
                let context = try XCTUnwrap(CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                let colors: [CGColor] = [
                    CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                    CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                    CGColor(red: 0, green: 0, blue: 1, alpha: 1),
                    CGColor(red: 1, green: 1, blue: 0, alpha: 1),
                ]
                context.setFillColor(colors[index % colors.count])
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let image = try XCTUnwrap(context.makeImage())
                CGImageDestinationAddImage(destination, image, [
                    kCGImagePropertyOrientation: orientation,
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
                ] as CFDictionary)
            }
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func audioFile(_ name: String, duration: Double, rate: Double = 48_000) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        let output = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 4096))
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let frames = Int((duration * rate).rounded())
        var offset = 0
        while offset < frames {
            let count = min(4096, frames - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let sample = Float(0.3 * sin(2 * .pi * 440 * Double(offset + index) / rate))
                channels[0][index] = sample
                channels[1][index] = sample
            }
            try output.write(from: buffer)
            offset += count
        }
        return url
    }

    private func videoFile(_ name: String, duration: Double, text: String? = nil) async throws -> URL {
        let url = temporary.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 96,
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        let frameCount = Int((duration * 4).rounded())
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing { throw try XCTUnwrap(writer.error) }
                try await Task.sleep(for: .milliseconds(1))
            }
            var pixelBuffer: CVPixelBuffer?
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            do {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let memory = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<96 {
                    for x in 0..<160 {
                        let offset = y * stride + x * 4
                        memory[offset] = index >= 40 ? 255 : 0
                        memory[offset + 1] = 0
                        memory[offset + 2] = index >= 40 ? 0 : 255
                        memory[offset + 3] = 255
                    }
                }
                if let text {
                    let context = try XCTUnwrap(CGContext(
                        data: base, width: 160, height: 96, bitsPerComponent: 8, bytesPerRow: stride,
                        space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                    ))
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: 160, height: 96))
                    drawText(text, in: context, size: 24, x: 8, y: 38)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 4)) else {
                throw try XCTUnwrap(writer.error)
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 48_000))
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw try XCTUnwrap(writer.error) }
        return url
    }

    private func combine(movie: URL, audio: URL, name: String, duration: Double) async throws -> URL {
        let composition = AVMutableComposition()
        let movieAsset = AVURLAsset(url: movie)
        let audioAsset = AVURLAsset(url: audio)
        let videoTracks = try await movieAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let movieDuration = try await movieAsset.load(.duration)
        let picture = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let sound = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        try picture.insertTimeRange(CMTimeRange(start: .zero, duration: movieDuration),
                                    of: XCTUnwrap(videoTracks.first), at: .zero)
        try sound.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 48_000)),
                                  of: XCTUnwrap(audioTracks.first), at: .zero)
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        let url = temporary.appendingPathComponent(name)
        export.outputURL = url
        export.outputFileType = .mov
        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else { throw try XCTUnwrap(export.error) }
        return url
    }

    private func decodedJPEG(_ data: Data) throws -> CGImage {
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 1024)
        return image
    }

    private func centerColor(_ image: CGImage) throws -> (red: Double, blue: Double) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (Double(bytes[0]) / 255, Double(bytes[2]) / 255)
    }

    private func assertWAV(_ data: Data, frames: Int, requireSignal: Bool = true,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(data.count, 44 + frames * 2, file: file, line: line)
        guard data.count >= 44 else { return }
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ count: Int) -> UInt32 {
            (0..<count).reduce(0) { $0 | (UInt32(bytes[offset + $1]) << (8 * $1)) }
        }
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF", file: file, line: line)
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ", file: file, line: line)
        XCTAssertEqual(number(4, 4), UInt32(data.count - 8), file: file, line: line)
        XCTAssertEqual(number(16, 4), 16, file: file, line: line)
        XCTAssertEqual(number(20, 2), 1, file: file, line: line)
        XCTAssertEqual(number(22, 2), 1, file: file, line: line)
        XCTAssertEqual(number(24, 4), 16_000, file: file, line: line)
        XCTAssertEqual(number(28, 4), 32_000, file: file, line: line)
        XCTAssertEqual(number(32, 2), 2, file: file, line: line)
        XCTAssertEqual(number(34, 2), 16, file: file, line: line)
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data", file: file, line: line)
        XCTAssertEqual(number(40, 4), UInt32(frames * 2), file: file, line: line)
        // Independently parse and decode the actual generated WAV with Core
        // Audio rather than validating only the implementation's header shape.
        let url = try write("verified-\(UUID()).wav", data)
        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(audio.fileFormat.sampleRate, 16_000, file: file, line: line)
        XCTAssertEqual(audio.fileFormat.channelCount, 1, file: file, line: line)
        XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mBitsPerChannel, 16, file: file, line: line)
        XCTAssertEqual(audio.length, AVAudioFramePosition(frames), file: file, line: line)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(frames)))
        try audio.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, AVAudioFrameCount(frames), file: file, line: line)
        if requireSignal {
            let signal = try XCTUnwrap(buffer.floatChannelData)[0]
            var energy: Float = 0
            for index in 0..<Int(buffer.frameLength) { energy += abs(signal[index]) }
            XCTAssertGreaterThan(energy, 1, "A valid header must not hide missing decoded samples", file: file, line: line)
        }
    }

    private func stagingDirectories() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("AskBase-Media-\(getpid())-") })
    }

    private func assertFails(file: StaticString = #filePath, line: UInt = #line,
                             _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected an explicit media error", file: file, line: line) }
        catch {
            XCTAssertTrue(error is AskBaseError, "Unexpected error: \(error)", file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
    }
}
