import CryptoKit
import Darwin
import Foundation
import PDFKit

public enum DocumentImporter {
    public static let supportedExtensions: Set<String> = [
        "pdf", "txt", "text", "md", "markdown", "csv", "tsv", "json", "jsonl", "ndjson",
        "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss", "less", "js", "jsx",
        "ts", "tsx", "py", "swift", "c", "h", "cc", "cpp", "hpp", "java", "kt", "kts",
        "rs", "go", "rb", "php", "sh", "bash", "zsh", "sql", "r", "m", "mm", "ini",
        "cfg", "conf", "log", "tex", "srt", "vtt"
    ]

    // Deliberately finite budgets; exceeding one fails the operation rather than
    // silently returning a partial document or a partial directory selection.
    static let maximumFileBytes = 32 * 1024 * 1024
    static let maximumTextUnits = 2_000_000
    static let maximumPDFPages = 2_000
    static let maximumFiles = 1_000
    static let maximumVisitedEntries = 10_000
    static let maximumDirectoryDepth = 16

    public static func expand(_ urls: [URL]) throws -> [URL] {
        guard urls.count <= maximumFiles else {
            throw AskBaseError.importFailed("一次最多选择 \(maximumFiles) 个文件或目录。")
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                        .isHiddenKey, .isPackageKey]
        var files: [URL] = []
        var seenFiles = Set<String>()
        var seenDirectories = Set<String>()
        var visited = 0

        func inspect(_ url: URL) throws -> URLResourceValues {
            guard url.isFileURL else { throw AskBaseError.importFailed("只能导入本机文件。") }
            visited += 1
            guard visited <= maximumVisitedEntries else {
                throw AskBaseError.importFailed("目录超过 \(maximumVisitedEntries) 个条目，请选择更小的目录。")
            }
            do { return try url.resourceValues(forKeys: keys) }
            catch { throw AskBaseError.importFailed("无法读取“\(url.lastPathComponent)”：\(error.localizedDescription)") }
        }

        func append(_ url: URL) throws {
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return }
            let path = url.standardizedFileURL.path
            guard seenFiles.insert(path).inserted else { return }
            guard files.count < maximumFiles else {
                throw AskBaseError.importFailed("一次最多导入 \(maximumFiles) 份资料，请分批选择。")
            }
            files.append(url.standardizedFileURL)
        }

