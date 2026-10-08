import AppKit
import Darwin
import Foundation
import PDFKit

/// Reads an already validated, stable local snapshot. File names are hints, never
/// an allowlist. Buffer sizes below are I/O granularity, not document budgets.
///
/// PDF page numbers and presentation slide numbers refer to the source. Reflowable
/// documents, workbook sheets and EPUB spine items deliberately have no page number.
/// Office extraction reads stored text/cached values; it does not render layouts,
/// recalculate formulas, execute macros, fetch links, or perform OCR.
enum DocumentTextExtractor {
    static func parse(url: URL, originalFilename: String) throws -> [ParsedPage] {
        try Task.checkCancellation()
        guard url.isFileURL else { throw failure("只能读取本机文档快照。") }
        let handle = try FileHandle(forReadingFrom: url)
        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 1_024) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard !prefix.isEmpty else { throw failure("文件为空，没有可提取的文字。") }

        // A textual mention of "%PDF-" is not a PDF signature.
        let significantPrefix = prefix.drop(while: { [9, 10, 12, 13, 32].contains($0) })
        if significantPrefix.starts(with: Data("%PDF-".utf8)) {
            return try pdf(url)
        }
        if prefix.starts(with: [0x50, 0x4B, 0x03, 0x04]) ||
            prefix.starts(with: [0x50, 0x4B, 0x05, 0x06]) ||
            prefix.starts(with: [0x50, 0x4B, 0x07, 0x08]) {
            return try officeArchive(Archive(url: url))
        }
        if prefix.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            throw failure("这是旧版 Office 或加密的 Office 二进制文件；请另存为未加密的 DOCX、XLSX 或 PPTX。")
        }
        let binarySignatures: [[UInt8]] = [
            [0x89, 0x50, 0x4E, 0x47], [0xFF, 0xD8, 0xFF],
            Array("GIF87a".utf8), Array("GIF89a".utf8), Array("RIFF".utf8),
            Array("fLaC".utf8), Array("OggS".utf8), Array("SQLite format 3".utf8),
            [0x1F, 0x8B], [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C],
            [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], [0x7F, 0x45, 0x4C, 0x46],
            [0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE],
            [0xCA, 0xFE, 0xBA, 0xBE], [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30]
        ]
        guard !binarySignatures.contains(where: { prefix.starts(with: $0) }) else {
            throw failure("文件是二进制内容，没有受支持的文档文字层。")
        }
        let data = try read(url)
        let rtfPrefix = String(decoding: prefix.prefix(32), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if rtfPrefix.hasPrefix("{\\rtf") {
            // Explicit RTF-only decoding: never use AppKit's HTML importer.
            guard let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else {
                throw failure("RTF 文件已损坏或无法读取。")
            }
            try Task.checkCancellation()
            return try nonempty([ParsedPage(text: normalized(attributed.string))])
        }

        let text = try decodeText(data)
        try validatePlainText(text)
        let hint = (originalFilename as NSString).pathExtension.lowercased()
        let beginning = text.prefix(512).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if beginning.hasPrefix("<!doctype html") || beginning.hasPrefix("<html") ||
            (["html", "htm", "xhtml"].contains(hint) && beginning.hasPrefix("<")) {
            return try nonempty([ParsedPage(text: htmlText(text))])
        }
        return [ParsedPage(text: try normalized(text))]
    }

    private static func failure(_ message: String) -> AskBaseError { .importFailed(message) }

    private static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            result.append(chunk)
        }
        return result
    }

    private static func pdf(_ url: URL) throws -> [ParsedPage] {
        guard let document = PDFDocument(url: url) else { throw failure("PDF 文件已损坏，无法读取。") }
        guard !document.isLocked else { throw failure("PDF 已加密，请解锁并另存后导入。") }
        guard document.pageCount > 0 else { throw failure("PDF 没有页面。") }
        var pages: [ParsedPage] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw failure("无法读取 PDF 第 \(index + 1) 页。")
            }
            pages.append(ParsedPage(page: index + 1, text: try normalized(page.string ?? "")))
        }
        return try nonempty(pages, message: "PDF 没有可提取文字，可能是扫描件或空白文件；本版本不执行 OCR。")
    }

    private static func normalized(_ text: String) throws -> String {
        var result = String.UnicodeScalarView()
        var previousCR = false
        var index = 0
        for scalar in text.unicodeScalars {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            index += 1
            if scalar == "\r" {
                result.append("\n")
            } else if scalar != "\n" || !previousCR {
                result.append(scalar)
            }
            previousCR = scalar == "\r"
        }
        return String(result)
    }

    private static func hasText(_ text: String) throws -> Bool {
        var index = 0
        for scalar in text.unicodeScalars {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            index += 1
            switch scalar.properties.generalCategory {
            case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator,
                 .nonspacingMark, .enclosingMark: continue
            default: return true
            }
        }
        return false
    }

    private static func nonempty(
        _ pages: [ParsedPage], message: String = "文件没有可提取的文字。"
    ) throws -> [ParsedPage] {
        for page in pages {
            try Task.checkCancellation()
            if try hasText(page.text) { return pages }
        }
        throw failure(message)
    }

    private static func validatePlainText(_ text: String) throws {
        var index = 0
        for scalar in text.unicodeScalars {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            index += 1
            let value = scalar.value
            if (value < 32 && ![9, 10, 12, 13].contains(value)) ||
                (127...159).contains(value) || (0xFDD0...0xFDEF).contains(value) ||
                value & 0xFFFF == 0xFFFE || value & 0xFFFF == 0xFFFF {
                throw failure("文件含二进制控制字符，不是有效的纯文本。")
            }
        }
        guard try hasText(text) else { throw failure("文件只有空白或不可见字符，没有可提取的文字。") }
    }

    /// No replacement-character decoding. BOM-less UTF-16/32 is accepted only
    /// when byte lanes identify the encoding; ambiguous UTF-16 needs a BOM.
    private static func decodeText(_ data: Data) throws -> String {
        try Task.checkCancellation()
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            if bytes.starts(with: [0xFF, 0xFE, 0, 0]) {
                return try unicode(bytes, offset: 4, width: 4, littleEndian: true)
            }
            if bytes.starts(with: [0, 0, 0xFE, 0xFF]) {
                return try unicode(bytes, offset: 4, width: 4, littleEndian: false)
            }
            if bytes.starts(with: [0xFF, 0xFE]) {
                return try unicode(bytes, offset: 2, width: 2, littleEndian: true)
            }
            if bytes.starts(with: [0xFE, 0xFF]) {
                return try unicode(bytes, offset: 2, width: 2, littleEndian: false)
            }
            var zeros = [0, 0, 0, 0]
            var utf32LE = !bytes.isEmpty && bytes.count.isMultiple(of: 4)
            var utf32BE = utf32LE
            for index in bytes.indices {
                if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
                if bytes[index] == 0 { zeros[index % 4] += 1 }
                if index % 4 == 3 && bytes[index] != 0 { utf32LE = false }
                if index % 4 == 2 && bytes[index] > 0x10 { utf32LE = false }
                if index % 4 == 0 && bytes[index] != 0 { utf32BE = false }
                if index % 4 == 1 && bytes[index] > 0x10 { utf32BE = false }
            }
            if utf32LE != utf32BE {
                return try unicode(bytes, offset: 0, width: 4, littleEndian: utf32LE)
            }
            if bytes.count.isMultiple(of: 2) {
                let even = zeros[0] + zeros[2], odd = zeros[1] + zeros[3]
                let pairs = bytes.count / 2
                if odd > 0 && odd > even * 4 && odd >= max(1, pairs / 20) {
                    return try unicode(bytes, offset: 0, width: 2, littleEndian: true)
                }
                if even > 0 && even > odd * 4 && even >= max(1, pairs / 20) {
                    return try unicode(bytes, offset: 0, width: 2, littleEndian: false)
                }
            }
            guard var text = String(data: data, encoding: .utf8) else {
                throw failure("文件不是有效的 UTF-8/16/32 文本，或是二进制文件；UTF-16/32 请保留 BOM 字节序标记。")
            }
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            try Task.checkCancellation()
            return text
        }
    }

    private static func unicode(
        _ bytes: UnsafeRawBufferPointer, offset: Int, width: Int, littleEndian: Bool
    ) throws -> String {
        guard (bytes.count - offset).isMultiple(of: width) else {
            throw failure("UTF-\(width * 8) 文件末尾不完整，拒绝有损导入。")
        }
        func unit(_ position: Int) -> UInt32 {
            var value: UInt32 = 0
            for lane in 0..<width {
                value |= UInt32(bytes[position + lane]) << (8 * (littleEndian ? lane : width - 1 - lane))
            }
            return value
        }
        var result = String.UnicodeScalarView()
        var index = offset
        var processed = 0
        while index < bytes.count {
            if processed.isMultiple(of: 4_096) { try Task.checkCancellation() }
            processed += 1
            var value = unit(index)
            index += width
            if width == 2 && (0xD800...0xDBFF).contains(value) {
                guard index < bytes.count, (0xDC00...0xDFFF).contains(unit(index)) else {
                    throw failure("UTF-16 包含不完整的代理字符，拒绝有损导入。")
                }
                value = 0x10000 + (value - 0xD800) * 0x400 + unit(index) - 0xDC00
                index += width
            }
            guard let scalar = UnicodeScalar(value) else {
                throw failure("UTF-\(width * 8) 包含无效字符，拒绝有损导入。")
            }
            result.append(scalar)
        }
        try Task.checkCancellation()
        return String(result)
    }

    // MARK: - ZIP XML document routing and relationships

    private struct Relationship {
        let target: String
        let type: String
        let external: Bool
    }

    private static func officeArchive(_ archive: Archive) throws -> [ParsedPage] {
        if archive.contains("META-INF/container.xml") { return try epub(archive) }
        if archive.contains("mimetype") {
            let mime = try decodeText(archive.member("mimetype")).trimmingCharacters(in: .whitespacesAndNewlines)
            if mime == "application/epub+zip" { return try epub(archive) }
            if mime == "application/vnd.oasis.opendocument.text" { return try odt(archive) }
        }
        if archive.contains("_rels/.rels") || archive.contains("[Content_Types].xml") {
            guard archive.contains("_rels/.rels"), archive.contains("[Content_Types].xml") else {
                throw failure("Office 容器缺少主文档关系或内容类型声明。")
            }
            let roots = try relationships(archive, part: nil)
            let main = roots.values.filter { $0.type.hasSuffix("/officeDocument") }
            guard main.count == 1 else { throw failure("Office 容器未唯一声明主文档，无法确定正文。") }
            if let relationship = main.first {
                guard !relationship.external else { throw failure("Office 正文指向外部资源，拒绝读取。") }
                let path = try resolve(relationship.target, relativeTo: nil)
                guard archive.contains(path) else { throw failure("Office 容器缺少声明的主文档：\(path)。") }
                var contentType: String?
                try xml(archive.member("[Content_Types].xml"), root: "Types", start: { element, attributes in
                    if element == "Override", let name = attributes["PartName"],
                       try resolve(name, relativeTo: nil) == path {
                        contentType = attributes["ContentType"]
                    }
                })
                if let type = contentType?.lowercased() {
                    if type.contains("wordprocessingml") || type.contains("ms-word") {
                        return try docx(archive, part: path)
                    }
                    if type.contains("spreadsheetml") || type.contains("ms-excel") {
                        return try xlsx(archive, part: path)
                    }
                    if type.contains("presentationml") || type.contains("ms-powerpoint") {
                        return try pptx(archive, part: path)
                    }
                }
            }
            // A declared main part is authoritative; stale conventional members
            // must never hide missing or unsupported declared content.
            throw failure("Office 声明的主文档类型缺失或暂不支持，请转换后导入。")
        }
        if archive.contains("word/document.xml") { return try docx(archive, part: "word/document.xml") }
        if archive.contains("xl/workbook.xml") { return try xlsx(archive, part: "xl/workbook.xml") }
        if archive.contains("ppt/presentation.xml") { return try pptx(archive, part: "ppt/presentation.xml") }
        throw failure("ZIP 容器中没有可识别的 DOCX、XLSX、PPTX、ODT 或 EPUB 正文。")
    }

    private static func relationships(_ archive: Archive, part: String?) throws -> [String: Relationship] {
        let path: String
        if let part {
            let directory = (part as NSString).deletingLastPathComponent
            path = (directory.isEmpty ? "" : directory + "/") + "_rels/" +
                (part as NSString).lastPathComponent + ".rels"
        } else {
            path = "_rels/.rels"
        }
        guard archive.contains(path) else { return [:] }
        var result: [String: Relationship] = [:]
        try xml(archive.member(path), root: "Relationships", start: { element, attributes in
            guard element == "Relationship" else { return }
            guard let id = attributes["Id"], let target = attributes["Target"],
                  let type = attributes["Type"], result[id] == nil else {
                throw failure("Office 关系表包含缺失或重复的标识。")
            }
            result[id] = Relationship(target: target, type: type,
                                      external: attributes["TargetMode"]?.lowercased() == "external")
        })
        return result
    }

    private static func related(
        _ id: String?, in relationships: [String: Relationship], part: String, kind: String
    ) throws -> String {
        guard let id, let relationship = relationships[id], relationship.type.hasSuffix("/" + kind) else {
            throw failure("Office 文档缺少 \(kind) 的内容关系。")
        }
        guard !relationship.external else { throw failure("Office 文档引用外部 \(kind)，拒绝读取。") }
        return try resolve(relationship.target, relativeTo: part)
    }

    /// URI resolution stays entirely inside the archive. Nothing here creates a
    /// filesystem URL or follows a resource outside the selected ZIP container.
    private static func resolve(_ reference: String, relativeTo part: String?) throws -> String {
        let pathOnly = String(reference.prefix { $0 != "#" && $0 != "?" })
        guard let path = pathOnly.removingPercentEncoding, !path.isEmpty,
              !path.hasPrefix("//"), !path.contains("\\"),
              !path.contains("\0"), !path.contains("\n"), !path.contains("\r"),
              !(path.split(separator: "/").first?.contains(":") ?? false) else {
            throw failure("文档包含无效路径或外部资源引用。")
        }
        var components: [String] = []
        if !path.hasPrefix("/"), let part {
            components = part.split(separator: "/").dropLast().map(String.init)
        }
        for component in path.split(separator: "/") {
            try Task.checkCancellation()
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw failure("文档路径超出 ZIP 容器。") }
                components.removeLast()
            } else {
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { throw failure("文档正文路径为空。") }
        return components.joined(separator: "/")
    }

    private static func attribute(_ name: String, in attributes: [String: String]) -> String? {
        attributes[name] ?? attributes.first(where: { $0.key.hasSuffix(":" + name) })?.value
    }
}

