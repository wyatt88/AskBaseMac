import AppKit
import CoreGraphics
import CoreText
import Darwin
import Foundation
import PDFKit
import XCTest
@testable import AskBaseCore

final class ImporterTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AskBaseImporterTests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }

    func testChineseUTF8AndUTF16AreDecodedWithoutLoss() throws {
        let content = "中文资料 English 👩🏽‍💻 e\u{301}\r\n第二行\r第三行"
        let expected = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let encodings: [(String, Data)] = [
            ("utf8.txt", Data(content.utf8)),
            ("utf8bom.md", Data([0xEF, 0xBB, 0xBF]) + Data(content.utf8)),
            ("little.txt", Data([0xFF, 0xFE]) + (try XCTUnwrap(content.data(using: .utf16LittleEndian)))),
            ("big.txt", Data([0xFE, 0xFF]) + (try XCTUnwrap(content.data(using: .utf16BigEndian)))),
            ("little-no-bom.txt", try XCTUnwrap(content.data(using: .utf16LittleEndian))),
            ("big-no-bom.txt", try XCTUnwrap(content.data(using: .utf16BigEndian)))
        ]
        for (filename, data) in encodings {
            let url = try file(filename, data: data)
            XCTAssertEqual(try DocumentImporter.parse(url: url), [ParsedPage(text: expected)], filename)
        }
        let pureChinese = "纯中文资料无需英文内容"
        let pure = try file("chinese.txt", data: Data([0xFE, 0xFF]) + XCTUnwrap(pureChinese.data(using: .utf16BigEndian)))
        XCTAssertEqual(try DocumentImporter.parse(url: pure).first?.text, pureChinese)
    }

    func testMalformedEncodingsBinaryAndEmptyFilesGiveExplicitFailures() throws {
        let invalid: [(String, Data)] = [
            ("empty.txt", Data()), ("white.md", Data(" \t\r\n".utf8)),
            ("binary.txt", Data([0x41, 0x00, 0xFF, 0x01, 0x00])),
            ("control.txt", Data("abc\u{1}def".utf8)),
            ("bad-utf8.txt", Data([0xC3, 0x28, 0xFF])),
            ("truncated-utf16.txt", Data([0xFF, 0xFE, 0x41])),
            ("high-surrogate.txt", Data([0xFF, 0xFE, 0x00, 0xD8])),
            ("low-surrogate.txt", Data([0xFE, 0xFF, 0xDC, 0x00])),
            ("utf32.txt", Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00])),
            ("broken.pdf", Data("This is not a PDF".utf8)),
            ("unsupported.exe", Data("executable".utf8))
        ]
        for (filename, data) in invalid {
            let url = try file(filename, data: data)
            XCTAssertThrowsError(try DocumentImporter.parse(url: url), filename) { error in
                XCTAssertTrue(error is AskBaseError)
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    func testSizeAndExtractedTextLimitsAreEnforced() throws {
        let oversized = try file("large.txt", data: Data())
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(DocumentImporter.maximumFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try DocumentImporter.parse(url: oversized)) {
            XCTAssertTrue($0.localizedDescription.contains("32 MiB"))
        }
        let tooMuchText = try file("text.txt", data: Data(repeating: 0x61, count: DocumentImporter.maximumTextUnits + 1))
        XCTAssertThrowsError(try DocumentImporter.parse(url: tooMuchText)) {
            XCTAssertTrue($0.localizedDescription.contains("200 万"))
        }
    }

    func testPDFExtractionPreservesOriginalPageNumbersIncludingBlankPages() throws {
        let url = try file("pages.pdf", data: pdf(pages: ["Page one 中文资料", "", "Page three 末页"]))
        let pages = try DocumentImporter.parse(url: url)
        XCTAssertEqual(pages.map(\.page), [1, 2, 3])
        XCTAssertTrue(pages[0].text.contains("Page one"))
        XCTAssertTrue(pages[0].text.contains("中文资料"))
        XCTAssertTrue(pages[1].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(pages[2].text.contains("末页"))
        let chunks = TextChunker.chunks(pages: pages, documentID: "pdf", knowledgeBaseID: "test")
        XCTAssertEqual(chunks.map(\.page), [1, 3])
        XCTAssertEqual(chunks.map(\.ordinal), [0, 1])
    }

    func testImageOnlyAndBlankPDFsExplicitlyRequireTextOrOCR() throws {
        for (name, data) in [("image.pdf", try pdf(pages: [nil])), ("blank.pdf", try pdf(pages: [""]))] {
            let url = try file(name, data: data)
            XCTAssertThrowsError(try DocumentImporter.parse(url: url)) {
                XCTAssertTrue($0.localizedDescription.contains("OCR"))
            }
        }
    }

    func testEncryptedPDFAndPageLimitAreRejected() throws {
        let document = try XCTUnwrap(PDFDocument(data: pdf(pages: ["Secret"])))
        let encrypted = temporary.appendingPathComponent("encrypted.pdf")
        XCTAssertTrue(document.write(to: encrypted, withOptions: [.userPasswordOption: "fixture-secret",
                                                                   .ownerPasswordOption: "fixture-owner"]))
        XCTAssertThrowsError(try DocumentImporter.parse(url: encrypted)) {
            XCTAssertTrue($0.localizedDescription.contains("加密"))
        }
        let long = try file("too-many-pages.pdf",
                            data: pdf(pages: Array(repeating: "", count: DocumentImporter.maximumPDFPages + 1)))
        XCTAssertThrowsError(try DocumentImporter.parse(url: long)) {
            XCTAssertTrue($0.localizedDescription.contains("页上限"))
        }
    }

    func testPreparedCopiesHashWholeFileAndRemainIndependentOfSource() throws {
        let originals = temporary.appendingPathComponent("Library/Originals")
        let content = Data("首行\r\n中文内容，保留原始字节。".utf8)
        let a = try file("original.TXT", data: content)
        let b = try file("renamed.md", data: content)
        let first = try DocumentImporter.prepare(url: a, knowledgeBaseID: "base", originalsRoot: originals)
        let second = try DocumentImporter.prepare(url: b, knowledgeBaseID: "base", originalsRoot: originals)
        XCTAssertEqual(first.document.contentHash, second.document.contentHash)
        XCTAssertEqual(first.document.contentHash.count, 64)
        XCTAssertNotEqual(first.document.id, second.document.id)
        XCTAssertNotEqual(first.document.relativePath, second.document.relativePath)
        XCTAssertEqual(first.document.byteCount, content.count)
        XCTAssertEqual(first.document.title, "original")
        XCTAssertEqual(first.document.fileName, "original.TXT")
        XCTAssertEqual(first.document.relativePath, "Originals/\(first.document.id).txt")
        XCTAssertEqual(first.document.status, .indexing)
        XCTAssertTrue(first.chunks.allSatisfy { $0.embedding.isEmpty && $0.encoderSignature.isEmpty })
        let storedURL = originals.appendingPathComponent("\(first.document.id).txt")
        XCTAssertEqual(try Data(contentsOf: storedURL), content)
        try Data("原文件已修改".utf8).write(to: a)
        XCTAssertEqual(try Data(contentsOf: storedURL), content)
        XCTAssertEqual(try DocumentImporter.parse(url: storedURL).first?.text, "首行\n中文内容，保留原始字节。")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: originals.path).contains {
            $0.hasPrefix(".askbase-")
        })
    }

    func testRejectedPreparationLeavesNoManagedCopy() throws {
        let originals = temporary.appendingPathComponent("Originals")
        let invalid = try file("bad.txt", data: Data([0xFF, 0x01, 0xFE]))
        XCTAssertThrowsError(try DocumentImporter.prepare(url: invalid, knowledgeBaseID: "base", originalsRoot: originals))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originals.path))
    }

    func testDirectoryExpansionIsDeduplicatedAndSkipsHiddenPackagesAndSymlinks() throws {
        let folder = temporary.appendingPathComponent("Selection")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let first = try file("Selection/a.TXT", data: Data("甲".utf8))
        let second = try file("Selection/nested/b.swift", data: Data("let 中文 = true".utf8))
        _ = try file("Selection/.hidden.md", data: Data("忽略".utf8))
        _ = try file("Selection/unsupported.bin", data: Data([0x01]))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".hidden-dir"), withIntermediateDirectories: true)
        _ = try file("Selection/.hidden-dir/hidden.txt", data: Data("忽略目录".utf8))
        let outside = try file("outside.txt", data: Data("不得跟随".utf8))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("loop"), withDestinationURL: folder)
        let results = try DocumentImporter.expand([folder, first, folder.appendingPathComponent("nested")])
        XCTAssertEqual(Set(results.map(\.path)), Set([first.path, second.path]))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(try DocumentImporter.expand([folder.appendingPathComponent("link.txt")]), [])
    }

    func testDirectoryDepthAndBatchSizeFailInsteadOfSilentlyTruncating() throws {
        let selected = temporary.appendingPathComponent("Deep")
        var directory = selected
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<DocumentImporter.maximumDirectoryDepth + 1 {
            directory.appendPathComponent("level-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        try Data("太深".utf8).write(to: directory.appendingPathComponent("deep.txt"))
        XCTAssertThrowsError(try DocumentImporter.expand([selected])) {
            XCTAssertTrue($0.localizedDescription.contains("层"))
        }
        let url = try file("single.txt", data: Data("内容".utf8))
        XCTAssertThrowsError(try DocumentImporter.expand(Array(repeating: url, count: DocumentImporter.maximumFiles + 1)))
    }

    func testHiddenEntriesStillCountAgainstTraversalBudget() throws {
        let folder = temporary.appendingPathComponent("HiddenOnly")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<DocumentImporter.maximumVisitedEntries {
            let path = folder.appendingPathComponent(".hidden-\(index).txt").path
            guard FileManager.default.createFile(atPath: path, contents: Data()) else {
                throw AskBaseError.storage("无法创建临时遍历边界测试文件")
            }
        }
        XCTAssertThrowsError(try DocumentImporter.expand([folder])) {
            XCTAssertTrue($0.localizedDescription.contains("\(DocumentImporter.maximumVisitedEntries)"))
        }
    }

    func testSymlinkAndNamedPipeInputsAreRejectedWithoutBlockingOrFollowing() throws {
        let source = try file("target.txt", data: Data("真实内容".utf8))
        let link = temporary.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try DocumentImporter.parse(url: link))
        let pipe = temporary.appendingPathComponent("pipe.txt")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try DocumentImporter.parse(url: pipe))
        let originalsTarget = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: originalsTarget, withIntermediateDirectories: true)
        let originalsLink = temporary.appendingPathComponent("Originals")
        try FileManager.default.createSymbolicLink(at: originalsLink, withDestinationURL: originalsTarget)
        XCTAssertThrowsError(try DocumentImporter.prepare(url: source, knowledgeBaseID: "base", originalsRoot: originalsLink))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: originalsTarget.path).isEmpty)
    }

    func testRemoteURLsAreRejectedBeforeAnyRead() throws {
        for value in ["https://example.invalid/private.txt", "http://127.0.0.1:8871/file.txt"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertThrowsError(try DocumentImporter.parse(url: url))
            XCTAssertThrowsError(try DocumentImporter.expand([url]))
        }
    }

    func testUnicodeChunkBoundsOverlapAndCoverage() throws {
        let sentence = "中文English👨‍👩‍👧‍👦e\u{301}检索。"
        let text = String(repeating: sentence, count: 130)
        let chunks = TextChunker.chunks(pages: [ParsedPage(page: 7, text: text)],
                                        documentID: "doc", knowledgeBaseID: "base", maxCharacters: 83, overlap: 13)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 83 && !$0.text.isEmpty && $0.page == 7 })
        XCTAssertEqual(chunks.map(\.ordinal), Array(chunks.indices))
        XCTAssertEqual(Set(chunks.map(\.id)).count, chunks.count)
        var reconstructed = try XCTUnwrap(chunks.first).text
        for index in 1..<chunks.count {
            XCTAssertEqual(String(chunks[index - 1].text.suffix(13)), String(chunks[index].text.prefix(13)))
            reconstructed += String(chunks[index].text.dropFirst(13))
        }
        XCTAssertEqual(reconstructed, text)
        XCTAssertTrue(chunks.allSatisfy { $0.documentID == "doc" && $0.knowledgeBaseID == "base" })
    }

    func testChunkerKeepsPageBoundariesAndHandlesDegenerateParameters() throws {
        let pages = [ParsedPage(page: 1, text: "中文第一段"), ParsedPage(page: 2, text: "\n "),
                     ParsedPage(page: 3, text: "第二段文字")]
        let chunks = TextChunker.chunks(pages: pages, documentID: "d", knowledgeBaseID: "b")
        XCTAssertEqual(chunks.map(\.page), [1, 3])
        XCTAssertEqual(chunks.map(\.text), ["中文第一段", "第二段文字"])
        XCTAssertTrue(TextChunker.chunks(pages: pages, documentID: "d", knowledgeBaseID: "b", maxCharacters: 0).isEmpty)
        XCTAssertTrue(TextChunker.chunks(pages: pages, documentID: "d", knowledgeBaseID: "b", maxCharacters: -2).isEmpty)
        let single = [ParsedPage(text: "中文一二三四五六七八九十")]
        let extreme = TextChunker.chunks(pages: single, documentID: "d", knowledgeBaseID: "b",
                                         maxCharacters: 5, overlap: .max)
        XCTAssertTrue(extreme.allSatisfy { $0.text.count <= 5 })
        XCTAssertLessThanOrEqual(extreme.count, single[0].text.count)
        let unlimited = TextChunker.chunks(pages: single, documentID: "d", knowledgeBaseID: "b",
                                           maxCharacters: .max, overlap: -10)
        XCTAssertEqual(unlimited.map(\.text), single.map(\.text))
    }

    private func file(_ name: String, data: Data) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Quartz/CoreText produces deterministic local fixtures; nil means an image
    /// page, and an empty string means a blank page. No network or sample download.
    private func pdf(pages: [String?]) throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 500, height: 700)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            if let page, !page.isEmpty {
                let string = NSAttributedString(string: page, attributes: [.font: NSFont.systemFont(ofSize: 16)])
                let line = CTLineCreateWithAttributedString(string)
                context.textPosition = CGPoint(x: 30, y: 640)
                CTLineDraw(line, context)
            } else if page == nil {
                let pixels = Data(repeating: 128, count: 16 * 16 * 4)
                let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
                let image = try XCTUnwrap(CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32,
                                                 bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                context.draw(image, in: CGRect(x: 30, y: 30, width: 400, height: 500))
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
