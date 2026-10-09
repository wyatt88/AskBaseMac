import Darwin
import Foundation

public enum DocumentImporter {
    /// Enumerate the complete selection without extension, count, or depth quotas.
    public static func expand(_ urls: [URL]) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                        .isHiddenKey, .isPackageKey]
        var files: [URL] = []
        var seenFiles = Set<String>()
        var seenDirectories = Set<String>()
        func inspect(_ url: URL) throws -> URLResourceValues {
            try Task.checkCancellation()
            guard url.isFileURL else { throw AskBaseError.importFailed("只能导入本机文件。") }
            do { return try url.resourceValues(forKeys: keys) }
            catch { throw AskBaseError.importFailed("无法读取“\(url.lastPathComponent)”：\(error.localizedDescription)") }
        }

        func append(_ url: URL) throws {
            try Task.checkCancellation()
            let path = url.standardizedFileURL.path
            guard seenFiles.insert(path).inserted else { return }
            files.append(url.standardizedFileURL)
        }

        for input in urls {
            let url = input.standardizedFileURL
            let values = try inspect(url)
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                try append(url)
            } else if values.isDirectory == true {
                if values.isPackage == true { continue }
                guard seenDirectories.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
                var traversalError: Error?
                guard let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: Array(keys),
                    // Hidden files may be selected explicitly. Folder imports
                    // continue to skip hidden descendants and application bundles.
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
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
        let snapshot = try FileSnapshotReader.read(url)
        defer { snapshot.remove() }
        let pages = try DocumentTextExtractor.parse(url: snapshot.url, originalFilename: url.lastPathComponent)
        return try prepared(snapshot: snapshot, original: url, knowledgeBaseID: knowledgeBaseID,
                            originalsRoot: originalsRoot, pages: pages)
    }

    /// Media is identified from the stable file contents, before trying text
    /// extraction. All positions refer to the exact bytes in the managed copy.
    public static func prepareForImport(
        url: URL, knowledgeBaseID: String, originalsRoot: URL
    ) async throws -> PreparedDocument {
        guard !knowledgeBaseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AskBaseError.invalidInput("请选择知识库。")
        }
        let snapshot = try await FileSnapshotReader.readAsync(url)
        defer { snapshot.remove() }
        if let plan = try await MediaProcessor.inspect(url: snapshot.url) {
            return try prepared(snapshot: snapshot, original: url, knowledgeBaseID: knowledgeBaseID,
                                originalsRoot: originalsRoot, media: plan)
        }
        let pages = try DocumentTextExtractor.parse(url: snapshot.url, originalFilename: url.lastPathComponent)
        return try prepared(snapshot: snapshot, original: url, knowledgeBaseID: knowledgeBaseID,
                            originalsRoot: originalsRoot, pages: pages)
    }

    private static func prepared(
        snapshot: InputFileSnapshot, original url: URL, knowledgeBaseID: String, originalsRoot: URL,
        pages: [ParsedPage] = [], media: MediaPlan? = nil
    ) throws -> PreparedDocument {
        try Task.checkCancellation()
        let id = UUID().uuidString
        let ext = url.pathExtension.lowercased()
        let candidate = ext.isEmpty ? id : "\(id).\(ext)"
        let originalName = url.lastPathComponent
        let stem = (originalName as NSString).deletingPathExtension
        let title = [stem, originalName].first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? "未命名资料"
        // Preserve useful extensions, while accommodating an original whose
        // extension alone would exceed the filesystem's component length.
        let filename = candidate.utf8.count <= 255 ? candidate : id
        let chunks: [DocumentChunk]
        if let media {
            chunks = try mediaChunks(plan: media, documentID: id, knowledgeBaseID: knowledgeBaseID)
        } else {
            chunks = try TextChunker.cancellableChunks(pages: pages, documentID: id,
                                                       knowledgeBaseID: knowledgeBaseID)
        }
        guard !chunks.isEmpty else { throw AskBaseError.importFailed("文件没有可索引的文字或媒体。") }
        // Hash, extraction, and the managed copy use the same stable snapshot.
        // Rejected files leave no managed copies behind.
        try OriginalFileStorage.copy(snapshot.url, filename: filename, directory: originalsRoot)
        return PreparedDocument(
            document: LibraryDocument(
                id: id, knowledgeBaseID: knowledgeBaseID,
                title: title, fileName: originalName, relativePath: "Originals/\(filename)",
                contentHash: snapshot.contentHash, byteCount: snapshot.byteCount, media: media?.reference
            ),
            chunks: chunks
        )
    }

    static func mediaChunks(plan: MediaPlan, documentID: String, knowledgeBaseID: String) throws -> [DocumentChunk] {
        guard plan.reference.isValid, !plan.segments.isEmpty else {
            throw AskBaseError.importFailed("媒体没有可索引的画面或时间段。")
        }
        return try plan.segments.enumerated().map { ordinal, reference in
            try Task.checkCancellation()
            guard reference.isValid, reference.kind == plan.reference.kind else {
                throw AskBaseError.importFailed("媒体分段位置无效。")
            }
            return DocumentChunk(documentID: documentID, knowledgeBaseID: knowledgeBaseID,
                                 ordinal: ordinal, text: mediaPlaceholder(reference), media: reference)
        }
    }

    static func mediaPlaceholder(_ reference: MediaReference) -> String {
        "\(reference.kind.label) · \(reference.positionLabel)（媒体语义索引，无文字转写）"
    }

    /// Keep the same snapshot alive across asynchronous segment preparation.
    /// expectedHash protects reindexing against externally replaced originals.
    static func withSnapshot<T>(
        url: URL, expectedHash: String? = nil, operation: (URL) async throws -> T
    ) async throws -> T {
        let snapshot = try await FileSnapshotReader.readAsync(url)
        defer { snapshot.remove() }
        if let expectedHash, expectedHash != snapshot.contentHash {
            throw AskBaseError.importFailed("资料副本的内容已改变，请重新导入；旧索引已保留。")
        }
        return try await operation(snapshot.url)
    }

    public static func parse(url: URL, originalFilename: String? = nil) throws -> [ParsedPage] {
        let snapshot = try FileSnapshotReader.read(url)
        defer { snapshot.remove() }
        return try DocumentTextExtractor.parse(url: snapshot.url,
                                                originalFilename: originalFilename ?? url.lastPathComponent)
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
        // POSIX treats slash/NUL as bytes. A slash or dot followed by a combining
        // mark is one Swift Character, so Character-based splitting is unsafe.
        let parts = relativePath.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].elementsEqual("Originals".utf8),
              !parts[1].contains(0), parts[1].count >= 36 else {
            throw AskBaseError.storage("资料副本路径无效，必须位于 Originals 目录。")
        }
        let filename = String(decoding: parts[1], as: UTF8.self)
        let identifier = String(decoding: parts[1].prefix(36), as: UTF8.self)
        let suffix = parts[1].dropFirst(36)
        guard UUID(uuidString: identifier) != nil,
              suffix.isEmpty || (suffix.first == 0x2E && suffix.count > 1 && suffix.dropFirst().first != 0x2E) else {
            throw AskBaseError.storage("资料副本必须使用 UUID 文件名。")
        }
        return filename
    }

    static func existingURL(relativePath: String, directory: URL) throws -> URL {
        let filename = try self.filename(relativePath: relativePath)
        let directoryFD = try openDirectory(directory, create: false)
        defer { Darwin.close(directoryFD) }
        let descriptor = openat(directoryFD, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AskBaseError.storage("资料副本不存在、不可读或已被替换为符号链接。")
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AskBaseError.storage("资料副本必须是普通文件。")
        }
        return directory.appendingPathComponent(filename)
    }

    static func copy(_ source: URL, filename: String, directory: URL) throws {
        try Task.checkCancellation()
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
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            while let part = try input.read(upToCount: 1_048_576), !part.isEmpty {
                try Task.checkCancellation()
                try handle.write(contentsOf: part)
            }
            try Task.checkCancellation()
            try handle.synchronize()
            // linkat installs the complete file without replacing an existing name.
            guard linkat(directoryFD, staging, directoryFD, filename, 0) == 0 else {
                throw AskBaseError.storage("无法保存资料副本，已有同名文件或磁盘不可写。")
            }
            _ = fsync(directoryFD)
        } catch is CancellationError {
            throw CancellationError()
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
