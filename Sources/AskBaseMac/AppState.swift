import AppKit
import Combine
import UniformTypeIdentifiers
import AskBaseCore

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var isStarting = false
    @Published private(set) var hasStarted = false
    @Published private(set) var startupError: String?
    @Published private(set) var snapshot = LibrarySnapshot(
        knowledgeBases: [], documents: [], notes: [], conversations: []
    )
    @Published private(set) var selectedKnowledgeBaseID: String?
    @Published var section: WorkspaceSection = .library
    @Published var sheet: AppSheet?
    @Published var deletion: DeletionRequest?
    @Published var notice: String?
    @Published private(set) var isDeleting = false

    @Published var libraryFilter = ""
    @Published var favoritesOnly = false
    @Published var tagFilter = ""
    @Published var documentSort: DocumentSort = .newest
    @Published var selectedDocumentID: String?
    @Published private(set) var changingDocumentIDs: Set<String> = []
    @Published private(set) var reindexingDocumentIDs: Set<String> = []
    @Published private(set) var reindexActivity: ReindexActivity?
    @Published private(set) var isCancellingReindex = false
    @Published private(set) var isChoosingFiles = false
    @Published private(set) var isReadingDrop = false
    @Published private(set) var importActivity: ImportActivity?
    @Published private(set) var isCancellingImport = false
    @Published private(set) var importOutcome: ImportOutcome?

    @Published var searchQuery = ""
    @Published private(set) var searchedQuery = ""
    @Published private(set) var searchMediaURL: URL?
    @Published private(set) var searchedInput: SearchInput?
    @Published private(set) var isChoosingSearchMedia = false
    @Published private(set) var searchResults: [SearchResult] = []
    @Published private(set) var hasSearched = false
    @Published private(set) var isSearching = false
    @Published private(set) var isCancellingSearch = false
    @Published private(set) var searchError: String?
    @Published private(set) var searchNotice: String?

    @Published private(set) var selectedConversationID: String?
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isLoadingMessages = false
    @Published var chatDraft = ""
    @Published private(set) var pendingQuestion: String?
    @Published private(set) var isAnswering = false
    @Published private(set) var isCancellingAnswer = false
    @Published private(set) var answerStartedAt: Date?
    @Published private(set) var chatError: String?
    @Published private(set) var chatNotice: String?

    @Published var selectedNoteID: String?
    @Published private(set) var noteDrafts: [String: LibraryNote] = [:]
    @Published private(set) var noteSaveStates: [String: NoteSaveState] = [:]
    @Published private(set) var isCreatingNote = false

    @Published private(set) var settings = AppSettings()
    @Published private(set) var modelStatus: ModelStatus?
    @Published private(set) var connectionCheckedAt: Date?
    @Published private(set) var isCheckingConnections = false
    @Published private(set) var isSavingSettings = false
    @Published private(set) var modelSelectionNotice: String?
    @Published private(set) var modelSelectionError: String?

    private let libraryRoot: URL
    private var launchFailure: String?
    private var engine: KnowledgeEngine?
    private var refreshRevision = 0
    private var importTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchToken: UUID?
    private var mediaSearchPanel: NSOpenPanel?
    private var mediaSearchPanelToken: UUID?
    private var answerTask: Task<Void, Never>?
    private var answerToken: UUID?
    private var answeringKnowledgeBaseID: String?
    private var messageTask: Task<Void, Never>?
    private var messageToken: UUID?
    private var chatDrafts: [String: String] = [:]
    private var noteTasks: [String: Task<Void, Never>] = [:]
    private var noteRevisions: [String: Int] = [:]
    private var notesBeingRemoved: Set<String> = []
    private var connectionToken: UUID?
    private var reindexTask: Task<Void, Never>?

    init(root: URL = KnowledgeEngine.defaultRoot) {
        libraryRoot = root
    }

    #if DEBUG
    /// Used only by synthetic checks with explicitly injected offline clients.
    convenience init(verificationEngine: KnowledgeEngine) {
        self.init(root: verificationEngine.root)
        engine = verificationEngine
    }

    var verificationSearchTask: Task<Void, Never>? { searchTask }
    #endif

    func preventStartup(message: String) {
        launchFailure = message
        startupError = message
    }

    var selectedKnowledgeBase: KnowledgeBase? {
        snapshot.knowledgeBases.first { $0.id == selectedKnowledgeBaseID }
    }
    var documents: [LibraryDocument] {
        snapshot.documents.filter { $0.knowledgeBaseID == selectedKnowledgeBaseID }
    }
    var readyDocumentCount: Int { documents.filter { $0.status == .ready }.count }
    var allTags: [String] { Array(Set(documents.flatMap(\.tags))).sorted() }
    var filteredDocuments: [LibraryDocument] {
        let query = libraryFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return documents.filter { document in
            (!favoritesOnly || document.isFavorite)
                && (tagFilter.isEmpty || document.tags.contains(tagFilter))
                && (query.isEmpty || ([document.title, document.fileName] + document.tags)
                    .contains { $0.localizedStandardContains(query) })
        }.sorted {
            switch documentSort {
            case .newest: $0.createdAt > $1.createdAt
            case .title: $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }
    var conversations: [Conversation] {
        snapshot.conversations.filter { $0.knowledgeBaseID == selectedKnowledgeBaseID }
            .sorted { $0.createdAt > $1.createdAt }
    }
    var notes: [LibraryNote] {
        snapshot.notes.filter { $0.knowledgeBaseID == selectedKnowledgeBaseID }
            .sorted { $0.createdAt > $1.createdAt }
    }
    var availableChatModels: [String] {
        Array(Set(modelStatus?.chatModels ?? [])).sorted()
    }
    var rootURL: URL? { engine?.root }
    private var selectionDefaultsKey: String {
        "AskBaseLocal.selectedKnowledgeBase.\(libraryRoot.standardizedFileURL.path)"
    }
    var canImport: Bool {
        hasStarted && selectedKnowledgeBaseID != nil && importActivity == nil
            && reindexActivity == nil && !isChoosingFiles && !isChoosingSearchMedia
            && !isReadingDrop && !isDeleting && !isSavingSettings
    }
    var settingsAreLocked: Bool {
        importActivity != nil || isAnswering || isSearching || isChoosingSearchMedia
            || !reindexingDocumentIDs.isEmpty
    }
    var canChooseSearchMedia: Bool {
        hasStarted && selectedKnowledgeBaseID != nil && readyDocumentCount > 0
            && !isSearching && !isChoosingSearchMedia && !isChoosingFiles && !isDeleting && !isSavingSettings
    }
    var canSearch: Bool {
        hasStarted && selectedKnowledgeBaseID != nil && readyDocumentCount > 0
            && !isSearching && !isChoosingSearchMedia && !isDeleting && !isSavingSettings
            && (searchMediaURL != nil || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var embeddingCapabilities: EmbeddingCapabilities {
        EmbeddingCapabilities(status: modelStatus, checking: isCheckingConnections)
    }
    var canAsk: Bool {
        selectedKnowledgeBaseID != nil && readyDocumentCount > 0
            && !settings.chatModel.isEmpty && !isAnswering && !isLoadingMessages && !isDeleting && !isSavingSettings
            && !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var importedDocumentsInProgress: [LibraryDocument] {
        guard let activity = importActivity else { return [] }
        return snapshot.documents.filter {
            $0.knowledgeBaseID == activity.knowledgeBaseID
                && !activity.existingDocumentIDs.contains($0.id)
        }
    }
    var hasUnsavedNotes: Bool { !noteDrafts.isEmpty }

    func start() async {
        guard !isStarting, !hasStarted else { return }
        if let launchFailure {
            startupError = launchFailure
            return
        }
        isStarting = true
        startupError = nil
        do {
            let openedEngine: KnowledgeEngine
            if let engine {
                openedEngine = engine
            } else {
                let root = libraryRoot
                openedEngine = try await Task.detached(priority: .userInitiated) {
                    try KnowledgeEngine(root: root)
                }.value
            }
            let initialSnapshot = try await openedEngine.snapshot()
            let initialSettings = try await openedEngine.settings()
            engine = openedEngine
            snapshot = initialSnapshot
            settings = initialSettings
            let rememberedID = UserDefaults.standard.string(forKey: selectionDefaultsKey)
            selectedKnowledgeBaseID = initialSnapshot.knowledgeBases.first { $0.id == rememberedID }?.id
                ?? initialSnapshot.knowledgeBases.first?.id
            hasStarted = true
            isStarting = false
            await checkConnections()
        } catch {
            startupError = error.localizedDescription
            isStarting = false
        }
    }

    @discardableResult
    func refresh(showErrors: Bool = true) async -> Bool {
        guard let engine else { return false }
        refreshRevision += 1
        let revision = refreshRevision
        do {
            let current = try await engine.snapshot()
            guard revision == refreshRevision else { return true }
            snapshot = current
            if !current.knowledgeBases.contains(where: { $0.id == selectedKnowledgeBaseID }) {
                selectKnowledgeBase(current.knowledgeBases.first?.id)
            }
            if let id = selectedDocumentID, !documents.contains(where: { $0.id == id }) {
                selectedDocumentID = nil
            }
            if case .source(let source) = sheet,
               !documents.contains(where: { $0.id == source.documentID }) {
                sheet = nil
            }
            let documentIDs = Set(documents.map(\.id))
            searchResults.removeAll { !documentIDs.contains($0.documentID) }
            if let id = selectedNoteID, !notes.contains(where: { $0.id == id }) {
                selectedNoteID = nil
            }
            if !tagFilter.isEmpty, !allTags.contains(tagFilter) { tagFilter = "" }
            return true
        } catch {
            if showErrors { showError("无法刷新资料库", error) }
            return false
        }
    }

    private var chatDraftKey: String {
        selectedConversationID ?? "new:\(selectedKnowledgeBaseID ?? "")"
    }

    func selectKnowledgeBase(_ id: String?) {
        guard id != selectedKnowledgeBaseID else { return }
        chatDrafts[chatDraftKey] = chatDraft
        discardSearch()
        mediaSearchPanelToken = nil
        mediaSearchPanel?.cancel(nil)
        mediaSearchPanel = nil
        isChoosingSearchMedia = false
        searchMediaURL = nil
        if case .source = sheet { sheet = nil }
        abandonAnswer()
        messageTask?.cancel()
        messageToken = nil
        selectedKnowledgeBaseID = id
        UserDefaults.standard.set(id, forKey: selectionDefaultsKey)
        selectedDocumentID = nil
        selectedNoteID = nil
        selectedConversationID = nil
        messages = []
        chatDraft = chatDrafts[chatDraftKey] ?? ""
        isLoadingMessages = false
        searchResults = []
        hasSearched = false
        searchedQuery = ""
        searchedInput = nil
        searchError = nil
        searchNotice = nil
        chatError = nil
        chatNotice = nil
        libraryFilter = ""
        tagFilter = ""
        favoritesOnly = false
    }

    func saveKnowledgeBase(name: String, existing: KnowledgeBase?) async throws {
        guard let engine else { throw AskBaseError.storage("资料库尚未打开。") }
        if let existing {
            try await engine.renameKnowledgeBase(id: existing.id, name: name)
            await refresh()
        } else {
            let base = try await engine.createKnowledgeBase(name: name)
            await refresh()
            selectKnowledgeBase(base.id)
            section = .library
        }
    }

    func showError(_ title: String, _ error: Error) {
        showError(title, message: error.localizedDescription)
    }

    func showError(_ title: String, message: String) {
        sheet = .issue(AppIssue(title: title, message: message))
    }

    // Only explicit open-panel selections or dropped file URLs enter this method.
    func chooseImport() {
        guard canImport, let base = selectedKnowledgeBase else { return }
        let panel = NSOpenPanel()
        panel.title = "导入资料"
        panel.message = "加入「\(base.name)」。支持文本、图片、音频、视频和文件夹；不设大小、数量或总时长配额，也不按扩展名筛选。按内容识别并检查模型能力，不支持的项目会说明原因。"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = false
        isChoosingFiles = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let urls = panel.urls
            Task { @MainActor in
                guard let self else { return }
                self.isChoosingFiles = false
                guard response == .OK, !urls.isEmpty else { return }
                self.importDocuments(urls, into: base)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canImport, let base = selectedKnowledgeBase else { return false }
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        isReadingDrop = true
        Task {
            var urls: [URL] = []
            var failures: [String] = []
            for provider in providers {
                do {
                    let url = try await Self.fileURL(from: provider)
                    guard url.isFileURL else { throw AskBaseError.invalidInput("只接受本机文件和文件夹。") }
                    urls.append(url)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            isReadingDrop = false
            if !failures.isEmpty {
                // Do not silently import a subset when part of the user's drop could not be read.
                showError("无法读取拖入的项目", message: failures.joined(separator: "\n\n"))
            } else if !urls.isEmpty {
                importDocuments(urls, into: base)
            }
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let string = item as? String, let url = URL(string: string) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: AskBaseError.invalidInput("无法取得拖入项目的文件地址，请使用“导入资料”。"))
                }
            }
        }
    }

    func importDocuments(_ urls: [URL], into base: KnowledgeBase) {
        guard let engine, importActivity == nil, !urls.isEmpty else { return }
        guard urls.allSatisfy(\.isFileURL) else {
            showError("无法导入", message: "请选择本机文件或文件夹。")
            return
        }
        let activity = ImportActivity(
            knowledgeBaseID: base.id, knowledgeBaseName: base.name, selectedCount: urls.count,
            existingDocumentIDs: Set(snapshot.documents.map(\.id))
        )
        importActivity = activity
        importOutcome = nil
        isCancellingImport = false
        startProgressRefresh()
        importTask = Task {
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            var outcome: ImportOutcome
            do {
                let report = try await engine.importDocuments(urls: urls, knowledgeBaseID: base.id)
                outcome = ImportOutcome(report: report, knowledgeBaseName: base.name)
            } catch {
                await refresh(showErrors: false)
                var partial = ImportReport()
                let added = snapshot.documents.filter {
                    $0.knowledgeBaseID == base.id && !activity.existingDocumentIDs.contains($0.id)
                }
                partial.imported = added.filter { $0.status == .ready }
                partial.failures = added.filter { $0.status == .failed }.map {
                    "\($0.fileName)：\($0.errorMessage ?? "索引未完成，可重试索引。")"
                }
                let cancelled = error is CancellationError || Task.isCancelled
                outcome = ImportOutcome(
                    report: partial, knowledgeBaseName: base.name, wasCancelled: cancelled,
                    error: cancelled ? "已完成的资料保留在库中，未完成的资料可重试索引。尚未处理的项目需要再次选择导入。" : error.localizedDescription
                )
            }
            await refresh(showErrors: false)
            guard importActivity?.id == activity.id else { return }
            importOutcome = outcome
            importActivity = nil
            importTask = nil
            isCancellingImport = false
            if selectedKnowledgeBaseID == base.id, let first = outcome.report.imported.first {
                selectedDocumentID = first.id
            }
        }
    }

    func cancelImport() {
        guard importActivity != nil else { return }
        isCancellingImport = true
        importTask?.cancel()
    }

    func dismissImportOutcome() { importOutcome = nil }

    private func startProgressRefresh() {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while let self, self.importActivity != nil || !self.reindexingDocumentIDs.isEmpty {
                await self.refresh(showErrors: false)
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { break }
            }
            self?.progressTask = nil
        }
    }

    func reindex(_ document: LibraryDocument) {
        reindexDocuments([document])
    }

    func reindexDocuments(_ documents: [LibraryDocument]) {
        guard let engine, reindexActivity == nil, importActivity == nil, !isDeleting else { return }
        let documents = documents.filter { $0.status != .indexing }
        guard !documents.isEmpty else { return }
        let activity = ReindexActivity(total: documents.count)
        reindexActivity = activity
        isCancellingReindex = false
        reindexingDocumentIDs = Set(documents.map(\.id))
        startProgressRefresh()
        reindexTask = Task {
            for document in documents {
                guard !Task.isCancelled, reindexActivity?.id == activity.id else { break }
                reindexActivity?.currentDocumentID = document.id
                reindexActivity?.currentTitle = document.title
                do {
                    try await engine.reindex(documentID: document.id)
                    reindexActivity?.succeeded += 1
                    searchResults.removeAll { $0.documentID == document.id }
                    if case .source(let source) = sheet, source.documentID == document.id { sheet = nil }
                } catch {
                    if error is CancellationError || Task.isCancelled { break }
                    reindexActivity?.failures.append("\(document.title)：\(error.localizedDescription)")
                }
                reindexActivity?.processed += 1
                reindexingDocumentIDs.remove(document.id)
                await refresh(showErrors: false)
            }
            guard let finished = reindexActivity, finished.id == activity.id else { return }
            let cancelled = Task.isCancelled
            if !finished.failures.isEmpty {
                showError("索引重建结果", message:
                    "已成功 \(finished.succeeded) 份，共处理 \(finished.processed) / \(finished.total) 份。\n\n"
                    + finished.failures.joined(separator: "\n\n")
                    + (cancelled ? "\n\n队列已停止，尚未完成的资料可再次重建。" : "")
                )
            }
            notice = cancelled
                ? "索引重建已停止，已成功 \(finished.succeeded) 份。"
                : "索引重建完成：\(finished.succeeded) 份成功，\(finished.failures.count) 份需处理。"
            reindexActivity = nil
            reindexingDocumentIDs = []
            reindexTask = nil
            isCancellingReindex = false
            await refresh()
        }
    }

    func cancelReindex() {
        isCancellingReindex = true
        reindexTask?.cancel()
    }

    func toggleFavorite(_ document: LibraryDocument) {
        guard !changingDocumentIDs.contains(document.id) else { return }
        Task {
            do {
                try await updateDocument(id: document.id, isFavorite: !document.isFavorite)
            } catch { showError("无法更新收藏", error) }
        }
    }

    func updateDocument(id: String, title: String? = nil, tags: [String]? = nil,
                        isFavorite: Bool? = nil) async throws {
        guard let engine, var document = snapshot.documents.first(where: { $0.id == id }) else {
            throw AskBaseError.invalidInput("资料已不存在。")
        }
        changingDocumentIDs.insert(id)
        defer { changingDocumentIDs.remove(id) }
        if let title { document.title = title }
        if let tags { document.tags = tags }
        if let isFavorite { document.isFavorite = isFavorite }
        try await engine.updateDocument(document)
        await refresh()
    }

    func chunks(for documentID: String) async throws -> [DocumentChunk] {
        guard let engine else { throw AskBaseError.storage("资料库尚未打开。") }
        return try await engine.documentChunks(documentID: documentID).sorted { $0.ordinal < $1.ordinal }
    }

    /// Preview callers must use the same original-file validation as external opening.
    /// Recheck the current library after the actor hop so a late read cannot revive
    /// a deleted source or the previous knowledge base's preview.
    func originalURL(for documentID: String) async throws -> URL {
        guard let engine, let baseID = selectedKnowledgeBaseID,
              documents.contains(where: { $0.id == documentID }) else {
            throw AskBaseError.invalidInput("来源已移除或不在当前知识库中。")
        }
        let url = try await engine.originalURL(documentID: documentID)
        try Task.checkCancellation()
        guard selectedKnowledgeBaseID == baseID,
              documents.contains(where: { $0.id == documentID }), url.isFileURL else {
            throw AskBaseError.invalidInput("来源已移除或知识库已切换，请重新选择资料。")
        }
        return url
    }

    func openOriginal(_ documentID: String, reveal: Bool = false) {
        guard let document = documents.first(where: { $0.id == documentID }) else { return }
        Task {
            do {
                let url = try await originalURL(for: documentID)
                if reveal {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    // Open code as text instead of letting a script's default handler execute it.
                    let bundleID: String
                    switch document.media?.kind {
                    case .image: bundleID = "com.apple.Preview"
                    case .audio, .video: bundleID = "com.apple.QuickTimePlayerX"
                    case nil:
                        bundleID = url.pathExtension.lowercased() == "pdf" ? "com.apple.Preview" : "com.apple.TextEdit"
                    }
                    guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                        throw AskBaseError.storage("未找到系统阅读器。可先在 Finder 中显示这份文件，再选择打开方式。")
                    }
                    _ = try await NSWorkspace.shared.open(
                        [url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()
                    )
                }
            } catch { showError("无法打开原始文件", error) }
        }
    }

    func chooseMediaSearch() {
        guard canChooseSearchMedia, let base = selectedKnowledgeBase else { return }
        let panel = NSOpenPanel()
        panel.title = "用媒体搜索"
        panel.message = "选择本机图片、音频或视频，按文件内容搜索「\(base.name)」。不按扩展名筛选，全部片段参与检索；此文件不会导入资料库。"
        panel.prompt = "搜索"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = false
        let token = UUID()
        mediaSearchPanelToken = token
        mediaSearchPanel = panel
        isChoosingSearchMedia = true
        searchNotice = nil
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let selectedURL = panel.url
            Task { @MainActor in
                guard let self, self.mediaSearchPanelToken == token else { return }
                self.mediaSearchPanelToken = nil
                self.mediaSearchPanel = nil
                self.isChoosingSearchMedia = false
                guard self.selectedKnowledgeBaseID == base.id else { return }
                guard response == .OK, let selectedURL else {
                    self.searchNotice = "已取消选择媒体文件，当前查询保持不变。"
                    return
                }
                self.selectSearchMedia(selectedURL)
                self.runSearch()
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func selectSearchMedia(_ url: URL) {
        guard url.isFileURL else {
            searchError = "媒体搜索只接受本机文件。"
            return
        }
        discardSearch()
        searchMediaURL = url
        clearSearchResults()
    }

    func useTextSearch() {
        discardSearch()
        searchMediaURL = nil
        clearSearchResults()
    }

    private func clearSearchResults() {
        searchResults = []
        hasSearched = false
        searchedQuery = ""
        searchedInput = nil
        searchError = nil
        searchNotice = nil
    }

    func runSearch() {
        guard canSearch, let baseID = selectedKnowledgeBaseID, let engine else { return }
        let input: SearchInput = searchMediaURL.map(SearchInput.media)
            ?? .text(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        let token = UUID()
        searchToken = token
        searchedInput = input
        if case .text(let query) = input { searchedQuery = query } else { searchedQuery = "" }
        searchResults = []
        hasSearched = true
        searchError = nil
        searchNotice = nil
        isSearching = true
        isCancellingSearch = false
        searchTask = Task {
            let scopedURL: URL?
            if case .media(let url) = input, url.startAccessingSecurityScopedResource() { scopedURL = url }
            else { scopedURL = nil }
            defer { scopedURL?.stopAccessingSecurityScopedResource() }
            do {
                let results: [SearchResult]
                switch input {
                case .text(let query):
                    results = try await engine.search(query: query, knowledgeBaseID: baseID)
                case .media(let url):
                    results = try await engine.search(mediaURL: url, knowledgeBaseID: baseID)
                }
                try Task.checkCancellation()
                guard searchToken == token, selectedKnowledgeBaseID == baseID else { return }
                let currentDocumentIDs = Set(documents.map(\.id))
                searchResults = results.filter { currentDocumentIDs.contains($0.documentID) }
            } catch {
                guard searchToken == token, selectedKnowledgeBaseID == baseID else { return }
                if error is CancellationError || Task.isCancelled {
                    hasSearched = false
                    searchNotice = "搜索已取消。查询已保留，可再次搜索。"
                } else {
                    searchError = error.localizedDescription
                }
            }
            guard searchToken == token else { return }
            isSearching = false
            isCancellingSearch = false
            searchTask = nil
            searchToken = nil
        }
    }

    func cancelSearch() {
        guard isSearching else { return }
        isCancellingSearch = true
        searchTask?.cancel()
    }

    private func discardSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchToken = nil
        if isSearching { hasSearched = false }
        isSearching = false
        isCancellingSearch = false
    }

    func selectConversation(_ id: String?) {
        guard id != selectedConversationID || id == nil else { return }
        chatDrafts[chatDraftKey] = chatDraft
        abandonAnswer()
        messageTask?.cancel()
        messageToken = nil
        selectedConversationID = id
        messages = []
        chatError = nil
        chatNotice = nil
        chatDraft = chatDrafts[chatDraftKey] ?? ""
        guard let id, let engine else { isLoadingMessages = false; return }
        let token = UUID()
        messageToken = token
        isLoadingMessages = true
        messageTask = Task {
            do {
                let loaded = try await engine.messages(conversationID: id)
                guard messageToken == token, !Task.isCancelled else { return }
                messages = loaded
            } catch {
                guard messageToken == token, !Task.isCancelled else { return }
                chatError = error.localizedDescription
            }
            if messageToken == token { isLoadingMessages = false }
        }
    }

    func ask() {
        guard canAsk, let baseID = selectedKnowledgeBaseID, let engine else { return }
        let question = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = UUID()
        let existingConversationID = selectedConversationID
        answerToken = token
        answeringKnowledgeBaseID = baseID
        isAnswering = true
        isCancellingAnswer = false
        answerStartedAt = Date()
        pendingQuestion = question
        chatError = nil
        chatNotice = nil
        chatDraft = ""
        chatDrafts[chatDraftKey] = ""
        answerTask = Task {
            var conversationID = existingConversationID
            do {
                if conversationID == nil {
                    let created = try await engine.createConversation(knowledgeBaseID: baseID, title: question)
                    conversationID = created.id
                    guard answerToken == token else { return }
                    selectedConversationID = created.id
                    try Task.checkCancellation()
                    await refresh(showErrors: false)
                }
                try Task.checkCancellation()
                guard let conversationID else { return }
                _ = try await engine.ask(question: question, conversationID: conversationID, knowledgeBaseID: baseID)
            } catch {
                guard answerToken == token else { return }
                if error is CancellationError || Task.isCancelled {
                    chatNotice = "已停止本次请求。你可以修改问题后再次发送。"
                } else {
                    chatError = error.localizedDescription
                }
                if chatDraft.isEmpty { chatDraft = question }
            }
            guard answerToken == token else { return }
            if let conversationID {
                do { messages = try await engine.messages(conversationID: conversationID) }
                catch { chatError = error.localizedDescription }
            }
            guard answerToken == token else { return }
            pendingQuestion = nil
            isAnswering = false
            isCancellingAnswer = false
            answerStartedAt = nil
            answeringKnowledgeBaseID = nil
            answerTask = nil
            await refresh(showErrors: false)
        }
    }

    func cancelAnswer() {
        guard isAnswering else { return }
        isCancellingAnswer = true
        answerTask?.cancel()
    }

    private func abandonAnswer() {
        if let question = pendingQuestion, chatDrafts[chatDraftKey, default: ""].isEmpty {
            chatDrafts[chatDraftKey] = question
        }
        answerTask?.cancel()
        answerTask = nil
        answerToken = nil
        pendingQuestion = nil
        isAnswering = false
        isCancellingAnswer = false
        answerStartedAt = nil
        answeringKnowledgeBaseID = nil
    }

    func createNote() {
        guard let baseID = selectedKnowledgeBaseID, let engine, !isCreatingNote else { return }
        isCreatingNote = true
        Task {
            defer { isCreatingNote = false }
            let note = LibraryNote(knowledgeBaseID: baseID, title: "未命名笔记", body: "")
            do {
                try await engine.saveNote(note)
                await refresh()
                if selectedKnowledgeBaseID == baseID {
                    selectedNoteID = note.id
                    section = .notes
                }
            } catch { showError("无法创建笔记", error) }
        }
    }

    func note(for id: String) -> LibraryNote? {
        noteDrafts[id] ?? snapshot.notes.first { $0.id == id }
    }

    func editNote(id: String, title: String? = nil, body: String? = nil) {
        guard !notesBeingRemoved.contains(id), var note = note(for: id) else { return }
        if let title { note.title = title }
        if let body { note.body = body }
        note.updatedAt = Date()
        noteDrafts[id] = note
        noteRevisions[id, default: 0] += 1
        noteSaveStates[id] = .pending
        startNoteSave(id, immediate: false)
    }

    func saveNoteNow(_ id: String) {
        guard noteDrafts[id] != nil else { return }
        startNoteSave(id, immediate: true)
    }

    private func startNoteSave(_ id: String, immediate: Bool) {
        guard noteTasks[id] == nil, !notesBeingRemoved.contains(id), let engine else { return }
        // One writer per note. Edits made during a write stay in the draft and are saved next.
        noteTasks[id] = Task {
            var wait = !immediate
            while !Task.isCancelled, !notesBeingRemoved.contains(id), noteDrafts[id] != nil {
                if wait {
                    do { try await Task.sleep(for: .milliseconds(650)) }
                    catch { break }
                }
                guard !Task.isCancelled, !notesBeingRemoved.contains(id),
                      var draft = noteDrafts[id] else { break }
                let revision = noteRevisions[id, default: 0]
                if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft.title = "未命名笔记"
                }
                noteSaveStates[id] = .saving
                do {
                    try await engine.saveNote(draft)
                    refreshRevision += 1
                    if let index = snapshot.notes.firstIndex(where: { $0.id == id }) {
                        snapshot.notes[index] = draft
                    }
                    if noteRevisions[id] == revision {
                        noteDrafts[id] = nil
                        noteSaveStates[id] = .saved
                    } else {
                        noteSaveStates[id] = .pending
                    }
                } catch {
                    if !Task.isCancelled { noteSaveStates[id] = .failed(error.localizedDescription) }
                    break
                }
                wait = true
            }
            noteTasks[id] = nil
        }
    }

    func flushNotes() async -> Bool {
        for id in Array(noteDrafts.keys) { startNoteSave(id, immediate: true) }
        let tasks = Array(noteTasks.values)
        for task in tasks { await task.value }
        return noteDrafts.isEmpty
    }

    func knowledgeBaseIsBusy(_ id: String) -> Bool {
        importActivity?.knowledgeBaseID == id || answeringKnowledgeBaseID == id
            || snapshot.documents.contains { $0.knowledgeBaseID == id && reindexingDocumentIDs.contains($0.id) }
    }

    func requestDelete(_ base: KnowledgeBase) {
        guard !knowledgeBaseIsBusy(base.id) else { return }
        let documentCount = snapshot.documents.filter { $0.knowledgeBaseID == base.id }.count
        let noteCount = snapshot.notes.filter { $0.knowledgeBaseID == base.id }.count
        let conversationCount = snapshot.conversations.filter { $0.knowledgeBaseID == base.id }.count
        deletion = DeletionRequest(
            target: .knowledgeBase(base), title: "删除「\(base.name)」？",
            explanation: "这会永久删除此库的 \(documentCount) 份资料及应用内副本、\(noteCount) 篇笔记和 \(conversationCount) 段对话。你最初选择的文件不会被删除。此操作无法撤销。"
        )
    }

    func requestDelete(_ document: LibraryDocument) {
        deletion = DeletionRequest(
            target: .document(document), title: "删除「\(document.title)」？",
            explanation: "这份资料、检索索引和应用内文件副本将被永久删除，历史问答中的相关来源会失效。你最初选择的文件不会被删除。此操作无法撤销。"
        )
    }

    func requestDelete(_ note: LibraryNote) {
        deletion = DeletionRequest(
            target: .note(note), title: "删除「\(note.title.isEmpty ? "未命名笔记" : note.title)」？",
            explanation: "笔记正文及尚未保存的修改将被永久删除。此操作无法撤销。"
        )
    }

    func requestDelete(_ conversation: Conversation) {
        deletion = DeletionRequest(
            target: .conversation(conversation), title: "删除这段对话？",
            explanation: "「\(conversation.title)」的所有问题、回答与已保存的引用将被永久删除。知识库资料不受影响。此操作无法撤销。"
        )
    }

    func confirmDelete(_ request: DeletionRequest) {
        guard let engine, !isDeleting else { return }
        deletion = nil
        isDeleting = true
        Task {
            defer { isDeleting = false }
            var stoppedNoteIDs: [String] = []
            do {
                switch request.target {
                case .knowledgeBase(let base):
                    guard !knowledgeBaseIsBusy(base.id) else {
                        throw AskBaseError.invalidInput("此知识库仍有任务在运行，请等待完成或停止任务后删除。")
                    }
                    let noteIDs = snapshot.notes.filter { $0.knowledgeBaseID == base.id }.map(\.id)
                    if selectedKnowledgeBaseID == base.id {
                        discardSearch()
                        selectedDocumentID = nil
                        if case .source = sheet { sheet = nil }
                    }
                    stoppedNoteIDs = noteIDs
                    await stopNoteWriters(noteIDs)
                    defer { notesBeingRemoved.subtract(noteIDs) }
                    try await engine.deleteKnowledgeBase(id: base.id)
                    noteIDs.forEach { noteDrafts[$0] = nil; noteSaveStates[$0] = nil }
                case .document(let document):
                    guard document.status != .indexing, !reindexingDocumentIDs.contains(document.id) else {
                        throw AskBaseError.invalidInput("资料正在建立索引，请等待完成后删除。")
                    }
                    if selectedDocumentID == document.id { selectedDocumentID = nil }
                    if case .source(let source) = sheet, source.documentID == document.id { sheet = nil }
                    discardSearch()
                    try await engine.deleteDocument(id: document.id)
                    searchResults.removeAll { $0.documentID == document.id }
                case .note(let note):
                    stoppedNoteIDs = [note.id]
                    await stopNoteWriters([note.id])
                    defer { notesBeingRemoved.remove(note.id) }
                    try await engine.deleteNote(id: note.id)
                    noteDrafts[note.id] = nil
                    noteSaveStates[note.id] = nil
                case .conversation(let conversation):
                    if selectedConversationID == conversation.id {
                        selectConversation(nil)
                    }
                    try await engine.deleteConversation(id: conversation.id)
                    chatDrafts[conversation.id] = nil
                }
                await refresh()
                if let id = selectedConversationID {
                    messages = try await engine.messages(conversationID: id)
                }
            } catch {
                for id in stoppedNoteIDs where noteDrafts[id] != nil {
                    noteSaveStates[id] = .failed("删除未完成，编辑内容仍保留。\(error.localizedDescription)")
                }
                showError("删除未完成", error)
            }
        }
    }

    private func stopNoteWriters(_ ids: [String]) async {
        notesBeingRemoved.formUnion(ids)
        for id in ids { noteTasks[id]?.cancel() }
        for id in ids { await noteTasks[id]?.value }
    }

    func checkConnections() async {
        guard let engine, !isCheckingConnections else { return }
        let token = UUID()
        connectionToken = token
        isCheckingConnections = true
        let result = await engine.modelStatus()
        guard connectionToken == token else { return }
        modelStatus = result
        connectionCheckedAt = Date()
        modelSelectionError = nil
        let models = Array(Set(result.chatModels)).sorted()
        if result.chatAvailable, models.count == 1, settings.chatModel.isEmpty {
            var configured = settings
            configured.chatModel = models[0]
            do {
                try await engine.saveSettings(configured)
                settings = configured
                modelSelectionNotice = "已自动选择本机唯一回答模型：\(models[0])"
            } catch {
                modelSelectionError = "已发现回答模型，但未能保存选择：\(error.localizedDescription)"
            }
        }
        isCheckingConnections = false
    }

    func applySettings(_ draft: AppSettings, testConnections: Bool) async throws {
        guard let engine else { throw AskBaseError.storage("资料库尚未打开。") }
        guard !settingsAreLocked, !isCheckingConnections, !isSavingSettings else {
            throw AskBaseError.invalidInput("请等待当前任务完成后修改模型设置。")
        }
        isSavingSettings = true
        defer { isSavingSettings = false }
        var saved = draft
        saved.embeddingBaseURL = saved.embeddingBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.ollamaBaseURL = saved.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.chatModel = saved.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        try await engine.saveSettings(saved)
        let endpointsChanged = saved.embeddingBaseURL != settings.embeddingBaseURL
            || saved.ollamaBaseURL != settings.ollamaBaseURL
        if saved.chatModel != settings.chatModel { modelSelectionNotice = nil }
        settings = saved
        if endpointsChanged {
            modelStatus = nil
            connectionCheckedAt = nil
        }
        if testConnections { await checkConnections() }
    }

    func exportNote(_ note: LibraryNote) {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? "未命名笔记" : title
        exportMarkdown("# \(name)\n\n\(note.body)\n", name: name)
    }

    func exportConversation() {
        guard !messages.isEmpty, let id = selectedConversationID,
              let conversation = snapshot.conversations.first(where: { $0.id == id }) else { return }
        var text = "# \(conversation.title)\n\n"
        if let base = selectedKnowledgeBase { text += "知识库：\(base.name)\n\n" }
        for message in messages {
            text += "## \(message.role == "user" ? "你" : "AskBase")\n\n\(message.content)\n\n"
            if !message.sources.isEmpty {
                text += "### 本轮引用来源\n\n"
                for (index, source) in message.sources.enumerated() {
                    text += "[\(index + 1)] \(source.sourceLabel)\n\n"
                    text += source.text.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
                    text += "\n\n"
                }
            }
        }
        exportMarkdown(text, name: conversation.title)
    }

    private func exportMarkdown(_ content: String, name: String) {
        let panel = NSSavePanel()
        panel.title = "导出 Markdown"
        panel.prompt = "导出"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        let forbidden = CharacterSet(charactersIn: "/\\:\n\r")
        let safeName = name.components(separatedBy: forbidden).joined(separator: "-")
        panel.nameFieldStringValue = String(safeName.prefix(80)) + ".md"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    try await Task.detached {
                        try content.write(to: url, atomically: true, encoding: .utf8)
                    }.value
                    self?.notice = "已导出「\(url.lastPathComponent)」。"
                } catch { self?.showError("导出失败", error) }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func prepareToQuit() async -> Bool {
        cancelSearch()
        cancelAnswer()
        cancelImport()
        reindexTask?.cancel()
        return await flushNotes()
    }
}
