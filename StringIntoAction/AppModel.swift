import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var projectURL: URL?
    private(set) var rememberedProjects: [URL]
    private(set) var showsProjectsSidebar: Bool
    private(set) var occurrences: [StringOccurrence] = []
    private(set) var filesScanned = 0
    private(set) var isScanning = false
    private(set) var stringEditorFocusRequest = 0
    var selectedID: String?
    var filter: ReviewFilter = .needsReview
    var searchText = ""
    var presentedError: String?
    var isApproveAllConfirmationPresented = false

    private var approvals: [String: ApprovalRecord] = [:]
    private var ignores: [String: IgnoreRecord] = [:]
    private var snapshots: [OccurrenceSnapshot] = []
    private var reviewSchemaVersion = 2

    private var reviewData: ProjectReviewData {
        ProjectReviewData(approvals: approvals, ignores: ignores, schemaVersion: reviewSchemaVersion, snapshots: snapshots)
    }
    private let scan: @Sendable (URL) async -> ScanResult
    private let reviewStore: ReviewStore
    private let remembersProject: Bool
    private let sourceEditor = SourceEditor()
    private var scanGeneration = UUID()

    init(reviewStore: ReviewStore = ReviewStore(), remembersProject: Bool = true,
         scan: @escaping @Sendable (URL) async -> ScanResult = { url in
             await Task.detached(priority: .userInitiated) { StringScanner().scan(projectURL: url) }.value
         }) {
        let history = ProjectHistory()
        self.reviewStore = reviewStore
        self.remembersProject = remembersProject
        self.scan = scan
        self.rememberedProjects = remembersProject ? history.projectURLs : []
        self.showsProjectsSidebar = remembersProject ? history.showsProjectsSidebar : true
        if remembersProject, let previous = history.lastProjectURL {
            Task {
                guard projectURL == nil else { return }
                await openProject(previous)
            }
        }
    }

    var selectedOccurrence: StringOccurrence? {
        occurrences.first { $0.id == selectedID }
    }

    var canEditSelectedString: Bool {
        guard let selectedOccurrence else { return false }
        return !isScanning && selectedOccurrence.isEditable && reviewState(for: selectedOccurrence) != .ignored
    }

    var canIgnoreSelectedString: Bool {
        guard let selectedOccurrence else { return false }
        return !isScanning && reviewState(for: selectedOccurrence) != .ignored
    }

    var filteredOccurrences: [StringOccurrence] {
        occurrences
            .filter { occurrence in
                let state = reviewState(for: occurrence)
                switch filter {
                case .needsReview: return state == .needsReview || state == .changed
                case .all: return true
                case .approved: return state == .approved
                case .ignored: return state == .ignored
                }
            }
            .filter { occurrence in
                guard !searchText.isEmpty else { return true }
                return occurrence.value.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { lhs, rhs in
                let lhsState = reviewState(for: lhs)
                let rhsState = reviewState(for: rhs)
                if lhsState != rhsState { return lhsState < rhsState }
                if lhs.relativePath != rhs.relativePath {
                    return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
                }
                return lhs.line < rhs.line
            }
    }

    var sidebarNodes: [SidebarNode] {
        SidebarTreeBuilder.build(from: filteredOccurrences)
    }

    var approvedCount: Int {
        occurrences.lazy.filter { self.reviewState(for: $0) == .approved }.count
    }

    var reviewCount: Int {
        occurrences.lazy.filter {
            let state = self.reviewState(for: $0)
            return state == .needsReview || state == .changed
        }.count
    }

    var canApproveAllQueuedStrings: Bool {
        projectURL != nil && !isScanning && reviewCount > 0
    }

    var approveAllConfirmationMessage: String {
        let noun = reviewCount == 1 ? "string" : "strings"
        return "This will approve all \(reviewCount) \(noun) currently waiting for review."
    }

    var ignoredCount: Int {
        occurrences.lazy.filter { self.reviewState(for: $0) == .ignored }.count
    }

    private var includedCount: Int { occurrences.count - ignoredCount }

    var progress: Double {
        guard includedCount > 0 else { return 0 }
        return Double(approvedCount) / Double(includedCount)
    }

    func reviewState(for occurrence: StringOccurrence) -> ReviewState {
        if ignores[occurrence.ignoreID] != nil { return .ignored }
        guard let approval = approvals[occurrence.id] else {
            return .needsReview
        }
        return approval.fingerprint == fingerprint(for: occurrence) ? .approved : .changed
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project to review"
        panel.message = "String Into Action scans source files without changing them until you save an edit."
        panel.prompt = "Open Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = projectURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openProject(url) }
    }

    @discardableResult
    func addDroppedProjects(_ urls: [URL]) -> Bool {
        var seenPaths: Set<String> = []
        let projectURLs = urls.compactMap { droppedProjectURL(for: $0) }.filter {
            seenPaths.insert($0.path).inserted
        }
        guard let projectToOpen = projectURLs.first else { return false }

        if remembersProject {
            let history = ProjectHistory()
            for projectURL in projectURLs { history.remember(projectURL) }
            rememberedProjects = history.projectURLs
        }
        Task { await openProject(projectToOpen) }
        return true
    }

    func openProject(_ url: URL) async {
        let url = url.standardizedFileURL
        let storedReview: ProjectReviewData
        do { storedReview = try reviewStore.load(projectURL: url) }
        catch {
            presentedError = "Couldn’t load review status: \(error.localizedDescription)"
            return
        }
        projectURL = url
        if remembersProject {
            let history = ProjectHistory()
            history.remember(url)
            rememberedProjects = history.projectURLs
        }
        occurrences = []
        filesScanned = 0
        approvals = storedReview.approvals
        ignores = storedReview.ignores
        snapshots = storedReview.snapshots
        reviewSchemaVersion = storedReview.schemaVersion
        selectedID = nil
        await performScan()
    }

    func forgetProject(_ url: URL) {
        guard remembersProject else { return }
        let url = url.standardizedFileURL
        let wasOpen = projectURL == url
        let history = ProjectHistory()
        history.forget(url)
        rememberedProjects = history.projectURLs

        guard wasOpen else { return }
        closeCurrentProject()
        if let replacement = rememberedProjects.last {
            Task { await openProject(replacement) }
        }
    }

    func moveProject(at sourcePath: String, relativeTo destinationURL: URL, placingAfter: Bool) {
        guard let sourceIndex = rememberedProjects.firstIndex(where: { $0.path == sourcePath }),
              rememberedProjects[sourceIndex] != destinationURL else { return }

        var reordered = rememberedProjects
        let sourceURL = reordered.remove(at: sourceIndex)
        guard let destinationIndex = reordered.firstIndex(of: destinationURL) else { return }
        let insertionIndex = destinationIndex + (placingAfter ? 1 : 0)
        reordered.insert(sourceURL, at: insertionIndex)
        guard reordered != rememberedProjects else { return }

        rememberedProjects = reordered
        if remembersProject { ProjectHistory().setProjectOrder(reordered) }
    }

    func toggleProjectsSidebar() {
        setProjectsSidebarVisible(!showsProjectsSidebar)
    }

    func setProjectsSidebarVisible(_ isVisible: Bool) {
        guard showsProjectsSidebar != isVisible else { return }
        showsProjectsSidebar = isVisible
        if remembersProject { ProjectHistory().showsProjectsSidebar = isVisible }
    }

    func refresh() {
        guard !isScanning, let projectURL else { return }
        let generation = scanGeneration
        let selection = selectedID
        isScanning = true
        Task {
            guard self.projectURL == projectURL, scanGeneration == generation else { return }
            await performScan(preservingSelection: selection)
        }
    }

    func focusStringEditor() {
        guard canEditSelectedString else { return }
        stringEditorFocusRequest &+= 1
    }

    func ignoreSelectedString() {
        guard canIgnoreSelectedString, let selectedOccurrence else { return }
        ignore(selectedOccurrence)
    }

    func requestApproveAllQueuedStrings() {
        guard canApproveAllQueuedStrings else { return }
        isApproveAllConfirmationPresented = true
    }

    func cancelApproveAllQueuedStrings() {
        isApproveAllConfirmationPresented = false
    }

    func confirmApproveAllQueuedStrings() {
        guard isApproveAllConfirmationPresented else { return }
        isApproveAllConfirmationPresented = false
        approveAllQueuedStrings()
    }

    func approve(_ occurrence: StringOccurrence) {
        guard canModify(occurrence) else { return }
        let previous = reviewData
        ignores.removeValue(forKey: occurrence.ignoreID)
        approvals[occurrence.id] = ApprovalRecord(
            fingerprint: fingerprint(for: occurrence),
            approvedAt: Date()
        )
        guard persistApprovals(rollingBackTo: previous) else { return }
        selectNext(after: occurrence)
    }

    func approveAllQueuedInFile(containing occurrence: StringOccurrence) {
        guard canModify(occurrence) else { return }
        let queued = occurrences.filter { candidate in
            guard candidate.fileURL == occurrence.fileURL else { return false }
            let state = reviewState(for: candidate)
            return switch filter {
            case .needsReview: state == .needsReview || state == .changed
            case .all: state == .needsReview || state == .changed
            case .approved, .ignored: false
            }
        }
        guard !queued.isEmpty else { return }

        let previous = reviewData
        let approvedAt = Date()
        for candidate in queued {
            ignores.removeValue(forKey: candidate.ignoreID)
            approvals[candidate.id] = ApprovalRecord(
                fingerprint: fingerprint(for: candidate),
                approvedAt: approvedAt
            )
        }
        guard persistApprovals(rollingBackTo: previous) else { return }
        selectNext(after: occurrence)
    }

    private func approveAllQueuedStrings() {
        guard canApproveAllQueuedStrings else { return }
        let queued = occurrences.filter {
            let state = reviewState(for: $0)
            return state == .needsReview || state == .changed
        }
        guard !queued.isEmpty else { return }

        let previous = reviewData
        let approvedAt = Date()
        for occurrence in queued {
            ignores.removeValue(forKey: occurrence.ignoreID)
            approvals[occurrence.id] = ApprovalRecord(
                fingerprint: fingerprint(for: occurrence),
                approvedAt: approvedAt
            )
        }
        guard persistApprovals(rollingBackTo: previous) else { return }
        ensureSelectionIsVisible()
    }

    func markForReview(_ occurrence: StringOccurrence) {
        guard canModify(occurrence) else { return }
        let previous = reviewData
        approvals.removeValue(forKey: occurrence.id)
        guard persistApprovals(rollingBackTo: previous) else { return }
        ensureSelectionIsVisible()
    }

    func ignore(_ occurrence: StringOccurrence) {
        guard canModify(occurrence) else { return }
        let previous = reviewData
        approvals.removeValue(forKey: occurrence.id)
        ignores[occurrence.ignoreID] = IgnoreRecord(ignoredAt: Date())
        guard persistApprovals(rollingBackTo: previous) else { return }
        selectNext(after: occurrence)
    }

    func restoreIgnored(_ occurrence: StringOccurrence) {
        guard canModify(occurrence) else { return }
        let previous = reviewData
        ignores.removeValue(forKey: occurrence.ignoreID)
        guard persistApprovals(rollingBackTo: previous) else { return }
        ensureSelectionIsVisible()
    }

    func saveAndApprove(_ value: String, for occurrence: StringOccurrence) {
        guard canModify(occurrence) else {
            presentedError = SourceEditorError.sourceChanged.localizedDescription
            return
        }
        do {
            try sourceEditor.replace(occurrence, with: value)
            let previous = reviewData
            ignores.removeValue(forKey: occurrence.ignoreID)
            // Bind approval to the bytes we wrote before yielding. A later scan may
            // belong to another project, or reflect a concurrent external edit.
            approvals[occurrence.id] = ApprovalRecord(
                fingerprint: Hashing.sha256(LiteralCodec.encode(value, style: occurrence.style)),
                approvedAt: Date()
            )
            if let index = snapshots.firstIndex(where: { $0.id == occurrence.id }) {
                snapshots[index].fingerprint = Hashing.sha256(LiteralCodec.encode(value, style: occurrence.style))
            }
            _ = persistApprovals(rollingBackTo: previous)
            refresh()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func canModify(_ occurrence: StringOccurrence) -> Bool {
        !isScanning && occurrences.contains(occurrence)
    }

    func revealInFinder(_ occurrence: StringOccurrence) {
        NSWorkspace.shared.activateFileViewerSelecting([occurrence.fileURL])
    }

    func openInDefaultEditor(_ occurrence: StringOccurrence) {
        NSWorkspace.shared.open(occurrence.fileURL)
    }

    func ensureSelectionIsVisible() {
        let visible = filteredOccurrences
        if let selectedID, visible.contains(where: { $0.id == selectedID }) { return }
        selectedID = visible.first?.id
    }

    private func performScan(preservingSelection desiredSelection: String? = nil) async {
        guard let projectURL else { return }
        let generation = UUID()
        scanGeneration = generation
        isScanning = true
        let result = await scan(projectURL)
        guard generation == scanGeneration, self.projectURL == projectURL else { return }
        let reconciled = OccurrenceMatcher().reconcile(result.occurrences, with: reviewData)
        occurrences = reconciled.occurrences
        approvals = reconciled.approvals
        ignores = reconciled.ignores
        snapshots = occurrences.map(OccurrenceSnapshot.init)
        reviewSchemaVersion = 2
        do {
            try reviewStore.save(reviewData, projectURL: projectURL)
        } catch {
            presentedError = "Couldn’t save string tracking: \(error.localizedDescription)"
        }
        filesScanned = result.filesScanned
        isScanning = false

        if let desiredSelection, filteredOccurrences.contains(where: { $0.id == desiredSelection }) {
            selectedID = desiredSelection
        } else {
            selectedID = filteredOccurrences.first?.id
        }
    }

    private func closeCurrentProject() {
        scanGeneration = UUID()
        projectURL = nil
        occurrences = []
        filesScanned = 0
        approvals = [:]
        ignores = [:]
        snapshots = []
        reviewSchemaVersion = 2
        selectedID = nil
        isScanning = false
    }

    private func droppedProjectURL(for droppedURL: URL) -> URL? {
        var url = droppedURL.standardizedFileURL
        if ["xcodeproj", "xcworkspace"].contains(url.pathExtension.lowercased()) {
            url.deleteLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    private func fingerprint(for occurrence: StringOccurrence) -> String {
        Hashing.sha256(occurrence.rawValue)
    }

    private func persistApprovals(rollingBackTo previous: ProjectReviewData) -> Bool {
        guard let projectURL else { return false }
        do {
            try reviewStore.save(
                reviewData,
                projectURL: projectURL
            )
            return true
        } catch {
            approvals = previous.approvals
            ignores = previous.ignores
            snapshots = previous.snapshots
            presentedError = "Couldn’t save review status: \(error.localizedDescription)"
            return false
        }
    }

    private func selectNext(after occurrence: StringOccurrence) {
        let remaining = filteredOccurrences
        if let next = remaining.first(where: { $0.id != occurrence.id }) {
            selectedID = next.id
        } else {
            selectedID = nil
        }
    }
}