private extension DocumentTextExtractor {
    // MARK: - Stored Office text

    static func docx(_ archive: Archive, part: String) throws -> [ParsedPage] {
        var text = ""
        var inBody = false
        var inText = false
        var deleted = 0
        try xml(archive.member(part), root: "document", start: { element, _ in
            if element == "body" { inBody = true }
            if element == "del" || element == "moveFrom" { deleted += 1 }
            guard inBody && deleted == 0 else { return }
            if element == "altChunk" {
                throw failure("DOCX 含嵌入式正文（altChunk）；请用 Word 打开并另存后导入，以免遗漏内容。")
            }
            if element == "t" { inText = true }
            if element == "tab" { text += "\t" }
            if element == "br" || element == "cr" { text += "\n" }
        }, text: { characters in
            if inBody && inText && deleted == 0 { text += characters }
        }, end: { element in
            if element == "t" { inText = false }
            if inBody && deleted == 0 {
                if element == "p" || element == "tr" { text += "\n" }
                if element == "tc" { text += "\t" }
            }
            if element == "del" || element == "moveFrom" { deleted -= 1 }
            if element == "body" { inBody = false }
        })
        return try nonempty([ParsedPage(text: normalized(text))])
    }

    static func sharedStrings(_ archive: Archive, part: String) throws -> [String] {
        var strings: [String] = []
        var current: String?
        var inText = false
        var phonetic = 0
        try xml(archive.member(part), root: "sst", start: { element, _ in
            if element == "si" { current = "" }
            if element == "rPh" { phonetic += 1 }
            if element == "t" { inText = true }
        }, text: { text in
            if current != nil && inText && phonetic == 0 { current! += text }
        }, end: { element in
            if element == "t" { inText = false }
            if element == "rPh" { phonetic -= 1 }
            if element == "si", let value = current {
                strings.append(value)
                current = nil
            }
        })
        return strings
    }

