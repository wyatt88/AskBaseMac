import AppKit
import CoreGraphics
import CoreText
import Darwin
import Foundation
import PDFKit
import XCTest
@testable import AskBaseCore

final class DocumentFormatTests: XCTestCase {
    private var temporary: URL!
    private let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private let sheetNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private let presentationNamespace = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private let drawingNamespace = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private let relationNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AskBaseFormats-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }

    func testTextUsesContentWithUnknownMissingAndMisleadingExtensions() throws {
        let text = "无扩展名也能读取。\r\nEnglish 👩🏽‍💻\r下一行"
        for hint in ["README", "notes.unlisted", "not-really.pdf", "not-really.docx", "notes.EXE"] {
            XCTAssertEqual(try parse(Data(text.utf8), hint: hint),
                           [ParsedPage(text: "无扩展名也能读取。\nEnglish 👩🏽‍💻\n下一行")], hint)
        }
        let mention = "PDF 文件以 %PDF-1.7 开头。"
        XCTAssertEqual(try parse(Data(mention.utf8)).first?.text, mention)
    }

    func testUTF8UTF16UTF32AreStrictAndLossless() throws {
        let text = "中文资料 English 👩🏽‍💻 e\u{301} 😀\r\n第二行\r第三行"
        let expected = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let encodings: [(String.Encoding, [UInt8])] = [
            (.utf8, []), (.utf8, [0xEF, 0xBB, 0xBF]),
            (.utf16LittleEndian, [0xFF, 0xFE]), (.utf16BigEndian, [0xFE, 0xFF]),
            (.utf16LittleEndian, []), (.utf16BigEndian, []),
            (.utf32LittleEndian, [0xFF, 0xFE, 0, 0]), (.utf32BigEndian, [0, 0, 0xFE, 0xFF]),
            (.utf32LittleEndian, []), (.utf32BigEndian, [])
        ]
        for (encoding, bom) in encodings {
            let data = Data(bom) + (try XCTUnwrap(text.data(using: encoding)))
            XCTAssertEqual(try parse(data, hint: "source.unknown"), [ParsedPage(text: expected)], "\(encoding)")
        }
        for encoding in [String.Encoding.utf32LittleEndian, .utf32BigEndian] {
            let chinese = "纯中文😀"
            XCTAssertEqual(try parse(XCTUnwrap(chinese.data(using: encoding))).first?.text, chinese)
        }
    }

    func testMalformedUnicodeBinaryAndInvisibleDocumentsAreRejected() throws {
        let invalid: [Data] = [
            Data(), Data(" \n\t\r".utf8), Data("\u{200B}\u{FEFF}\u{0301}".utf8),
            Data([0xC3, 0x28]), Data([0xED, 0xA0, 0x80]),
            Data([0xFF, 0xFE, 0x41]), Data([0xFF, 0xFE, 0, 0xD8]),
            Data([0xFE, 0xFF, 0xDC, 0]), Data([0xFF, 0xFE, 0, 0, 0x41]),
            Data([0, 0, 0xFE, 0xFF, 0, 0x11, 0, 0]),
            Data([0xFF, 0xFE, 0, 0, 0, 0xD8, 0, 0]),
            Data("hello\u{0}world".utf8), Data("hello\u{1}world".utf8),
            Data("hello\u{0085}world".utf8), Data([0xEF, 0xB7, 0x90]),
            Data([0x41, 0, 0xFF, 1, 0]), Data(repeating: 0, count: 32),
            Data([0x89, 0x50, 0x4E, 0x47]), Data("GIF89a".utf8),
            Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        ]
        for (index, data) in invalid.enumerated() {
            XCTAssertThrowsError(try parse(data, hint: "disguised.txt"), "fixture \(index)") {
                XCTAssertTrue($0 is AskBaseError)
                XCTAssertFalse($0.localizedDescription.isEmpty)
            }
        }
    }

    func testTextBeyondPreviousLengthLimitIsNotTruncated() throws {
        let text = String(repeating: "a", count: 2_000_123) + "末尾"
        let result = try parse(Data(text.utf8), hint: "large.arbitrary")
        XCTAssertEqual(result.first?.text, text)
    }

    func testPDFContentIsRecognizedWithoutExtensionAndPreservesBlankPageNumbers() throws {
        let pages = try parse(pdf(["第一页 First", "", "第三页 Third"]), hint: "scan.unlisted")
        XCTAssertEqual(pages.map(\.page), [1, 2, 3])
        XCTAssertTrue(pages[0].text.contains("第一页"))
        XCTAssertTrue(pages[1].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(pages[2].text.contains("Third"))
        let chunks = TextChunker.chunks(pages: pages, documentID: "synthetic", knowledgeBaseID: "synthetic")
        XCTAssertEqual(chunks.map(\.page), [1, 3])
        XCTAssertEqual(chunks.map(\.ordinal), [0, 1])
    }

    func testBlankLockedAndBrokenPDFsAreNotIndexedAsText() throws {
        XCTAssertThrowsError(try parse(pdf([""]))) { XCTAssertTrue($0.localizedDescription.contains("OCR")) }
        XCTAssertThrowsError(try parse(Data("%PDF-1.7\nbroken".utf8)))
        let locked = try XCTUnwrap(PDFDocument(data: pdf(["Secret"])))
        let url = temporary.appendingPathComponent("locked.snapshot")
        XCTAssertTrue(locked.write(to: url, withOptions: [.userPasswordOption: "fixture",
                                                        .ownerPasswordOption: "fixture-owner"]))
        XCTAssertThrowsError(try DocumentTextExtractor.parse(url: url, originalFilename: "no-extension")) {
            XCTAssertTrue($0.localizedDescription.contains("加密"))
        }
    }

    func testRTFUsesItsSignatureAndExtractsUnicodeAndParagraphs() throws {
        let rtf = #"{\rtf1\ansi\ansicpg1252 First \b bold\b0\par \u20013?\u25991? \u-10179?\u-8704?}"#
        let result = try XCTUnwrap(parse(Data(rtf.utf8), hint: "notes.bin").first)
        XCTAssertNil(result.page)
        XCTAssertTrue(result.text.contains("First bold"))
        XCTAssertTrue(result.text.contains("\n"))
        XCTAssertTrue(result.text.contains("中文 😀"))
        XCTAssertFalse(result.text.contains("\\rtf"))
    }

    func testDOCXExtractsRunsParagraphsTablesAndExcludesDeletedInstructions() throws {
        let body = """
        <w:p><w:r><w:t>第一段 </w:t></w:r><w:r><w:t>bold &amp; 中文</w:t></w:r>
        <w:r><w:tab/><w:t>制表</w:t><w:br/><w:t>换行</w:t></w:r>
        <w:del><w:r><w:t>DELETED SENTINEL</w:t></w:r></w:del>
        <w:r><w:instrText>FIELD INSTRUCTION</w:instrText></w:r></w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell one</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Cell two</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """
        let result = try parse(zip([("word/document.xml", word(body))]), hint: "not-a-docx.xyz")
        let text = try XCTUnwrap(result.first?.text)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result.first?.page)
        XCTAssertTrue(text.contains("第一段 bold & 中文\t制表\n换行"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Cell one")?.lowerBound),
                          try XCTUnwrap(text.range(of: "Cell two")?.lowerBound))
        XCTAssertFalse(text.contains("DELETED"))
        XCTAssertFalse(text.contains("FIELD INSTRUCTION"))
    }

    func testDOCXRootRelationshipsAndLiteralWildcardMemberNames() throws {
        let type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
        let archive = zip([
            ("[Content_Types].xml", """
             <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
             <Override PartName="/texts/real[1]*.xml" ContentType="\(type)"/></Types>
             """),
            ("_rels/.rels", rels([("main", "officeDocument", "texts/real%5B1%5D%2A.xml", false)])),
            ("texts/real[1]*.xml", word("<w:p><w:r><w:t>Correct member</w:t></w:r></w:p>")),
            ("texts/real1decoy.xml", word("<w:p><w:r><w:t>DECOY MEMBER</w:t></w:r></w:p>"))
        ])
        let text = try XCTUnwrap(parse(archive, hint: "archive").first?.text)
        XCTAssertTrue(text.contains("Correct member"))
        XCTAssertFalse(text.contains("DECOY"))
    }

    func testDeflatedOfficeArchiveAndZIP64DirectoryAreAccepted() throws {
        let document = word("<w:p><w:r><w:t>\(String(repeating: "可压缩的正文。", count: 100))</w:t></w:r></w:p>")
        let input = temporary.appendingPathComponent("zip-input")
        try FileManager.default.createDirectory(at: input.appendingPathComponent("word"), withIntermediateDirectories: true)
        try Data(document.utf8).write(to: input.appendingPathComponent("word/document.xml"))
        let compressed = temporary.appendingPathComponent("deflated.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", compressed.path, "word/document.xml"]
        process.currentDirectoryURL = input
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = try Data(contentsOf: compressed)
        XCTAssertEqual(data[8], 8, "The fixture must exercise DEFLATE rather than stored ZIP.")
        try FileManager.default.removeItem(at: input)
        XCTAssertTrue(try XCTUnwrap(parse(data).first?.text).contains("可压缩的正文。"))
        XCTAssertTrue(try XCTUnwrap(parse(zip([("word/document.xml", document)], zip64: true)).first?.text)
            .contains("可压缩的正文。"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
    }

    func testXLSXPreservesWorkbookOrderAndExtractsStoredCellTypes() throws {
        let workbook = """
        <workbook xmlns="\(sheetNamespace)" xmlns:r="\(relationNamespace)">
        <sheets><sheet name="先看" sheetId="9" r:id="later"/><sheet name="后看" sheetId="1" r:id="earlier"/></sheets>
        </workbook>
        """
        let shared = """
        <sst xmlns="\(sheetNamespace)"><si><t></t></si><si><r><t>共享</t></r><r><t>文字</t></r>
        <rPh sb="0" eb="1"><t>PHONETIC</t></rPh></si></sst>
        """
        let cells = """
        <worksheet xmlns="\(sheetNamespace)"><sheetData><row r="2">
        <c r="A2" t="s"><v>0</v></c><c r="B2" t="s"><v>1</v></c>
        <c r="C2" t="inlineStr"><is><r><t>Inline </t></r><r><t>中文</t></r></is></c>
        <c r="D2"><v>42</v></c><c r="E2" t="b"><v>1</v></c>
        <c r="F2"><f>SUM(D1:D2)</f><v>43</v></c><c r="G2"><f>1+1</f></c>
        </row></sheetData></worksheet>
        """
        let archive = zip([
            ("xl/worksheets/sheet1.xml", sheet("Later in reading order")),
            ("xl/workbook.xml", workbook),
            ("xl/_rels/workbook.xml.rels", rels([
                ("earlier", "worksheet", "worksheets/sheet1.xml", false),
                ("strings", "sharedStrings", "strings/shared.xml", false),
                ("later", "worksheet", "/xl/worksheets/sheet9.xml", false)
            ])),
            ("xl/strings/shared.xml", shared), ("xl/worksheets/sheet9.xml", cells)
        ])
        let pages = try parse(archive, hint: "book.unknown")
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.map(\.page), [nil, nil])
        XCTAssertTrue(pages[0].text.hasPrefix("工作表：先看\n"))
        XCTAssertTrue(pages[0].text.contains("B2: 共享文字\tC2: Inline 中文\tD2: 42\tE2: TRUE\tF2: 43\tG2: =1+1"))
        XCTAssertFalse(pages[0].text.contains("PHONETIC"))
        XCTAssertTrue(pages[1].text.hasPrefix("工作表：后看\n"))
        XCTAssertTrue(pages[1].text.contains("Later in reading order"))
    }

    func testXLSXMissingSharedStringsOrExternalWorksheetFailsWholeDocument() throws {
        let workbook = """
        <workbook xmlns="\(sheetNamespace)" xmlns:r="\(relationNamespace)">
        <sheets><sheet name="A" sheetId="1" r:id="sheet"/></sheets></workbook>
        """
        for external in [false, true] {
            let archive = zip([
                ("xl/workbook.xml", workbook),
                ("xl/_rels/workbook.xml.rels", rels([
                    ("sheet", "worksheet", external ? "https://example.invalid/sheet.xml" : "worksheets/sheet.xml", external)
                ])),
                ("xl/worksheets/sheet.xml", """
                <worksheet xmlns="\(sheetNamespace)"><sheetData><row><c t="s"><v>999</v></c></row></sheetData></worksheet>
                """)
            ])
            XCTAssertThrowsError(try parse(archive))
        }
    }

    func testPPTXSlideRelationshipOrderAndBlankSlidesPreserveSourceNumbers() throws {
        let presentation = """
        <p:presentation xmlns:p="\(presentationNamespace)" xmlns:r="\(relationNamespace)">
        <p:sldIdLst><p:sldId id="300" r:id="ten"/><p:sldId id="301" r:id="blank"/>
        <p:sldId id="302" r:id="one"/></p:sldIdLst></p:presentation>
        """
        let archive = zip([
            ("ppt/slides/slide1.xml", slide("Last")),
            ("ppt/presentation.xml", presentation),
            ("ppt/_rels/presentation.xml.rels", rels([
                ("one", "slide", "slides/slide1.xml", false), ("blank", "slide", "slides/slide2.xml", false),
                ("ten", "slide", "slides/slide10.xml", false)
            ])),
            ("ppt/slides/slide2.xml", slide("")), ("ppt/slides/slide10.xml", slide("First 中文"))
        ])
        let pages = try parse(archive, hint: "presentation.data")
        XCTAssertEqual(pages.map(\.page), [1, 2, 3])
        XCTAssertTrue(pages[0].text.contains("First 中文"))
        XCTAssertTrue(pages[1].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(pages[2].text.contains("Last"))
    }

    func testODTParagraphsWhitespaceAndTableTextWithoutStyleMetadata() throws {
        let archive = zip([
            ("mimetype", "application/vnd.oasis.opendocument.text"),
            ("content.xml", """
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
            xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
            xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
            <office:automatic-styles><text:p>STYLE SENTINEL</text:p></office:automatic-styles>
            <office:body><office:text><text:h>标题</text:h><text:p>甲<text:s text:c="3"/>乙<text:tab/>丙<text:line-break/>丁</text:p>
            <table:table><table:table-row><table:table-cell><text:p>单元格</text:p></table:table-cell></table:table-row></table:table>
            </office:text></office:body></office:document-content>
            """)
        ])
        let page = try XCTUnwrap(parse(archive).first)
        XCTAssertNil(page.page)
        XCTAssertTrue(page.text.contains("标题\n甲 乙\t丙\n丁"))
        XCTAssertTrue(page.text.contains("单元格"))
        XCTAssertFalse(page.text.contains("STYLE SENTINEL"))
    }

    func testEPUBUsesSpineOrderAndInertHTMLWithEntitiesAndResources() throws {
        let archive = epubArchive(first: """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "https://example.invalid/external.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>HEAD SENTINEL</title>
        <link rel="stylesheet" href="https://example.invalid/style.css"/><style>CSS SENTINEL</style></head>
        <body><p>First&nbsp;chapter &amp; &#x1F600;</p>
        <script>const x = "<style>"; if(a<b) { SCRIPT SENTINEL }</script>
        <script src="https://example.invalid/empty-script.js"/><p>正文</p>
        <img src="https://example.invalid/image.png"/><iframe src="https://example.invalid/frame"></iframe>
        </body></html>
        """, second: "<html><body><h1>Second in filename, first in spine</h1><p>第二章</p></body></html>")
        let pages = try parse(archive, hint: "book.anything")
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.map(\.page), [nil, nil])
        XCTAssertTrue(pages[0].text.contains("Second in filename, first in spine\n第二章"))
        XCTAssertTrue(pages[1].text.contains("First chapter & 😀\n正文"))
        for sentinel in ["HEAD SENTINEL", "CSS SENTINEL", "SCRIPT SENTINEL", "example.invalid"] {
            XCTAssertFalse(pages.map(\.text).joined().contains(sentinel))
        }
    }

    func testHTMLFragmentUsesFilenameHintAndNeverExpandsCustomEntities() throws {
        let source = """
        <!DOCTYPE html [<!ENTITY secret SYSTEM "file:///not-a-readable-document">]>
        <p>甲 <b>乙</b> &lt;literal&gt; &copy; &#20013;</p><!-- HIDDEN --><p>&secret;</p>
        """
        let text = try XCTUnwrap(parse(Data(source.utf8), hint: "web.html").first?.text)
        XCTAssertEqual(text, "甲 乙 <literal> © 中\n&secret;")
        XCTAssertFalse(text.contains("HIDDEN"))
        XCTAssertThrowsError(try parse(Data("<html><head><script>only code</script></head><body> </body></html>".utf8)))
    }

    func testXMLExternalEntitiesCannotReadLocalFilesOrUseNetwork() throws {
        let secret = temporary.appendingPathComponent("private-fixture.txt")
        try Data("MUST NEVER BE INDEXED".utf8).write(to: secret)
        let probe = try OfflineHTTPProbe()
        defer { probe.stop() }
        for target in [secret.absoluteString, probe.url] {
            let document = """
            <?xml version="1.0"?>
            <!DOCTYPE w:document [<!ENTITY leak SYSTEM "\(target)">]>
            <w:document xmlns:w="\(wordNamespace)"><w:body><w:p><w:r><w:t>&leak;</w:t></w:r></w:p></w:body></w:document>
            """
            XCTAssertThrowsError(try parse(zip([("word/document.xml", document)]))) {
                XCTAssertTrue($0.localizedDescription.contains("实体"), $0.localizedDescription)
            }
        }
        let externalDTD = """
        <!DOCTYPE w:document SYSTEM "\(probe.url)">
        \(word("<w:p><w:r><w:t>Safe literal text</w:t></w:r></w:p>"))
        """
        XCTAssertTrue(try XCTUnwrap(parse(zip([("word/document.xml", externalDTD)])).first?.text)
            .contains("Safe literal text"))
        XCTAssertEqual(probe.connectionCount, 0)
    }

    func testXMLInternalEntityExpansionAndMalformedDocumentsAreRejected() throws {
        let entity = """
        <!DOCTYPE w:document [<!ENTITY a "expanded"><!ENTITY b "&a;&a;&a;">]>
        <w:document xmlns:w="\(wordNamespace)"><w:body><w:p><w:r><w:t>&b;</w:t></w:r></w:p></w:body></w:document>
        """
        XCTAssertThrowsError(try parse(zip([("word/document.xml", entity)])))
        XCTAssertThrowsError(try parse(zip([("word/document.xml", "<w:document>truncated")])))
        XCTAssertThrowsError(try parse(zip([("word/document.xml", word("<w:p/>"))])))
        let literal = word("<w:p><w:r><w:t><![CDATA[<!ENTITY literal>]]></w:t></w:r></w:p>")
        XCTAssertTrue(try XCTUnwrap(parse(zip([("word/document.xml", literal)])).first?.text)
            .contains("<!ENTITY literal>"))
        let skipped = """
        <!DOCTYPE w:document SYSTEM "https://example.invalid/never-fetch.dtd">
        \(word("<w:p><w:r><w:t>Safe prefix &missing;</w:t></w:r></w:p>"))
        """
        XCTAssertThrowsError(try parse(zip([("word/document.xml", skipped)])))
    }

    func testZIPUnsupportedDuplicateCorruptAndEncryptedMembersAreRejected() throws {
        XCTAssertThrowsError(try parse(zip([("readme.txt", "This is just an archive.")])))
        let document = word("<w:p><w:r><w:t>Text</w:t></w:r></w:p>")
        XCTAssertThrowsError(try parse(zip([("word/document.xml", document), ("word/document.xml", document)])))
        XCTAssertThrowsError(try parse(zip([("word/document.xml", document)], corruptCRC: true)))
        XCTAssertThrowsError(try parse(zip([("word/document.xml", document)], encrypted: true)))
        var truncated = zip([("word/document.xml", document)])
        truncated.removeLast(10)
        XCTAssertThrowsError(try parse(truncated))
    }

    func testOfficeAndEPUBArchiveTraversalOrExternalTargetsAreRejected() throws {
        let document = word("<w:p><w:r><w:t>Text</w:t></w:r></w:p>")
        for target in ["../../outside.xml", "https://example.invalid/document.xml", "//example.invalid/file"] {
            let archive = zip([
                ("[Content_Types].xml", "<Types/>"),
                ("_rels/.rels", rels([("main", "officeDocument", target, false)])),
                ("word/document.xml", document)
            ])
            XCTAssertThrowsError(try parse(archive))
        }
        let archive = epubArchive(first: "<html><body>Text</body></html>", second: "<html><body>More</body></html>",
                                  firstHref: "../../escape.xhtml")
        XCTAssertThrowsError(try parse(archive))
    }

    func testCancelledTaskStopsBeforeParsing() async throws {
        let url = try snapshot(Data("Synthetic text".utf8))
        let task = Task.detached { () throws -> [ParsedPage] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try DocumentTextExtractor.parse(url: url, originalFilename: "notes")
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled extraction must not succeed.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func parse(_ data: Data, hint: String = "document") throws -> [ParsedPage] {
        try DocumentTextExtractor.parse(url: snapshot(data), originalFilename: hint)
    }

    private func snapshot(_ data: Data) throws -> URL {
        let url = temporary.appendingPathComponent("\(UUID()).snapshot")
        try data.write(to: url)
        return url
    }

    private func word(_ body: String) -> String {
        "<w:document xmlns:w=\"\(wordNamespace)\"><w:body>\(body)</w:body></w:document>"
    }

    private func sheet(_ text: String) -> String {
        """
        <worksheet xmlns="\(sheetNamespace)"><sheetData><row r="1">
        <c r="A1" t="inlineStr"><is><t>\(text)</t></is></c></row></sheetData></worksheet>
        """
    }

    private func slide(_ text: String) -> String {
        """
        <p:sld xmlns:p="\(presentationNamespace)" xmlns:a="\(drawingNamespace)">
        <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>\(text)</a:t></a:r></a:p>
        </p:txBody></p:sp></p:spTree></p:cSld></p:sld>
        """
    }

    private func rels(_ values: [(String, String, String, Bool)]) -> String {
        let entries = values.map { id, type, target, external in
            """
            <Relationship Id="\(id)" Type="\(relationNamespace)/\(type)" Target="\(target)"\(external ? " TargetMode=\"External\"" : "")/>
            """
        }.joined()
        return "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(entries)</Relationships>"
    }

    private func epubArchive(first: String, second: String, firstHref: String = "Text/chapter1.xhtml") -> Data {
        zip([
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles>
            <rootfile full-path="OEBPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """),
            ("OEBPS/book.opf", """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><manifest>
            <item id="one" href="\(firstHref)" media-type="application/xhtml+xml"/>
            <item id="two" href="Text/chapter%202.xhtml#part" media-type="application/xhtml+xml"/>
            </manifest><spine><itemref idref="two"/><itemref idref="one"/></spine></package>
            """),
            ("OEBPS/Text/chapter1.xhtml", first), ("OEBPS/Text/chapter 2.xhtml", second)
        ])
    }

    /// A tiny stored-ZIP writer keeps fixtures synthetic, portable and independent
    /// of installed Office apps. CRC verification is performed by the extractor.
    private func zip(
        _ entries: [(String, String)], corruptCRC: Bool = false, encrypted: Bool = false, zip64: Bool = false
    ) -> Data {
        var output = Data(), central = Data()
        func append(_ number: UInt64, width: Int, to data: inout Data) {
            for index in 0..<width { data.append(UInt8(truncatingIfNeeded: number >> (8 * index))) }
        }
        for (name, value) in entries {
            let filename = Data(name.utf8), bytes = Data(value.utf8)
            let offset = output.count
            let crc = UInt64(crc32(bytes) ^ (corruptCRC ? 1 : 0))
            let flags: UInt64 = encrypted ? 0x0801 : 0x0800
            append(0x04034B50, width: 4, to: &output)
            for field in [UInt64(20), flags, 0, 0, 0] { append(field, width: 2, to: &output) }
            for field in [crc, UInt64(bytes.count), UInt64(bytes.count)] { append(field, width: 4, to: &output) }
            append(UInt64(filename.count), width: 2, to: &output)
            append(0, width: 2, to: &output)
            output.append(filename); output.append(bytes)

            append(0x02014B50, width: 4, to: &central)
            for field in [UInt64(20), 20, flags, 0, 0, 0] { append(field, width: 2, to: &central) }
            for field in [crc, UInt64(bytes.count), UInt64(bytes.count)] { append(field, width: 4, to: &central) }
            for field in [UInt64(filename.count), 0, 0, 0, 0] { append(field, width: 2, to: &central) }
            append(0, width: 4, to: &central); append(UInt64(offset), width: 4, to: &central)
            central.append(filename)
        }
        let offset = output.count
        output.append(central)
        if zip64 {
            let endOffset = output.count
            append(0x06064B50, width: 4, to: &output)
            append(44, width: 8, to: &output)
            append(45, width: 2, to: &output); append(45, width: 2, to: &output)
            append(0, width: 4, to: &output); append(0, width: 4, to: &output)
            append(UInt64(entries.count), width: 8, to: &output)
            append(UInt64(entries.count), width: 8, to: &output)
            append(UInt64(central.count), width: 8, to: &output)
            append(UInt64(offset), width: 8, to: &output)
            append(0x07064B50, width: 4, to: &output)
            append(0, width: 4, to: &output)
            append(UInt64(endOffset), width: 8, to: &output)
            append(1, width: 4, to: &output)
        }
        append(0x06054B50, width: 4, to: &output)
        let count = zip64 ? UInt64(UInt16.max) : UInt64(entries.count)
        for field in [UInt64(0), 0, count, count] {
            append(field, width: 2, to: &output)
        }
        append(zip64 ? UInt64(UInt32.max) : UInt64(central.count), width: 4, to: &output)
        append(zip64 ? UInt64(UInt32.max) : UInt64(offset), width: 4, to: &output)
        append(0, width: 2, to: &output)
        return output
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
        }
        return ~crc
    }

    private func pdf(_ pages: [String]) throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 500, height: 700)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: page, attributes: [.font: NSFont.systemFont(ofSize: 16)]))
            context.textPosition = CGPoint(x: 30, y: 640)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// No internet access: a loopback-only tripwire responds immediately if an XML
    /// regression attempts a fetch, avoiding a hanging test and counting the access.
    private final class OfflineHTTPProbe: @unchecked Sendable {
        private let descriptor: Int32
        private let lock = NSLock()
        private let group = DispatchGroup()
        private var stopped = false
        private var connections = 0
        let url: String

        var connectionCount: Int { lock.withLock { connections } }

        init() throws {
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            descriptor = socketFD
            guard socketFD >= 0 else { throw AskBaseError.storage("无法创建离线实体测试探针。") }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(descriptor, 4) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                Darwin.close(descriptor)
                throw AskBaseError.storage("无法监听离线实体测试探针。")
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
            }
            guard named == 0 else {
                Darwin.close(descriptor)
                throw AskBaseError.storage("无法取得离线实体测试端口。")
            }
            url = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/entity"
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { group.leave() }
                while !lock.withLock({ stopped }) {
                    var descriptorEvent = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    if poll(&descriptorEvent, 1, 10) > 0 {
                        let client = accept(descriptor, nil, nil)
                        if client >= 0 {
                            lock.withLock { connections += 1 }
                            let body = "NETWORK ENTITY SENTINEL"
                            let response = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                            response.withUnsafeBytes { bytes in
                                _ = Darwin.send(client, bytes.baseAddress, bytes.count, 0)
                            }
                            Darwin.close(client)
                        }
                    }
                }
            }
        }

        func stop() {
            let first = lock.withLock { () -> Bool in
                if stopped { return false }
                stopped = true
                return true
            }
            if first {
                group.wait()
                Darwin.close(descriptor)
            }
        }
    }
}