        for input in urls {
            let url = input.standardizedFileURL
            let values = try inspect(url)
            if values.isSymbolicLink == true || values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                continue
            }
            if values.isRegularFile == true {
                guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                    throw AskBaseError.importFailed("不支持“\(url.lastPathComponent)”的文件格式。")
                }
                try append(url)
            } else if values.isDirectory == true {
                if values.isPackage == true { continue }
                guard seenDirectories.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                var traversalError: Error?
                guard let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: Array(keys),
                    // Inspect hidden entries too, then skip them ourselves:
                    // otherwise a huge hidden-only directory evades the budget.
                    options: [.skipsPackageDescendants],
                    errorHandler: { failedURL, error in
                        traversalError = AskBaseError.importFailed(
                            "无法遍历“\(failedURL.lastPathComponent)”：\(error.localizedDescription)"
                        )
                        return false
                    }
                ) else { throw AskBaseError.importFailed("无法遍历所选目录。") }
                while let item = enumerator.nextObject() as? URL {
                    if let traversalError { throw traversalError }
                    let itemValues = try inspect(item)
                    if itemValues.isSymbolicLink == true || itemValues.isHidden == true ||
                        item.lastPathComponent.hasPrefix(".") {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard enumerator.level <= maximumDirectoryDepth else {
                        throw AskBaseError.importFailed("目录层级超过 \(maximumDirectoryDepth) 层，请选择更具体的目录。")
                    }
                    if itemValues.isDirectory == true {
                        if itemValues.isPackage == true ||
                            !seenDirectories.insert(item.standardizedFileURL.path).inserted {
                            enumerator.skipDescendants()
                        }
                    } else if itemValues.isRegularFile == true {
                        try append(item)
                    }
                }
                if let traversalError { throw traversalError }
            } else {
                throw AskBaseError.importFailed("“\(url.lastPathComponent)”不是普通文件或目录。")
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    public static func prepare(
        url: URL, knowledgeBaseID: String, originalsRoot: URL
    ) throws -> PreparedDocument {
        guard !knowledgeBaseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AskBaseError.invalidInput("请选择知识库。")
        }
        let data = try readInput(url)
        let pages = try parse(data: data, extension: url.pathExtension.lowercased())
        let id = UUID().uuidString
        let filename = "\(id).\(url.pathExtension.lowercased())"
        let chunks = TextChunker.chunks(pages: pages, documentID: id, knowledgeBaseID: knowledgeBaseID)
        guard !chunks.isEmpty else { throw AskBaseError.importFailed("文件没有可索引的文字。") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // Hash, extraction, and the managed copy all use the very same bytes.
        // Parse before writing so rejected/empty documents leave no copies behind.
        try OriginalFileStorage.write(data, filename: filename, directory: originalsRoot)
        return PreparedDocument(
            document: LibraryDocument(
                id: id, knowledgeBaseID: knowledgeBaseID,
                title: url.deletingPathExtension().lastPathComponent,
                fileName: url.lastPathComponent, relativePath: "Originals/\(filename)",
                contentHash: digest, byteCount: data.count
            ),
            chunks: chunks
        )
    }

    public static func parse(url: URL) throws -> [ParsedPage] {
        try parse(data: readInput(url), extension: url.pathExtension.lowercased())
    }

    private static func readInput(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw AskBaseError.importFailed("只能导入本机文件。") }
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw AskBaseError.importFailed("不支持“\(url.lastPathComponent)”的文件格式。")
        }
        // O_NONBLOCK prevents opening a disguised FIFO from hanging the app;
        // O_NOFOLLOW plus fstat prevents importing a link or device as a file.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AskBaseError.importFailed("无法打开“\(url.lastPathComponent)”；请检查权限，且不要选择符号链接。")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw AskBaseError.importFailed("只能导入普通文件，不支持目录、设备或管道。")
        }
        guard before.st_size <= maximumFileBytes else {
            throw AskBaseError.importFailed("文件超过 32 MiB 上限，请拆分后导入。")
        }
        guard before.st_size > 0 else { throw AskBaseError.importFailed("文件为空，没有可索引的文字。") }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        do {
            while let part = try handle.read(upToCount: min(65_536, maximumFileBytes + 1 - data.count)),
                  !part.isEmpty {
                data.append(part)
                guard data.count <= maximumFileBytes else {
                    throw AskBaseError.importFailed("读取期间文件超过 32 MiB 上限，请拆分后导入。")
                }
            }
        } catch let error as AskBaseError { throw error }
        catch { throw AskBaseError.importFailed("读取文件失败：\(error.localizedDescription)") }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              after.st_size == data.count,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw AskBaseError.importFailed("读取期间文件发生变化，请保存文件后重新导入。")
        }
        return data
    }

    private static func parse(data: Data, extension ext: String) throws -> [ParsedPage] {
        if ext == "pdf" { return try parsePDF(data) }
        let text = try decodeText(data)
        try validateText(text)
        return [ParsedPage(text: normalizeNewlines(text))]
    }

    private static func parsePDF(_ data: Data) throws -> [ParsedPage] {
        guard let pdf = PDFDocument(data: data) else {
            throw AskBaseError.importFailed("PDF 文件已损坏或不是有效的 PDF。")
        }
        guard !pdf.isLocked else { throw AskBaseError.importFailed("PDF 已加密，请解锁并另存后导入。") }
        guard pdf.pageCount > 0 else { throw AskBaseError.importFailed("PDF 没有页面。") }
        guard pdf.pageCount <= maximumPDFPages else {
            throw AskBaseError.importFailed("PDF 超过 \(maximumPDFPages) 页上限，请拆分后导入。")
        }
        var pages: [ParsedPage] = []
        var totalUnits = 0
        var hasText = false
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else {
                throw AskBaseError.importFailed("无法读取 PDF 第 \(index + 1) 页。")
            }
            let text = normalizeNewlines(page.string ?? "")
            totalUnits += text.utf16.count
            guard totalUnits <= maximumTextUnits else {
                throw AskBaseError.importFailed("PDF 提取文字超过 200 万个 UTF-16 单元，请拆分后导入。")
            }
            hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Include blank pages so page numbers always refer to the source PDF.
            pages.append(ParsedPage(page: index + 1, text: text))
        }
        guard hasText else {
            throw AskBaseError.importFailed("PDF 没有可提取文字，可能是扫描件或空白文件；本版本不执行 OCR。")
        }
        return pages
    }

    private static func decodeText(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            throw AskBaseError.importFailed("暂不支持 UTF-32，请另存为 UTF-8 或 UTF-16。")
        }
        if bytes.starts(with: [0xFF, 0xFE]) { return try decodeUTF16(Array(bytes.dropFirst(2)), littleEndian: true) }
        if bytes.starts(with: [0xFE, 0xFF]) { return try decodeUTF16(Array(bytes.dropFirst(2)), littleEndian: false) }
        // BOM-less UTF-16 is accepted only when ASCII/NUL lanes identify its byte
        // order. Arbitrary invalid UTF-8 must not be reinterpreted as CJK binary.
        if bytes.count.isMultiple(of: 2), bytes.contains(0) {
            let pairs = bytes.count / 2
            let evenZeros = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            if oddZeros > 0, evenZeros == 0, oddZeros * 20 >= pairs {
                return try decodeUTF16(bytes, littleEndian: true)
            }
            if evenZeros > 0, oddZeros == 0, evenZeros * 20 >= pairs {
                return try decodeUTF16(bytes, littleEndian: false)
            }
        }
        guard var text = String(data: data, encoding: .utf8) else {
            throw AskBaseError.importFailed("文件不是有效的 UTF-8/UTF-16 文本，或是二进制文件；UTF-16 请保留 BOM 字节序标记。")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    private static func decodeUTF16(_ bytes: [UInt8], littleEndian: Bool) throws -> String {
        guard bytes.count.isMultiple(of: 2) else {
            throw AskBaseError.importFailed("UTF-16 文件末尾不完整，请重新保存后导入。")
        }
        let units: [UInt16] = stride(from: 0, to: bytes.count, by: 2).map {
            littleEndian ? UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
                : UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
        }
        var index = 0
        while index < units.count {
            let value = units[index]
            if (0xD800...0xDBFF).contains(value) {
                guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else {
                    throw AskBaseError.importFailed("UTF-16 包含不完整的字符，拒绝有损导入。")
                }
                index += 2
            } else {
                guard !(0xDC00...0xDFFF).contains(value) else {
                    throw AskBaseError.importFailed("UTF-16 包含无效字符，拒绝有损导入。")
                }
                index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func validateText(_ text: String) throws {
        guard text.utf16.count <= maximumTextUnits else {
            throw AskBaseError.importFailed("文字超过 200 万个 UTF-16 单元，请拆分后导入。")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AskBaseError.importFailed("文件只有空白字符，没有可索引的文字。")
        }
        let binary = text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (value < 32 && ![9, 10, 12, 13].contains(value)) ||
                (127...159).contains(value) || (0xFDD0...0xFDEF).contains(value) ||
                value & 0xFFFF == 0xFFFE || value & 0xFFFF == 0xFFFF
        }
        guard !binary else {
            throw AskBaseError.importFailed("文件含二进制控制字符，不是支持的纯文本。")
        }
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}

/// File operations use an opened, non-symlink directory and single-component
/// names, so a deletion can never resolve through a source-file symlink.
enum OriginalFileStorage {
    static func openDirectory(_ directory: URL, create: Bool) throws -> Int32 {
        guard directory.isFileURL else { throw AskBaseError.storage("资料副本目录必须位于本机。") }
        if create {
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { throw AskBaseError.storage("无法创建资料副本目录：\(error.localizedDescription)") }
        }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AskBaseError.storage("无法打开资料副本目录；目录不能是符号链接。")
        }
        return descriptor
    }

    static func filename(relativePath: String) throws -> String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Originals", !parts[1].contains("\0") else {
            throw AskBaseError.storage("资料副本路径无效，必须位于 Originals 目录。")
        }
        let filename = String(parts[1])
        let url = URL(fileURLWithPath: filename)
        guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
              DocumentImporter.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw AskBaseError.storage("资料副本必须使用 UUID 文件名和受支持的扩展名。")
        }
        return filename
    }

    static func write(_ data: Data, filename: String, directory: URL) throws {
        _ = try self.filename(relativePath: "Originals/\(filename)")
        let directoryFD = try openDirectory(directory, create: true)
        defer { Darwin.close(directoryFD) }
        let staging = ".askbase-\(UUID().uuidString).tmp"
        let descriptor = openat(directoryFD, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AskBaseError.storage("无法创建资料副本。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(directoryFD, staging, 0)
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            // linkat installs the complete file without replacing an existing name.
            guard linkat(directoryFD, staging, directoryFD, filename, 0) == 0 else {
                throw AskBaseError.storage("无法保存资料副本，已有同名文件或磁盘不可写。")
            }
            _ = fsync(directoryFD)
        } catch let error as AskBaseError { throw error }
        catch { throw AskBaseError.storage("保存资料副本失败：\(error.localizedDescription)") }
    }

    static func remove(relativePath: String, directory: URL) throws {
        let filename = try filename(relativePath: relativePath)
        let directoryFD = try openDirectory(directory, create: false)
        defer { Darwin.close(directoryFD) }
        // unlinkat removes the entry itself even if an external program replaced
        // it with a symlink; it cannot remove the symlink target.
        guard unlinkat(directoryFD, filename, 0) == 0 || errno == ENOENT else {
            throw AskBaseError.storage("资料记录已删除，但副本清理失败；重新打开资料库时会重试。")
        }
        _ = fsync(directoryFD)
    }
}