    static func xlsx(_ archive: Archive, part: String) throws -> [ParsedPage] {
        let links = try relationships(archive, part: part)
        var sheets: [(String, String)] = []
        var inSheets = false
        try xml(archive.member(part), root: "workbook", start: { element, attributes in
            if element == "sheets" { inSheets = true }
            if inSheets && element == "sheet" {
                let path = try related(attribute("id", in: attributes), in: links, part: part, kind: "worksheet")
                sheets.append((attributes["name"] ?? (path as NSString).lastPathComponent, path))
            }
        }, end: { element in
            if element == "sheets" { inSheets = false }
        })
        var strings: [String] = []
        let stringLinks = links.values.filter { $0.type.hasSuffix("/sharedStrings") }
        guard stringLinks.count <= 1 else { throw failure("XLSX 包含重复的共享字符串表。") }
        if let link = stringLinks.first {
            guard !link.external else { throw failure("XLSX 共享字符串表指向外部资源。") }
            strings = try sharedStrings(archive, part: resolve(link.target, relativeTo: part))
        } else {
            let conventional = try resolve("sharedStrings.xml", relativeTo: part)
            if archive.contains(conventional) { strings = try sharedStrings(archive, part: conventional) }
        }
        var pages: [ParsedPage] = []
        for (name, path) in sheets {
            try Task.checkCancellation()
            let text = try worksheet(archive.member(path), strings: strings)
            // A sheet name alone is metadata, not evidence of nonempty cell text.
            pages.append(ParsedPage(text: try hasText(text) ? "工作表：\(name)\n\(text)" : ""))
        }
        return try nonempty(pages)
    }

