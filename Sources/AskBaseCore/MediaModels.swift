import Foundation

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image, audio, video
    public var label: String {
        switch self { case .image: "图片"; case .audio: "音频"; case .video: "视频" }
    }
    public var symbol: String {
        switch self { case .image: "photo"; case .audio: "waveform"; case .video: "film" }
    }
}

public enum MediaTextSource: String, Codable, Sendable {
    case ocr
    public var label: String { "画面文字（OCR）" }
}

/// Position in the original media, never a path or a generated description.
/// New optional fields allow existing text-only libraries and citations to decode.
public struct MediaReference: Codable, Equatable, Sendable {
    public var kind: MediaKind
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var frameTimes: [Double]?
    public var imageIndex: Int?
    public var audioIncluded: Bool?
    public var textSource: MediaTextSource?
    public var encoderSignature: String?
    public var recipe: String?

    public init(kind: MediaKind, startSeconds: Double? = nil, endSeconds: Double? = nil,
                frameTimes: [Double]? = nil, imageIndex: Int? = nil,
                audioIncluded: Bool? = nil, textSource: MediaTextSource? = nil,
                encoderSignature: String? = nil, recipe: String? = nil) {
        self.kind = kind; self.startSeconds = startSeconds; self.endSeconds = endSeconds
        self.frameTimes = frameTimes; self.imageIndex = imageIndex
        self.audioIncluded = audioIncluded; self.textSource = textSource
        self.encoderSignature = encoderSignature; self.recipe = recipe
    }

    public var positionLabel: String {
        if let startSeconds, let endSeconds {
            return "\(Self.timestamp(startSeconds))–\(Self.timestamp(endSeconds))"
        }
        if let imageIndex, imageIndex > 0 { return "第 \(imageIndex + 1) 帧／页" }
        return kind.label
    }

    public static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let value = Int(seconds.rounded(.down))
        if abs(seconds - Double(value)) > 0.0001 {
            let remainder = seconds - Double(value / 60 * 60)
            if value >= 3600 {
                return String(format: "%d:%02d:%06.3f", value / 3600, value / 60 % 60, remainder)
            }
            return String(format: "%02d:%06.3f", value / 60, remainder)
        }
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    public var isValid: Bool {
        if let imageIndex, imageIndex < 0 { return false }
        if kind == .image {
            return startSeconds == nil && endSeconds == nil && frameTimes == nil && audioIncluded != true
        }
        guard let startSeconds, let endSeconds, startSeconds.isFinite, endSeconds.isFinite,
              startSeconds >= 0, endSeconds > startSeconds, imageIndex == nil else { return false }
        if kind == .audio, textSource != nil { return false }
        if let frameTimes {
            guard kind == .video, (1...8).contains(frameTimes.count),
                  frameTimes.allSatisfy({ $0.isFinite && $0 >= startSeconds && $0 < endSeconds }),
                  zip(frameTimes, frameTimes.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else { return false }
        }
        return true
    }
}

/// Encoded bytes only. The local service never receives arbitrary paths or URLs.
public struct MediaEmbeddingInput: Codable, Equatable, Sendable {
    public var kind: MediaKind
    public var images: [Data]?
    public var audio: Data?
    public var timestamps: [Double]?
    public init(kind: MediaKind, images: [Data]? = nil, audio: Data? = nil,
                timestamps: [Double]? = nil) {
        self.kind = kind; self.images = images; self.audio = audio; self.timestamps = timestamps
    }
    public var isValid: Bool {
        switch kind {
        case .image:
            return images?.count == 1 && images?.first?.isEmpty == false && audio == nil && timestamps == nil
        case .audio:
            return audio?.isEmpty == false && images == nil && timestamps == nil
        case .video:
            guard let images, (1...8).contains(images.count), images.allSatisfy({ !$0.isEmpty }),
                  let timestamps, timestamps.count == images.count,
                  timestamps.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else { return false }
            return audio.map { !$0.isEmpty } ?? true
        }
    }
}

public struct MediaPlan: Sendable {
    public var reference: MediaReference
    public var segments: [MediaReference]
    public init(reference: MediaReference, segments: [MediaReference]) {
        self.reference = reference; self.segments = segments
    }
}

public struct PreparedMediaSegment: Sendable {
    public var reference: MediaReference
    public var input: MediaEmbeddingInput
    /// Actual locally recognized text, if any. Never a fabricated transcript.
    public var text: String?
    public init(reference: MediaReference, input: MediaEmbeddingInput, text: String? = nil) {
        self.reference = reference; self.input = input; self.text = text
    }
}
