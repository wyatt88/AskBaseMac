import Foundation
import Accelerate

public enum Retrieval {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &aa, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &bb, vDSP_Length(b.count))
        guard aa > 0, bb > 0 else { return 0 }
        return Double(dot / sqrt(aa * bb))
    }

    public static func rank(query: String, vector: [Float], chunks: [DocumentChunk],
                            documents: [LibraryDocument], limit: Int) -> [SearchResult] {
        let titles = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.title) })
        let terms = lexicalTerms(query)
        let ranked = chunks.map { chunk -> (DocumentChunk, Double) in
            let semantic = cosine(vector, chunk.embedding)
            let text = (titles[chunk.documentID, default: ""] + "\n" + chunk.text).lowercased()
            let matched = terms.filter { text.contains($0) }.count
            let lexical = terms.isEmpty ? 0 : Double(matched) / Double(terms.count)
            return (chunk, semantic + 0.08 * lexical)
        }.sorted { left, right in
            if left.1 == right.1 { return left.0.id < right.0.id }
            return left.1 > right.1
        }
        // Suppress identical text or duplicate chunk positions within one document.
        var selected: [(DocumentChunk, Double)] = []
        for item in ranked {
            let isDuplicate = selected.contains {
                $0.0.documentID == item.0.documentID &&
                ($0.0.text == item.0.text || abs($0.0.ordinal - item.0.ordinal) < 1)
            }
            if !isDuplicate { selected.append(item) }
            if selected.count >= max(1, min(limit, 12)) { break }
        }
        return selected.map { chunk, score in
            SearchResult(id: chunk.id, documentID: chunk.documentID,
                         knowledgeBaseID: chunk.knowledgeBaseID,
                         title: titles[chunk.documentID, default: "未命名资料"],
                         text: chunk.text, page: chunk.page, score: score)
        }
    }

    static func lexicalTerms(_ text: String) -> [String] {
        var terms = Set(text.lowercased().components(separatedBy: .whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty })
        let chinese: [Unicode.Scalar] = Array(text.unicodeScalars).filter { (0x3400...0x9FFF).contains($0.value) }
        if chinese.count >= 2 {
            for i in 0..<(chinese.count - 1) {
                let first = String(chinese[i])
                let second = String(chinese[i + 1])
                terms.insert(first + second)
            }
        }
        return Array(terms.sorted().prefix(64))
    }
}