    static func worksheet(_ data: Data, strings: [String]) throws -> String {
        var output = ""
        var cellType: String?
        var cellReference = ""
        var value = "", inline = "", formula = ""
        var capture: String?
        var inCell = false
        var inData = false
        var inInline = false
        var phonetic = 0
        var rowHasValue = false
        try xml(data, root: "worksheet", start: { element, attributes in
            if element == "sheetData" { inData = true }
            guard inData else { return }
            if element == "row" { rowHasValue = false }
            if element == "c" {
                inCell = true
                cellType = attributes["t"]
                cellReference = attributes["r"] ?? ""
                value = ""; inline = ""; formula = ""
            }
            guard inCell else { return }
            if element == "is" { inInline = true }
            if element == "rPh" { phonetic += 1 }
            if element == "v" || element == "f" || (element == "t" && inInline && phonetic == 0) {
                capture = element
            }
        }, text: { text in
            switch capture {
            case "v": value += text
            case "t": inline += text
            case "f": formula += text
            default: break
            }
        }, end: { element in
            if element == capture { capture = nil }
            if element == "rPh" { phonetic -= 1 }
            if element == "is" { inInline = false }
            if element == "c" && inCell {
                let stored = value.trimmingCharacters(in: .whitespacesAndNewlines)
                var displayed = stored
                if cellType == "s" && !stored.isEmpty {
                    guard let index = Int(stored), strings.indices.contains(index) else {
                        throw failure("XLSX 单元格 \(cellReference) 引用了不存在的共享字符串。")
                    }
                    displayed = strings[index]
                } else if cellType == "inlineStr" {
                    displayed = inline
                } else if cellType == "b" && !stored.isEmpty {
                    guard stored == "0" || stored == "1" else { throw failure("XLSX 布尔单元格值无效。") }
                    displayed = stored == "1" ? "TRUE" : "FALSE"
                } else if stored.isEmpty && !formula.isEmpty {
                    displayed = "=" + formula
                }
                if try hasText(displayed) {
                    if rowHasValue { output += "\t" }
                    if !cellReference.isEmpty { output += cellReference + ": " }
                    output += displayed
                    rowHasValue = true
                }
                inCell = false
                capture = nil
            }
            if element == "row" && rowHasValue { output += "\n" }
            if element == "sheetData" { inData = false }
        })
        return try normalized(output)
    }

    static func pptx(_ archive: Archive, part: String) throws -> [ParsedPage] {
        let links = try relationships(archive, part: part)
        var slides: [String] = []
        var inSlides = false
        try xml(archive.member(part), root: "presentation", start: { element, attributes in
            if element == "sldIdLst" { inSlides = true }
            if inSlides && element == "sldId" {
                // The unqualified numeric `id` is NOT the relationship `r:id`.
                let id = attributes.first { $0.key.hasSuffix(":id") }?.value
                slides.append(try related(id, in: links, part: part, kind: "slide"))
            }
        }, end: { element in
            if element == "sldIdLst" { inSlides = false }
        })
        var pages: [ParsedPage] = []
        for (index, path) in slides.enumerated() {
            try Task.checkCancellation()
            var text = ""
            var inText = false
            try xml(archive.member(path), root: "sld", start: { element, _ in
                if element == "t" { inText = true }
                if element == "br" { text += "\n" }
            }, text: { characters in
                if inText { text += characters }
            }, end: { element in
                if element == "t" { inText = false }
                if element == "p" || element == "tr" { text += "\n" }
                if element == "tc" { text += "\t" }
            })
            pages.append(ParsedPage(page: index + 1, text: try normalized(text)))
        }
        return try nonempty(pages)
    }

