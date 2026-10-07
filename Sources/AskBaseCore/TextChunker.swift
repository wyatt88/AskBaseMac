import Foundation

public enum TextChunker {
    /// Limits and overlap are measured in extended grapheme clusters, so a Chinese
    /// character, combining accent, or emoji sequence is never split in half.
    /// Invalid sizes produce no chunks; overlap is clamped to permit progress.
    public static func chunks(
        pages: [ParsedPage], documentID: String, knowledgeBaseID: String,
        maxCharacters: Int = 1200, overlap: Int = 160
    ) -> [DocumentChunk] {
        guard maxCharacters > 0 else { return [] }
        let overlap = min(max(overlap, 0), maxCharacters - 1)
        var result: [DocumentChunk] = []

        for page in pages {
            guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let characters = Array(page.text)
            var start = 0
            while start < characters.count {
                // Subtraction first avoids overflow for callers using Int.max.
                let hardEnd = start + min(maxCharacters, characters.count - start)
                var end = hardEnd
                if hardEnd < characters.count {
                    // Prefer a nearby sentence/line boundary without allowing a
                    // short chunk to make the overlap move backwards.
                    let minimumLength = max(overlap + 1, (hardEnd - start) * 3 / 4)
                    let minimumEnd = start + minimumLength
                    if minimumEnd < hardEnd {
                        for candidate in stride(from: hardEnd, through: minimumEnd, by: -1) {
                            if isBoundary(characters[candidate - 1]) {
                                end = candidate
                                break
                            }
                        }
                    }
                }
                let text = String(characters[start..<end])
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(DocumentChunk(
                        documentID: documentID, knowledgeBaseID: knowledgeBaseID,
                        ordinal: result.count, page: page.page, text: text
                    ))
                }
                if end == characters.count { break }
                start = end - overlap
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
