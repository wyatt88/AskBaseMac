import Foundation

public enum TextChunker {
    /// Limits and overlap are measured in extended grapheme clusters, so a Chinese
    /// character, combining accent, or emoji sequence is never split in half.
    /// Invalid sizes produce no chunks; overlap is clamped to permit progress.
    public static func chunks(
        pages: [ParsedPage], documentID: String, knowledgeBaseID: String,
        maxCharacters: Int = 1200, overlap: Int = 160
    ) -> [DocumentChunk] {
        makeChunks(pages: pages, documentID: documentID, knowledgeBaseID: knowledgeBaseID,
                   maxCharacters: maxCharacters, overlap: overlap, checkCancellation: {})
    }

    static func cancellableChunks(
        pages: [ParsedPage], documentID: String, knowledgeBaseID: String,
        maxCharacters: Int = 1200, overlap: Int = 160
    ) throws -> [DocumentChunk] {
        try makeChunks(pages: pages, documentID: documentID, knowledgeBaseID: knowledgeBaseID,
                       maxCharacters: maxCharacters, overlap: overlap) {
            try Task.checkCancellation()
        }
    }

    private static func makeChunks(
        pages: [ParsedPage], documentID: String, knowledgeBaseID: String,
        maxCharacters: Int, overlap: Int, checkCancellation: () throws -> Void
    ) rethrows -> [DocumentChunk] {
        try checkCancellation()
        guard maxCharacters > 0 else { return [] }
        let overlap = min(max(overlap, 0), maxCharacters - 1)
        var result: [DocumentChunk] = []

        for page in pages {
            try checkCancellation()
            let source = page.text
            var start = source.startIndex
            while start < source.endIndex {
                try checkCancellation()
                // Walk String indices instead of materializing a Character array
                // for the entire document. Only the current window is copied.
                let hardEnd = source.index(start, offsetBy: maxCharacters,
                                           limitedBy: source.endIndex) ?? source.endIndex
                var end = hardEnd
                if hardEnd < source.endIndex {
                    // Prefer a nearby sentence/line boundary without allowing a
                    // short chunk to make the overlap move backwards.
                    let threeQuarters = (maxCharacters / 4) * 3 + (maxCharacters % 4) * 3 / 4
                    let minimumLength = max(overlap + 1, threeQuarters)
                    let minimumEnd = source.index(start, offsetBy: minimumLength)
                    if minimumEnd < hardEnd {
                        var candidate = hardEnd
                        while candidate >= minimumEnd {
                            let previous = source.index(before: candidate)
                            if isBoundary(source[previous]) {
                                end = candidate
                                break
                            }
                            candidate = previous
                        }
                    }
                }
                let text = String(source[start..<end])
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(DocumentChunk(
                        documentID: documentID, knowledgeBaseID: knowledgeBaseID,
                        ordinal: result.count, page: page.page, text: text
                    ))
                }
                if end == source.endIndex { break }
                start = source.index(end, offsetBy: -overlap)
            }
        }
        return result
    }

    private static func isBoundary(_ character: Character) -> Bool {
        switch character {
        case "\n", "\r", "\r\n", "。", "！", "？", "!", "?", ".", ";", "；": true
        default: false
        }
    }
}