    static func odt(_ archive: Archive) throws -> [ParsedPage] {
        var text = ""
        var inBody = false
        var inDocumentText = false
        var paragraphDepth = 0
        var excluded = 0
        try xml(archive.member("content.xml"), root: "document-content", start: { element, _ in
            if element == "body" { inBody = true }
            if inBody && element == "text" { inDocumentText = true }
            if element == "tracked-changes" || element == "annotation" { excluded += 1 }
            guard inDocumentText && excluded == 0 else { return }
            if element == "p" || element == "h" { paragraphDepth += 1 }
            // Repeated layout whitespace is collapsed; content is never truncated.
            if element == "s" { text += " " }
            if element == "tab" { text += "\t" }
            if element == "line-break" { text += "\n" }
        }, text: { characters in
            if inDocumentText && paragraphDepth > 0 && excluded == 0 { text += characters }
        }, end: { element in
            if inDocumentText && excluded == 0 {
                if element == "p" || element == "h" { paragraphDepth -= 1; text += "\n" }
                if element == "table-cell" { text += "\t" }
                if element == "table-row" { text += "\n" }
            }
            if element == "tracked-changes" || element == "annotation" { excluded -= 1 }
            if element == "text" { inDocumentText = false }
            if element == "body" { inBody = false }
        })
        return try nonempty([ParsedPage(text: normalized(text))])
    }

    // MARK: - EPUB reading order

    struct EPUBItem {
        let href: String
        let mediaType: String
        let fallback: String?
    }

    static func epub(_ archive: Archive) throws -> [ParsedPage] {
        var packagePath: String?
        try xml(archive.member("META-INF/container.xml"), root: "container", start: { element, attributes in
            if element == "rootfile", packagePath == nil,
               attributes["media-type"] == "application/oebps-package+xml",
               let path = attributes["full-path"] {
                packagePath = try resolve(path, relativeTo: nil)
            }
        })
        guard let packagePath else { throw failure("EPUB 缺少可读取的 OPF 包描述。") }
        var manifest: [String: EPUBItem] = [:]
        var spine: [String] = []
        var inManifest = false, inSpine = false
        try xml(archive.member(packagePath), root: "package", start: { element, attributes in
            if element == "manifest" { inManifest = true }
            if element == "spine" { inSpine = true }
            if inManifest && element == "item" {
                guard let id = attributes["id"], let href = attributes["href"],
                      let mime = attributes["media-type"], manifest[id] == nil else {
                    throw failure("EPUB 资源清单缺少属性或包含重复标识。")
                }
                manifest[id] = EPUBItem(href: href, mediaType: mime, fallback: attributes["fallback"])
            }
            if inSpine && element == "itemref" {
                guard let id = attributes["idref"] else { throw failure("EPUB 阅读顺序缺少资源标识。") }
                spine.append(id)
            }
        }, end: { element in
            if element == "manifest" { inManifest = false }
            if element == "spine" { inSpine = false }
        })
        var pages: [ParsedPage] = []
        for id in spine {
            try Task.checkCancellation()
            var current = id
            var visited = Set<String>()
            var text = ""
            while true {
                try Task.checkCancellation()
                guard visited.insert(current).inserted, let item = manifest[current] else {
                    throw failure("EPUB 阅读顺序引用缺失资源，或存在循环备用资源。")
                }
                let path = try resolve(item.href, relativeTo: packagePath)
                guard archive.contains(path), !path.hasSuffix("/") else {
                    throw failure("EPUB 阅读顺序引用的资源不存在：\(path)。")
                }
                if ["application/xhtml+xml", "text/html", "text/plain"].contains(item.mediaType) {
                    let raw = try decodeText(archive.member(path))
                    try validatePlainText(raw)
                    text = try item.mediaType == "text/plain" ? normalized(raw) : htmlText(raw)
                    break
                }
                if let fallback = item.fallback { current = fallback; continue }
                // Image/audio spine entries have no text layer. Keep their place.
                if item.mediaType.hasPrefix("image/") || item.mediaType.hasPrefix("audio/") ||
                    item.mediaType.hasPrefix("video/") { break }
                throw failure("EPUB 包含尚不支持的正文类型：\(item.mediaType)。")
            }
            pages.append(ParsedPage(text: text))
        }
        return try nonempty(pages)
    }
}

private extension DocumentTextExtractor {
    // MARK: - XML without entity expansion or external access

    static func xml(
        _ data: Data, root: String,
        start: @escaping (String, [String: String]) throws -> Void = { _, _ in },
        text: @escaping (String) throws -> Void = { _ in },
        end: @escaping (String) throws -> Void = { _ in }
    ) throws {
        try Task.checkCancellation()
        try checkXMLDeclarations(data)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let delegate = XMLReader(root: root, start: start, text: text, end: end)
        parser.delegate = delegate
        let succeeded = parser.parse()
        try Task.checkCancellation()
        if let error = delegate.error { throw error }
        guard succeeded, delegate.sawRoot else {
            throw failure("XML 正文损坏或无法解析（第 \(parser.lineNumber) 行）。")
        }
    }

    /// Foundation can omit entity-declaration callbacks when resolution is off.
    /// Check declarations before invoking it, so unavailable entities never turn
    /// into silently missing source text. Comments and CDATA remain literal.
    static func checkXMLDeclarations(_ data: Data) throws {
        let source = try decodeText(data)
        let input = source.unicodeScalars
        var index = input.startIndex
        var steps = 0
        func advance() throws {
            steps += 1
            if steps.isMultiple(of: 4_096) { try Task.checkCancellation() }
            input.formIndex(after: &index)
        }
        func skip(until terminator: String) throws {
            while index < input.endIndex {
                if source[index...].hasPrefix(terminator) {
                    for _ in terminator.unicodeScalars { try advance() }
                    return
                }
                try advance()
            }
        }
        while index < input.endIndex {
            if input[index] == "<" {
                if source[index...].hasPrefix("<!--") {
                    for _ in 0..<4 { try advance() }
                    try skip(until: "-->")
                    continue
                }
                if source[index...].hasPrefix("<![CDATA[") {
                    for _ in 0..<9 { try advance() }
                    try skip(until: "]]>")
                    continue
                }
                if source[index...].hasPrefix("<!ENTITY") {
                    throw failure("XML 含自定义实体声明，拒绝展开或读取。")
                }
                if source[index...].hasPrefix("<!DOCTYPE") {
                    var quote: UnicodeScalar?
                    while index < input.endIndex {
                        let scalar = input[index]
                        if let current = quote {
                            if scalar == current { quote = nil }
                        } else if scalar == "\"" || scalar == "'" {
                            quote = scalar
                        } else if scalar == "[" {
                            throw failure("XML 含 DTD 内部子集，拒绝自定义实体和默认属性展开。")
                        } else if scalar == ">" {
                            try advance()
                            break
                        }
                        try advance()
                    }
                    continue
                }
            }
            if input[index] == "&" {
                try advance()
                let start = index
                while index < input.endIndex && input[index] != ";" &&
                    input[index] != "<" && input[index] != "&" && !input[index].properties.isWhitespace {
                    try advance()
                }
                if index < input.endIndex && input[index] == ";" {
                    let entity = String(input[start..<index])
                    guard entity.hasPrefix("#") || ["amp", "lt", "gt", "quot", "apos"].contains(entity) else {
                        throw failure("XML 引用了自定义实体，拒绝外部读取或丢失文字的导入。")
                    }
                    try advance()
                }
                continue
            }
            try advance()
        }
        try Task.checkCancellation()
    }

    final class XMLReader: NSObject, XMLParserDelegate {
        let root: String
        let start: (String, [String: String]) throws -> Void
        let text: (String) throws -> Void
        let end: (String) throws -> Void
        var sawRoot = false
        var error: Error?

        init(root: String, start: @escaping (String, [String: String]) throws -> Void,
             text: @escaping (String) throws -> Void, end: @escaping (String) throws -> Void) {
            self.root = root; self.start = start; self.text = text; self.end = end
        }

        func action(_ parser: XMLParser, _ body: () throws -> Void) {
            guard error == nil else { return }
            do { try Task.checkCancellation(); try body() }
            catch { self.error = error; parser.abortParsing() }
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            action(parser) {
                if !sawRoot {
                    guard elementName == root else { throw failure("XML 正文类型不匹配，预期 \(root)。") }
                    sawRoot = true
                }
                try start(elementName, attributes)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            action(parser) { try text(string) }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            action(parser) {
                guard let string = String(data: CDATABlock, encoding: .utf8) else {
                    throw failure("XML CDATA 编码无效。")
                }
                try text(string)
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            action(parser) { try end(elementName) }
        }

        func rejectEntity(_ parser: XMLParser) {
            action(parser) { throw failure("XML 含自定义实体声明；为避免外部读取和实体展开，拒绝导入。") }
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            rejectEntity(parser)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            rejectEntity(parser)
        }

        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?, notationName: String?) {
            rejectEntity(parser)
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            rejectEntity(parser)
            return nil
        }
    }
}

private extension DocumentTextExtractor {
    // MARK: - Inert HTML tokenizer (no browser, importer, URL loader or script)

    static func htmlText(_ source: String) throws -> String {
        let input = source.unicodeScalars
        var position = input.startIndex
        var steps = 0
        var output = ""
        var hidden: [String] = []
        var preformatted = 0
        var pendingSpace = false
        let hiddenTags: Set<String> = ["head", "script", "style", "template"]
        let blocks: Set<String> = [
            "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt",
            "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6",
            "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table", "tr", "ul"
        ]
        func advance(_ index: inout String.UnicodeScalarView.Index) throws {
            steps += 1
            if steps.isMultiple(of: 4_096) { try Task.checkCancellation() }
            input.formIndex(after: &index)
        }
        func boundary(_ separator: String) {
            pendingSpace = false
            if !output.isEmpty && !output.hasSuffix(separator) { output += separator }
        }
        func appendText(_ value: String) throws {
            for scalar in try htmlEntities(value).unicodeScalars {
                steps += 1
                if steps.isMultiple(of: 4_096) { try Task.checkCancellation() }
                if preformatted > 0 {
                    output.unicodeScalars.append(scalar)
                } else if scalar.properties.isWhitespace {
                    pendingSpace = true
                } else {
                    if pendingSpace && !output.isEmpty &&
                        !(output.unicodeScalars.last?.properties.isWhitespace ?? true) { output += " " }
                    pendingSpace = false
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        while position < input.endIndex {
            try Task.checkCancellation()
            if input[position] != "<" {
                let start = position
                while position < input.endIndex && input[position] != "<" { try advance(&position) }
                if hidden.isEmpty { try appendText(String(input[start..<position])) }
                continue
            }
            // Raw script/style text may contain `a<b` or quoted fake tags.
            // Only the matching end tag has markup meaning in these elements.
            if let current = hidden.last, current == "script" || current == "style" {
                let ending = "</" + current
                let prefix = source[position...].prefix(ending.count).lowercased()
                let afterName = input.index(position, offsetBy: ending.count, limitedBy: input.endIndex)
                let isEnd = prefix == ending && afterName != nil && afterName! < input.endIndex &&
                    (input[afterName!] == ">" || input[afterName!] == "/" || input[afterName!].properties.isWhitespace)
                if !isEnd { try advance(&position); continue }
            }
            let opening = position
            var cursor = input.index(after: position)
            guard cursor < input.endIndex else {
                if hidden.isEmpty { try appendText("<") }
                break
            }
            let comment = source[opening...].hasPrefix("<!--")
            let declaration = input[cursor] == "!" || input[cursor] == "?"
            let closing = input[cursor] == "/"
            if closing { try advance(&cursor) }
            let nameStart = cursor
            while cursor < input.endIndex {
                let value = input[cursor].value
                guard (65...90).contains(value) || (97...122).contains(value) ||
                    (48...57).contains(value) || value == 58 || value == 45 else { break }
                try advance(&cursor)
            }
            let name = String(input[nameStart..<cursor]).lowercased()
            if !declaration && name.isEmpty {
                if hidden.isEmpty { try appendText("<") }
                try advance(&position)
                continue
            }
            var quote: UnicodeScalar?
            var subsetDepth = 0
            var terminated = false
            while cursor < input.endIndex {
                let scalar = input[cursor]
                if comment {
                    if source[cursor...].hasPrefix("-->") {
                        for _ in 0..<3 { try advance(&cursor) }
                        terminated = true
                        break
                    }
                } else if let currentQuote = quote {
                    if scalar == currentQuote { quote = nil }
                } else if scalar == "\"" || scalar == "'" {
                    quote = scalar
                } else if declaration && scalar == "[" {
                    subsetDepth += 1
                } else if declaration && scalar == "]" && subsetDepth > 0 {
                    subsetDepth -= 1
                } else if scalar == ">" && subsetDepth == 0 {
                    try advance(&cursor)
                    terminated = true
                    break
                }
                try advance(&cursor)
            }
            guard terminated else { throw failure("HTML/XHTML 含未结束的标记。") }
            let closingBracket = input.index(before: cursor)
            let selfClosing = closingBracket > opening && input[input.index(before: closingBracket)] == "/"
            position = cursor
            if declaration { continue }
            if let current = hidden.last {
                if closing && name == current { hidden.removeLast() }
                else if !["script", "style"].contains(current), !closing, !selfClosing, hiddenTags.contains(name) {
                    hidden.append(name)
                }
                continue
            }
            if !closing && hiddenTags.contains(name) {
                if !selfClosing { hidden.append(name) }
                continue
            }
            if blocks.contains(name) { boundary("\n") }
            if closing && (name == "td" || name == "th") { boundary("\t") }
            if name == "pre" { preformatted = closing ? max(0, preformatted - 1) : preformatted + 1 }
        }
        try Task.checkCancellation()
        return try normalized(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func htmlEntities(_ source: String) throws -> String {
        let named = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
            "copy": "©", "reg": "®", "trade": "™", "ndash": "–", "mdash": "—", "hellip": "…",
            "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
            "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "times": "×", "divide": "÷",
            "laquo": "«", "raquo": "»", "shy": "\u{AD}", "ensp": "\u{2002}", "emsp": "\u{2003}",
            "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}",
            "rlm": "\u{200F}", "eacute": "é", "Eacute": "É", "auml": "ä", "ouml": "ö",
            "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß"
        ]
        let scalars = source.unicodeScalars
        var result = ""
        var index = scalars.startIndex
        var steps = 0
        while index < scalars.endIndex {
            steps += 1
            if steps.isMultiple(of: 4_096) { try Task.checkCancellation() }
            if scalars[index] == "&" {
                let start = scalars.index(after: index)
                var end = start
                while end < scalars.endIndex && scalars[end] != ";" &&
                    scalars[end] != "&" && scalars[end] != "<" && !scalars[end].properties.isWhitespace {
                    steps += 1
                    if steps.isMultiple(of: 4_096) { try Task.checkCancellation() }
                    scalars.formIndex(after: &end)
                }
                if end < scalars.endIndex && scalars[end] == ";" {
                    let entity = String(scalars[start..<end])
                    var replacement = named[entity]
                    if entity.hasPrefix("#") {
                        let hex = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                        if let number = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                           let scalar = UnicodeScalar(number), number != 0 {
                            replacement = String(scalar)
                        }
                    }
                    if let replacement {
                        result += replacement
                        index = scalars.index(after: end)
                        continue
                    }
                }
            }
            result.unicodeScalars.append(scalars[index])
            scalars.formIndex(after: &index)
        }
        return result
    }
}

private extension DocumentTextExtractor {
    // MARK: - ZIP directory and read-only member decompression

    /// Read the central directory ourselves: line-based `unzip -Z1` output cannot
    /// unambiguously represent file names containing newlines or duplicate names.
    /// ZIP64 is accepted; no member count or uncompressed-size budget is imposed.
    final class Archive {
        let url: URL
        var entries: [String: UInt16] = [:]

        init(url: URL) throws {
            self.url = url
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard size >= 22 else { throw failure("ZIP 容器不完整。") }
            // 22-byte EOCD plus the ZIP specification's UInt16 comment length.
            let tailSize = Int(min(size, 22 + UInt64(UInt16.max)))
            try handle.seek(toOffset: size - UInt64(tailSize))
            let tail = try Self.readExactly(handle, count: tailSize)
            var eocd: Int?
            for offset in stride(from: tail.count - 22, through: 0, by: -1) {
                if offset.isMultiple(of: 4_096) { try Task.checkCancellation() }
                if Self.integer(tail, offset, 4) == 0x06054B50,
                   offset + 22 + Int(Self.integer(tail, offset + 20, 2)) == tail.count {
                    eocd = offset
                    break
                }
            }
            guard let eocd else { throw failure("ZIP 缺少有效的中央目录。") }
            guard Self.integer(tail, eocd + 4, 2) == 0, Self.integer(tail, eocd + 6, 2) == 0 else {
                throw failure("分卷 ZIP 文档需要先合并为一个文件。")
            }
            var count = Self.integer(tail, eocd + 10, 2)
            var directorySize = Self.integer(tail, eocd + 12, 4)
            var directoryOffset = Self.integer(tail, eocd + 16, 4)
            var directoryBoundary = size - UInt64(tailSize) + UInt64(eocd)
            if count == UInt16.max || directorySize == UInt32.max || directoryOffset == UInt32.max {
                guard directoryBoundary >= 20 else { throw failure("ZIP64 目录定位记录缺失。") }
                try handle.seek(toOffset: directoryBoundary - 20)
                let locator = try Self.readExactly(handle, count: 20)
                guard Self.integer(locator, 0, 4) == 0x07064B50,
                      Self.integer(locator, 4, 4) == 0, Self.integer(locator, 16, 4) == 1 else {
                    throw failure("ZIP64 目录定位记录无效或属于分卷文档。")
                }
                let offset = Self.integer(locator, 8, 8)
                guard offset <= directoryBoundary - 20, directoryBoundary - 20 - offset >= 56 else {
                    throw failure("ZIP64 目录超出文件。")
                }
                try handle.seek(toOffset: offset)
                let record = try Self.readExactly(handle, count: 56)
                guard Self.integer(record, 0, 4) == 0x06064B50,
                      Self.integer(record, 4, 8) >= 44,
                      Self.integer(record, 4, 8) <= directoryBoundary - 20 - offset - 12,
                      Self.integer(record, 16, 4) == 0, Self.integer(record, 20, 4) == 0,
                      Self.integer(record, 24, 8) == Self.integer(record, 32, 8) else {
                    throw failure("ZIP64 目录记录无效。")
                }
                count = Self.integer(record, 32, 8)
                directorySize = Self.integer(record, 40, 8)
                directoryOffset = Self.integer(record, 48, 8)
                directoryBoundary = offset
            } else if Self.integer(tail, eocd + 8, 2) != count {
                throw failure("ZIP 目录的文件计数不一致。")
            }
            guard directoryOffset <= directoryBoundary,
                  directorySize <= directoryBoundary - directoryOffset,
                  count <= directorySize / 46 else { throw failure("ZIP 目录长度或文件计数无效。") }
            var cursor = directoryOffset
            let directoryEnd = directoryOffset + directorySize
            try handle.seek(toOffset: cursor)
            var index: UInt64 = 0
            while index < count {
                try Task.checkCancellation()
                guard cursor <= directoryEnd, directoryEnd - cursor >= 46 else {
                    throw failure("ZIP 中央目录被截断。")
                }
                let entry = try Self.readExactly(handle, count: 46)
                guard Self.integer(entry, 0, 4) == 0x02014B50 else { throw failure("ZIP 目录成员无效。") }
                let nameLength = Int(Self.integer(entry, 28, 2))
                let extraLength = Int(Self.integer(entry, 30, 2))
                let commentLength = Int(Self.integer(entry, 32, 2))
                let length = UInt64(46 + nameLength + extraLength + commentLength)
                guard length <= directoryEnd - cursor else { throw failure("ZIP 成员路径被截断。") }
                let nameBytes = try Self.readExactly(handle, count: nameLength)
                // Office package parts use URI/UTF-8 names. Never guess a lossy
                // spelling and risk selecting a different member in `unzip`.
                guard let name = String(data: nameBytes, encoding: .utf8), !name.isEmpty,
                      !name.contains("\0"), !name.contains("\n"), !name.contains("\r"),
                      entries[name] == nil else {
                    throw failure("ZIP 成员名不是唯一且有效的 UTF-8 路径。")
                }
                entries[name] = UInt16(Self.integer(entry, 8, 2))
                cursor += length
                try handle.seek(toOffset: cursor)
                index += 1
            }
        }

        func contains(_ name: String) -> Bool { entries[name] != nil }

        func member(_ name: String) throws -> Data {
            try Task.checkCancellation()
            guard let flags = entries[name], !name.hasSuffix("/") else {
                throw failure("ZIP 文档缺少正文成员：\(name)。")
            }
            guard flags & 1 == 0 else { throw failure("ZIP 正文成员已加密，请解锁并另存后导入。") }
            // Info-ZIP interprets member arguments as glob patterns even without
            // a shell. Escape every metacharacter to read exactly one member.
            var pattern = ""
            for character in name {
                try Task.checkCancellation()
                if "*?[]\\".contains(character) { pattern.append("\\") }
                if pattern.isEmpty && character == "-" { pattern += "[-]" }
                else { pattern.append(character) }
            }
            return try Self.unzip(url: url, memberPattern: pattern)
        }

        static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                try Task.checkCancellation()
                guard let bytes = try handle.read(upToCount: min(65_536, count - result.count)), !bytes.isEmpty else {
                    throw failure("ZIP 容器在读取期间意外结束。")
                }
                result.append(bytes)
            }
            return result
        }

        static func integer(_ data: Data, _ offset: Int, _ width: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<width { value |= UInt64(data[offset + index]) << (index * 8) }
            return value
        }

        static func unzip(url: URL, memberPattern: String) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", "-qq", url.path, memberPattern]
            // Do not inherit UNZIP/UNZIPOPT options, credentials, or a password
            // prompt. Only selected member bytes are emitted; nothing is extracted.
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw failure("无法建立 ZIP 读取管道。") }
            try process.run()
            try? pipe.fileHandleForWriting.close()
            defer {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try? pipe.fileHandleForReading.close()
            }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try Task.checkCancellation()
                let received = Darwin.read(descriptor, &buffer, buffer.count)
                if received > 0 {
                    result.append(contentsOf: buffer.prefix(received))
                    continue
                }
                if received == 0 { break }
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else { throw failure("读取 ZIP 正文失败。") }
                var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let status = poll(&event, 1, 100)
                guard status >= 0 || errno == EINTR else { throw failure("等待 ZIP 正文失败。") }
            }
            // There is no output left to drain, but cancellation must still be
            // observed while the child finishes (including CRC verification).
            while process.isRunning {
                try Task.checkCancellation()
                _ = poll(nil, 0, 10)
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw failure("ZIP 正文解压失败；文件可能损坏、加密或使用系统不支持的压缩方式。")
            }
            return result
        }
    }
}
