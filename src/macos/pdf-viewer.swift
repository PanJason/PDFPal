import AppKit
import PDFKit
import SwiftUI

enum PDFAnnotationAction: String {
    case highlightYellow
    case highlightGreen
    case highlightBlue
    case highlightPink
    case highlightPurple
    case underline
    case strikeOut
}

enum PDFSearchMode: String, CaseIterable, Identifiable {
    case anyMatch
    case exactPhrase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyMatch:
            return "Any Match"
        case .exactPhrase:
            return "Exact Phrase"
        }
    }
}

enum PDFSidebarMode: String, CaseIterable, Identifiable {
    case hidden
    case thumbnails
    case tableOfContents
    case highlightsAndNotes
    case bookmarks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hidden:
            return "Hide Sidebar"
        case .thumbnails:
            return "Thumbnails"
        case .tableOfContents:
            return "Table of contents"
        case .highlightsAndNotes:
            return "Highlights and Notes"
        case .bookmarks:
            return "Bookmarks (TODO)"
        }
    }
}

extension Notification.Name {
    static let pdfSetAnnotationAction = Notification.Name("PDFSetAnnotationAction")
    static let pdfHighlighterPrimaryAction = Notification.Name("PDFHighlighterPrimaryAction")
    static let pdfHighlighterModeChanged = Notification.Name("PDFHighlighterModeChanged")
    static let pdfAnnotationsDidChange = Notification.Name("PDFAnnotationsDidChange")
    static let pdfSaveDocument = Notification.Name("PDFSaveDocument")
    static let pdfFocusSearch = Notification.Name("PDFFocusSearch")
    static let pdfSearchNext = Notification.Name("PDFSearchNext")
    static let pdfSearchPrevious = Notification.Name("PDFSearchPrevious")
}

struct PDFViewer: View {
    let fileURL: URL?
    let onAskLLM: (String) -> Void
    let searchQuery: String
    let searchMode: PDFSearchMode
    let sidebarMode: PDFSidebarMode

    @State private var document: PDFDocument? = nil
    @State private var loadErrorMessage: String? = nil

    var body: some View {
        ZStack {
            if let document = document {
                PDFKitContainer(
                    document: document,
                    onAskLLM: onAskLLM,
                    searchQuery: searchQuery,
                    searchMode: searchMode,
                    sidebarMode: sidebarMode
                )
                    .id(document.documentURL?.path ?? UUID().uuidString)
            } else if let errorMessage = loadErrorMessage {
                PDFEmptyState(
                    title: "Unable to open PDF",
                    message: errorMessage
                )
            } else {
                PDFEmptyState(
                    title: "No PDF opened yet",
                    message: "Use the Open PDF button to choose a local file."
                )
            }
        }
        .onAppear {
            loadDocument(url: fileURL)
        }
        .onChange(of: fileURL) { newURL in
            loadDocument(url: newURL)
        }
    }

    private func loadDocument(url: URL?) {
        guard let url else {
            document = nil
            loadErrorMessage = nil
            return
        }

        document = nil
        loadErrorMessage = nil
        if let loadedDocument = PDFDocument(url: url) {
            document = loadedDocument
        } else {
            loadErrorMessage = "The selected file could not be read as a PDF."
        }
    }
}

struct PDFKitContainer: NSViewRepresentable {
    let document: PDFDocument
    let onAskLLM: (String) -> Void
    let searchQuery: String
    let searchMode: PDFSearchMode
    let sidebarMode: PDFSidebarMode

    func makeNSView(context: Context) -> PDFReaderContainerView {
        let container = PDFReaderContainerView()
        container.update(
            document: document,
            onAskLLM: onAskLLM,
            searchQuery: searchQuery,
            searchMode: searchMode,
            sidebarMode: sidebarMode
        )
        return container
    }

    func updateNSView(_ container: PDFReaderContainerView, context: Context) {
        container.update(
            document: document,
            onAskLLM: onAskLLM,
            searchQuery: searchQuery,
            searchMode: searchMode,
            sidebarMode: sidebarMode
        )
    }
}

private final class SidebarSplitView: NSSplitView {
    var onSubviewsResized: (() -> Void)?
    // When non-zero, the leading subview is prevented from collapsing below this width.
    // NSSplitView restores autosaved positions inside adjustSubviews, so enforcing here
    // catches autosave restores that would otherwise collapse the sidebar to 0.
    var minimumLeadingWidth: CGFloat = 0
    private var isEnforcingMinimum = false

    override func adjustSubviews() {
        super.adjustSubviews()
        if !isEnforcingMinimum,
           minimumLeadingWidth > 0,
           subviews.count >= 2,
           !(subviews[0].isHidden),
           subviews[0].frame.width < minimumLeadingWidth {
            isEnforcingMinimum = true
            setPosition(minimumLeadingWidth, ofDividerAt: 0)
            isEnforcingMinimum = false
        }
        onSubviewsResized?()
    }
}

final class PDFReaderContainerView: NSView {
    private let splitView = SidebarSplitView()
    private let sidebarContainer = NSView()
    private let pdfView = PDFKitView()
    private let thumbnailView = PDFThumbnailView()

    private var currentSidebarMode: PDFSidebarMode = .hidden
    private weak var currentDocument: PDFDocument?
    private let sidebarWidth: CGFloat = 180
    private var sidebarFrameObserver: NSObjectProtocol?
    private var annotationsChangedObserver: NSObjectProtocol?
    private var thumbnailWarmupWorkItem: DispatchWorkItem?
    private var thumbnailWarmupAttemptsRemaining: Int = 0
    private var thumbnailRefreshWorkItem: DispatchWorkItem?
    private var annotationSidebarMonitorTimer: Timer?
    private var lastAnnotationSidebarSignature: String?
    private var hasBoundThumbnailView = false
    private let thumbnailResizeSettleDelay: TimeInterval = 0.18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    deinit {
        if let sidebarFrameObserver {
            NotificationCenter.default.removeObserver(sidebarFrameObserver)
        }
        if let annotationsChangedObserver {
            NotificationCenter.default.removeObserver(annotationsChangedObserver)
        }
        thumbnailWarmupWorkItem?.cancel()
        thumbnailRefreshWorkItem?.cancel()
        annotationSidebarMonitorTimer?.invalidate()
    }

    func update(
        document: PDFDocument,
        onAskLLM: @escaping (String) -> Void,
        searchQuery: String,
        searchMode: PDFSearchMode,
        sidebarMode: PDFSidebarMode
    ) {
        let documentChanged = pdfView.document !== document
        if documentChanged {
            pdfView.document = document
            hasBoundThumbnailView = false
            lastAnnotationSidebarSignature = nil
        }

        pdfView.onAskLLM = onAskLLM
        pdfView.updateSearch(query: searchQuery, mode: searchMode)

        if documentChanged || sidebarMode != currentSidebarMode {
            currentDocument = document
            currentSidebarMode = sidebarMode
            configureSidebar(mode: sidebarMode, document: document)
        } else if sidebarMode == .highlightsAndNotes {
            // Keep this list reasonably fresh while the user interacts with annotations.
            configureSidebar(mode: sidebarMode, document: document)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Defer until after NSSplitView has applied its autosaved divider position,
        // which can override the setPosition calls made during initial setup.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentSidebarMode != .hidden else { return }
            self.enforceMinimumSidebarWidthIfNeeded()
            if self.currentSidebarMode == .thumbnails {
                self.refreshThumbnailViewIfReady(forceRebind: true)
            }
        }
    }

    private func setupViews() {
        wantsLayer = true

        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "PDFReaderContainerSplitView"
        splitView.onSubviewsResized = { [weak self] in
            guard let self else { return }
            if self.currentSidebarMode == .thumbnails {
                self.scheduleThumbnailRefreshAfterResizeSettles()
            }
        }
        addSubview(splitView)

        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.postsFrameChangedNotifications = true
        splitView.addSubview(sidebarContainer)
        splitView.addSubview(pdfView)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebarContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.maximumNumberOfColumns = 1
        thumbnailView.backgroundColor = NSColor.windowBackgroundColor
        thumbnailView.allowsDragging = false

        sidebarFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: sidebarContainer,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.currentSidebarMode == .thumbnails {
                self.scheduleThumbnailRefreshAfterResizeSettles()
            }
        }

        annotationsChangedObserver = NotificationCenter.default.addObserver(
            forName: .pdfAnnotationsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard self.currentSidebarMode == .highlightsAndNotes else { return }
            guard let document = note.object as? PDFDocument else { return }
            guard self.currentDocument === document else { return }
            self.refreshHighlightsSidebarIfNeeded(force: true)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitView.setPosition(self.sidebarWidth, ofDividerAt: 0)
            if self.currentSidebarMode == .thumbnails {
                self.refreshThumbnailViewIfReady(forceRebind: true)
            }
        }
    }

    private func configureSidebar(mode: PDFSidebarMode, document: PDFDocument) {
        if mode != .thumbnails {
            stopThumbnailWarmup()
        }
        if mode != .highlightsAndNotes {
            stopAnnotationSidebarMonitoring()
        }

        if mode == .hidden {
            splitView.minimumLeadingWidth = 0
            sidebarContainer.subviews.forEach { $0.removeFromSuperview() }
            sidebarContainer.isHidden = true
            hasBoundThumbnailView = false
            splitView.setPosition(0, ofDividerAt: 0)
            return
        }

        splitView.minimumLeadingWidth = sidebarWidth
        sidebarContainer.isHidden = false
        enforceMinimumSidebarWidthIfNeeded()

        sidebarContainer.subviews.forEach { $0.removeFromSuperview() }

        if mode == .thumbnails {
            hasBoundThumbnailView = false
            thumbnailView.pdfView = nil
            sidebarContainer.addSubview(thumbnailView)
            NSLayoutConstraint.activate([
                thumbnailView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
                thumbnailView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
                thumbnailView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
                thumbnailView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            ])
            sidebarContainer.layoutSubtreeIfNeeded()
            startThumbnailWarmup()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.currentSidebarMode == .thumbnails {
                    self.refreshThumbnailViewIfReady(forceRebind: true)
                }
            }
            return
        }

        let outlineItems: [PDFOutlineSidebarItem] = {
            if mode == .tableOfContents {
                return flattenOutlineItems(from: document.outlineRoot)
            }
            return []
        }()
        if mode == .highlightsAndNotes {
            startAnnotationSidebarMonitoring(for: document)
        }
        let annotationItems = collectHighlightAndNoteItems(from: document)
        let hosting = NSHostingView(
            rootView: PDFDocumentSidebarContentView(
                mode: mode,
                outlineItems: outlineItems,
                annotationItems: annotationItems,
                onSelectOutline: { [weak self] item in
                    self?.navigateToOutlineItem(item)
                },
                onSelectAnnotation: { [weak self] item in
                    self?.navigateToAnnotationItem(item)
                }
            )
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
        ])
    }

    private func flattenOutlineItems(from root: PDFOutline?) -> [PDFOutlineSidebarItem] {
        guard let root else { return [] }
        var result: [PDFOutlineSidebarItem] = []

        func visit(_ node: PDFOutline, level: Int) {
            let children = Int(node.numberOfChildren)
            for childIndex in 0..<children {
                guard let child = node.child(at: childIndex) else { continue }
                let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanedTitle = (title?.isEmpty == false ? title! : "Untitled")
                let page = child.destination?.page
                let pageNumber = page.flatMap { page in
                    child.document.map { $0.index(for: page) + 1 }
                }
                result.append(
                    PDFOutlineSidebarItem(
                        id: "\(level)-\(childIndex)-\(cleanedTitle)-\(pageNumber ?? -1)",
                        title: cleanedTitle,
                        level: level,
                        destination: child.destination,
                        page: page,
                        pageNumber: pageNumber
                    )
                )
                visit(child, level: level + 1)
            }
        }

        visit(root, level: 0)
        return result
    }

    private func collectHighlightAndNoteItems(from document: PDFDocument) -> [PDFAnnotationSidebarItem] {
        var items: [PDFAnnotationSidebarItem] = []
        var seenAnnotationKeys = Set<String>()

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                let typeName = (annotation.type ?? "").lowercased()
                let isMarkup = typeName.contains("highlight")
                    || typeName.contains("underline")
                    || typeName.contains("strike")
                let isNote = typeName.contains("text")

                guard isMarkup || isNote else { continue }

                let annotationGroup = relatedSidebarAnnotations(for: annotation, on: page)
                let annotationKey = sidebarAnnotationKey(for: annotation, relatedAnnotations: annotationGroup)
                guard seenAnnotationKeys.insert(annotationKey).inserted else { continue }

                items.append(
                    PDFAnnotationSidebarItem(
                        id: annotationKey,
                        pageLabel: "Page \(index + 1)",
                        authorName: sidebarAuthorName(for: annotationGroup),
                        excerpt: sidebarExcerpt(for: annotationGroup, on: page),
                        note: sidebarNote(for: annotationGroup),
                        accentColor: sidebarAccentColor(for: annotationGroup, isNote: isNote),
                        page: page,
                        annotation: annotation
                    )
                )
            }
        }
        return items
    }

    private func relatedSidebarAnnotations(for annotation: PDFAnnotation, on page: PDFPage) -> [PDFAnnotation] {
        let markupGroupPrefix = "pdfpal-group:"
        guard let userName = annotation.userName, userName.hasPrefix(markupGroupPrefix) else {
            return [annotation]
        }

        let groupID = String(userName.dropFirst(markupGroupPrefix.count))
        let annotationType = (annotation.type ?? "").lowercased()
        let grouped = page.annotations.filter { candidate in
            let candidateType = (candidate.type ?? "").lowercased()
            guard candidateType == annotationType else { return false }
            guard let candidateUserName = candidate.userName else { return false }
            return candidateUserName == "\(markupGroupPrefix)\(groupID)"
        }

        return grouped.sorted { lhs, rhs in
            if abs(lhs.bounds.maxY - rhs.bounds.maxY) > 0.5 {
                return lhs.bounds.maxY > rhs.bounds.maxY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }
    }

    private func sidebarAnnotationKey(for annotation: PDFAnnotation, relatedAnnotations: [PDFAnnotation]) -> String {
        let markupGroupPrefix = "pdfpal-group:"
        if let userName = annotation.userName, userName.hasPrefix(markupGroupPrefix) {
            let groupID = String(userName.dropFirst(markupGroupPrefix.count))
            return "\((annotation.type ?? "").lowercased())-\(groupID)"
        }

        let bounds = relatedAnnotations.first?.bounds ?? annotation.bounds
        return "\((annotation.type ?? "").lowercased())-\(bounds.origin.x)-\(bounds.origin.y)-\(bounds.width)-\(bounds.height)"
    }

    private func sidebarAuthorName(for annotations: [PDFAnnotation]) -> String? {
        for annotation in annotations {
            guard let userName = annotation.userName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !userName.isEmpty,
                  !userName.hasPrefix("pdfpal-group:")
            else {
                continue
            }
            return userName
        }
        return nil
    }

    private func sidebarExcerpt(for annotations: [PDFAnnotation], on page: PDFPage) -> String {
        let fragments = annotations.compactMap { annotation in
            page.selection(for: annotation.bounds)?
                .string?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        if !fragments.isEmpty {
            return fragments.joined(separator: " ")
        }

        let typeName = (annotations.first?.type ?? "").lowercased()
        if typeName.contains("highlight") {
            return "Highlighted text"
        }
        if typeName.contains("underline") {
            return "Underlined text"
        }
        if typeName.contains("strike") {
            return "Struck through text"
        }
        return "Note"
    }

    private func sidebarNote(for annotations: [PDFAnnotation]) -> String? {
        for annotation in annotations {
            let note = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !note.isEmpty {
                return note
            }
        }
        return nil
    }

    private func sidebarAccentColor(for annotations: [PDFAnnotation], isNote: Bool) -> NSColor {
        if let color = annotations.first?.color {
            return color.withAlphaComponent(0.95)
        }
        return isNote ? NSColor.systemBlue : NSColor.systemYellow
    }

    private func navigateToOutlineItem(_ item: PDFOutlineSidebarItem) {
        if let destination = item.destination {
            pdfView.go(to: destination)
            return
        }
        if let page = item.page {
            pdfView.go(to: page)
        }
    }

    private func navigateToAnnotationItem(_ item: PDFAnnotationSidebarItem) {
        if let annotation = item.annotation {
            let point = CGPoint(x: annotation.bounds.minX, y: annotation.bounds.maxY)
            let destination = PDFDestination(page: item.page, at: point)
            pdfView.go(to: destination)
            return
        }
        pdfView.go(to: item.page)
    }

    override func layout() {
        super.layout()
        if currentSidebarMode == .thumbnails {
            scheduleThumbnailRefreshAfterResizeSettles()
        }
    }

    private func resolvedThumbnailSidebarWidth() -> CGFloat? {
        guard window != nil else { return nil }
        guard splitView.subviews.count >= 2 else { return nil }

        let sidebarFrameWidth = splitView.subviews[0].frame.width
        let sidebarHeight = sidebarContainer.bounds.height
        guard sidebarFrameWidth > 1, sidebarHeight > 1 else { return nil }

        return sidebarFrameWidth
    }

    @discardableResult
    private func updateThumbnailSizeToSidebarWidth() -> Bool {
        guard let availableWidth = resolvedThumbnailSidebarWidth() else { return false }

        let horizontalPadding: CGFloat = 8
        let thumbnailWidth = max(90, availableWidth - horizontalPadding)
        let defaultAspectRatio: CGFloat = 1.30
        let rawAspectRatio: CGFloat = {
            guard
                let document = currentDocument,
                let firstPage = document.page(at: 0)
            else {
                return defaultAspectRatio
            }

            let pageBounds = firstPage.bounds(for: .mediaBox)
            guard pageBounds.width > 0 else {
                return defaultAspectRatio
            }
            return max(1.0, pageBounds.height / pageBounds.width)
        }()
        // Keep thumbnail cards visually tight like Preview and avoid extremely tall cells.
        let aspectRatio = min(rawAspectRatio, 1.35)
        let thumbnailHeight = thumbnailWidth * aspectRatio
        let size = NSSize(width: thumbnailWidth, height: thumbnailHeight)
        if thumbnailView.thumbnailSize != size {
            thumbnailView.thumbnailSize = size
            thumbnailView.layoutSubtreeIfNeeded()
            return true
        }
        return false
    }

    private func refreshThumbnailViewIfReady(forceRebind: Bool = false) {
        guard currentSidebarMode == .thumbnails else { return }
        let sizeDidChange = updateThumbnailSizeToSidebarWidth()
        guard resolvedThumbnailSidebarWidth() != nil else { return }

        // Bind after the sidebar has a real post-attach size. Rebinding on every
        // warmup tick was racing PDFThumbnailView against unstable startup layout.
        if forceRebind || !hasBoundThumbnailView {
            thumbnailView.pdfView = nil
            thumbnailView.pdfView = pdfView
            hasBoundThumbnailView = true
        }

        if forceRebind || sizeDidChange {
            thumbnailView.needsLayout = true
            thumbnailView.needsDisplay = true
        }
    }

    private func scheduleThumbnailRefresh(forceRebind: Bool = false) {
        guard currentSidebarMode == .thumbnails else { return }
        thumbnailRefreshWorkItem?.cancel()
        thumbnailRefreshWorkItem = nil
        refreshThumbnailViewIfReady(forceRebind: forceRebind)
    }

    private func scheduleThumbnailRefreshAfterResizeSettles(forceRebind: Bool = false) {
        guard currentSidebarMode == .thumbnails else { return }
        let scheduledWidth = splitView.subviews.first?.frame.width ?? 0

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentSidebarMode == .thumbnails else { return }

            let currentWidth = self.splitView.subviews.first?.frame.width ?? 0
            if abs(currentWidth - scheduledWidth) > 0.5 {
                self.scheduleThumbnailRefreshAfterResizeSettles(forceRebind: forceRebind)
                return
            }

            self.thumbnailRefreshWorkItem = nil
            self.refreshThumbnailViewIfReady(forceRebind: forceRebind)
        }

        thumbnailRefreshWorkItem?.cancel()
        thumbnailRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + thumbnailResizeSettleDelay, execute: workItem)
    }

    private func startThumbnailWarmup() {
        thumbnailWarmupAttemptsRemaining = 8
        scheduleThumbnailWarmupTick()
    }

    private func stopThumbnailWarmup() {
        thumbnailWarmupWorkItem?.cancel()
        thumbnailWarmupWorkItem = nil
        thumbnailWarmupAttemptsRemaining = 0
    }

    private func scheduleThumbnailWarmupTick() {
        thumbnailWarmupWorkItem?.cancel()

        guard thumbnailWarmupAttemptsRemaining > 0 else {
            thumbnailWarmupWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.currentSidebarMode == .thumbnails else { return }
            self.enforceMinimumSidebarWidthIfNeeded()
            self.scheduleThumbnailRefresh(forceRebind: !self.hasBoundThumbnailView)
            self.thumbnailWarmupAttemptsRemaining -= 1
            self.scheduleThumbnailWarmupTick()
        }
        thumbnailWarmupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func startAnnotationSidebarMonitoring(for document: PDFDocument) {
        lastAnnotationSidebarSignature = annotationSidebarSignature(for: document)

        guard annotationSidebarMonitorTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.refreshHighlightsSidebarIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        annotationSidebarMonitorTimer = timer
    }

    private func stopAnnotationSidebarMonitoring() {
        annotationSidebarMonitorTimer?.invalidate()
        annotationSidebarMonitorTimer = nil
        lastAnnotationSidebarSignature = nil
    }

    private func refreshHighlightsSidebarIfNeeded(force: Bool = false) {
        guard currentSidebarMode == .highlightsAndNotes else { return }
        guard let document = currentDocument else { return }

        let nextSignature = annotationSidebarSignature(for: document)
        guard force || nextSignature != lastAnnotationSidebarSignature else { return }

        lastAnnotationSidebarSignature = nextSignature
        configureSidebar(mode: .highlightsAndNotes, document: document)
    }

    private func annotationSidebarSignature(for document: PDFDocument) -> String {
        var parts: [String] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                let typeName = (annotation.type ?? "").lowercased()
                let isMarkup = typeName.contains("highlight")
                    || typeName.contains("underline")
                    || typeName.contains("strike")
                let isNote = typeName.contains("text")
                guard isMarkup || isNote else { continue }

                let bounds = annotation.bounds
                let rgb = annotation.color.usingColorSpace(.deviceRGB)
                let colorPart = rgb.map {
                    "\($0.redComponent),\($0.greenComponent),\($0.blueComponent),\($0.alphaComponent)"
                } ?? "nil"

                parts.append(
                    [
                        "\(pageIndex)",
                        typeName,
                        annotation.contents ?? "",
                        annotation.userName ?? "",
                        "\(bounds.origin.x)",
                        "\(bounds.origin.y)",
                        "\(bounds.size.width)",
                        "\(bounds.size.height)",
                        colorPart,
                    ].joined(separator: "|")
                )
            }
        }

        return parts.joined(separator: "\n")
    }

    private func enforceMinimumSidebarWidthIfNeeded() {
        guard splitView.subviews.count >= 2, !sidebarContainer.isHidden else { return }
        if splitView.subviews[0].frame.width < sidebarWidth {
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        }
    }
}

private struct PDFOutlineSidebarItem: Identifiable {
    let id: String
    let title: String
    let level: Int
    let destination: PDFDestination?
    let page: PDFPage?
    let pageNumber: Int?
}

private struct PDFAnnotationSidebarItem: Identifiable {
    let id: String
    let pageLabel: String
    let authorName: String?
    let excerpt: String
    let note: String?
    let accentColor: NSColor
    let page: PDFPage
    let annotation: PDFAnnotation?
}

private struct PDFDocumentSidebarContentView: View {
    let mode: PDFSidebarMode
    let outlineItems: [PDFOutlineSidebarItem]
    let annotationItems: [PDFAnnotationSidebarItem]
    let onSelectOutline: (PDFOutlineSidebarItem) -> Void
    let onSelectAnnotation: (PDFAnnotationSidebarItem) -> Void

    var body: some View {
        switch mode {
        case .tableOfContents:
            if outlineItems.isEmpty {
                sidebarEmptyState(title: mode.title, message: "No entries available.")
            } else {
                List(outlineItems) { item in
                    Button {
                        onSelectOutline(item)
                    } label: {
                        HStack(spacing: 8) {
                            Text(item.title)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            if let pageNumber = item.pageNumber {
                                Text("\(pageNumber)")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                        }
                        .padding(.leading, CGFloat(item.level) * 12.0)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        case .bookmarks:
            sidebarEmptyState(
                title: mode.title,
                message: "TODO: Bookmarks sidebar is not implemented yet."
            )
        case .highlightsAndNotes:
            if annotationItems.isEmpty {
                sidebarEmptyState(title: mode.title, message: "No highlights or notes found.")
        } else {
            List(annotationItems) { item in
                    Button {
                        onSelectAnnotation(item)
                    } label: {
                        annotationCard(item)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                    .listRowBackground(Color.clear)
            }
            .listStyle(.sidebar)
        }
    case .hidden, .thumbnails:
        EmptyView()
        }
    }

    private func sidebarEmptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private func annotationCard(_ item: PDFAnnotationSidebarItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: item.accentColor))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.pageLabel)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 8)
                    if let authorName = item.authorName {
                        Text(authorName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(item.excerpt)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if let note = item.note, !note.isEmpty {
                    Text(note)
                        .font(.body)
                        .foregroundColor(annotationNoteTextColor(for: item.accentColor))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(annotationNoteBackgroundColor(for: item.accentColor))
                        )
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func annotationNoteBackgroundColor(for accentColor: NSColor) -> Color {
        Color(nsColor: accentColor.withAlphaComponent(0.78))
    }

    private func annotationNoteTextColor(for accentColor: NSColor) -> Color {
        guard let rgb = accentColor.usingColorSpace(.deviceRGB) else {
            return .white
        }

        let brightness =
            (0.299 * rgb.redComponent)
            + (0.587 * rgb.greenComponent)
            + (0.114 * rgb.blueComponent)

        return brightness > 0.68 ? .black.opacity(0.82) : .white
    }
}

final class PDFKitView: PDFView {
    private static let markupGroupPrefix = "pdfpal-group:"

    var onAskLLM: ((String) -> Void)?
    private var lastSelectionText: String = ""
    private var contextMenuAnnotation: PDFAnnotation?
    private var contextMenuPage: PDFPage?
    private var contextMenuPointOnPage: CGPoint?
    private var annotationObserver: NSObjectProtocol?
    private var highlighterPrimaryObserver: NSObjectProtocol?
    private var selectionChangedObserver: NSObjectProtocol?
    private var saveObserver: NSObjectProtocol?
    private var searchNextObserver: NSObjectProtocol?
    private var searchPreviousObserver: NSObjectProtocol?
    private var pendingModeApplyWorkItem: DispatchWorkItem?
    private var currentAnnotationAction: PDFAnnotationAction = .highlightYellow
    private var isHighlighterModeEnabled = false
    private var isApplyingFromMode = false
    private var lastModeSelectionFingerprint: String?
    private var lastSearchSignature: String = ""
    private var searchMatches: [PDFSelection] = []
    private var currentSearchMatchIndex: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerAnnotationObserver()
        registerSelectionObserver()
        registerSaveObserver()
        registerSearchNavigationObservers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerAnnotationObserver()
        registerSelectionObserver()
        registerSaveObserver()
        registerSearchNavigationObservers()
    }

    deinit {
        pendingModeApplyWorkItem?.cancel()
        if let annotationObserver {
            NotificationCenter.default.removeObserver(annotationObserver)
        }
        if let highlighterPrimaryObserver {
            NotificationCenter.default.removeObserver(highlighterPrimaryObserver)
        }
        if let selectionChangedObserver {
            NotificationCenter.default.removeObserver(selectionChangedObserver)
        }
        if let saveObserver {
            NotificationCenter.default.removeObserver(saveObserver)
        }
        if let searchNextObserver {
            NotificationCenter.default.removeObserver(searchNextObserver)
        }
        if let searchPreviousObserver {
            NotificationCenter.default.removeObserver(searchPreviousObserver)
        }
    }

    override func setCurrentSelection(_ selection: PDFSelection?, animate: Bool) {
        super.setCurrentSelection(selection, animate: animate)
    }

    func updateSearch(query: String, mode: PDFSearchMode) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let documentIdentity = document.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let signature = "\(documentIdentity)|\(mode.rawValue)|\(normalized)"
        guard signature != lastSearchSignature else { return }
        lastSearchSignature = signature

        guard !normalized.isEmpty else {
            highlightedSelections = nil
            setCurrentSelection(nil, animate: false)
            searchMatches = []
            currentSearchMatchIndex = nil
            return
        }

        let matches = searchSelections(query: normalized, mode: mode)
        guard !matches.isEmpty else {
            highlightedSelections = nil
            setCurrentSelection(nil, animate: false)
            searchMatches = []
            currentSearchMatchIndex = nil
            return
        }

        searchMatches = matches

        let highlightedMatches = matches.map { selection -> PDFSelection in
            let displaySelection = (selection.copy() as? PDFSelection) ?? selection
            displaySelection.color = NSColor.systemYellow.withAlphaComponent(0.45)
            return displaySelection
        }
        highlightedSelections = highlightedMatches

        let focusedIndex = nearestSearchMatchIndex(in: matches) ?? 0
        currentSearchMatchIndex = focusedIndex
        focusSearchMatch(at: focusedIndex, animate: true)
    }

    private struct SearchSelectionKey: Hashable {
        let pageIndex: Int
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let text: String
    }

    private func searchSelections(query: String, mode: PDFSearchMode) -> [PDFSelection] {
        guard let document else { return [] }
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        switch mode {
        case .exactPhrase:
            return document.findString(query, withOptions: options)
        case .anyMatch:
            let terms = query
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard !terms.isEmpty else { return [] }

            var seen = Set<SearchSelectionKey>()
            var unique: [PDFSelection] = []

            for term in terms {
                let matches = document.findString(term, withOptions: options)
                for match in matches {
                    guard let key = searchSelectionKey(for: match, in: document) else { continue }
                    if seen.insert(key).inserted {
                        unique.append(match)
                    }
                }
            }

            unique.sort { lhs, rhs in
                compareSearchSelections(lhs, rhs, in: document)
            }
            return unique
        }
    }

    private func searchSelectionKey(for selection: PDFSelection, in document: PDFDocument) -> SearchSelectionKey? {
        guard let page = selection.pages.first else { return nil }
        let pageIndex = document.index(for: page)
        let bounds = selection.bounds(for: page)
        return SearchSelectionKey(
            pageIndex: pageIndex,
            x: Int((bounds.origin.x * 10).rounded()),
            y: Int((bounds.origin.y * 10).rounded()),
            width: Int((bounds.width * 10).rounded()),
            height: Int((bounds.height * 10).rounded()),
            text: selection.string ?? ""
        )
    }

    private func compareSearchSelections(_ lhs: PDFSelection, _ rhs: PDFSelection, in document: PDFDocument) -> Bool {
        guard let lhsPage = lhs.pages.first, let rhsPage = rhs.pages.first else {
            return lhs.pages.count < rhs.pages.count
        }
        let lhsPageIndex = document.index(for: lhsPage)
        let rhsPageIndex = document.index(for: rhsPage)
        if lhsPageIndex != rhsPageIndex {
            return lhsPageIndex < rhsPageIndex
        }

        let lhsBounds = lhs.bounds(for: lhsPage)
        let rhsBounds = rhs.bounds(for: rhsPage)
        if abs(lhsBounds.minY - rhsBounds.minY) > 0.1 {
            return lhsBounds.minY > rhsBounds.minY
        }
        return lhsBounds.minX < rhsBounds.minX
    }

    private struct SearchCandidate {
        let index: Int
        let pageIndex: Int
        let pageDistance: Int
        let localDistance: CGFloat
        let bounds: CGRect
    }

    private func nearestSearchMatchIndex(in matches: [PDFSelection]) -> Int? {
        guard let document else { return matches.isEmpty ? nil : 0 }

        let currentPageIndex: Int = {
            guard let page = currentPage else { return 0 }
            return document.index(for: page)
        }()

        let anchorPoint: CGPoint? = {
            guard let destination = currentDestination else { return nil }
            return destination.point
        }()

        let candidates: [SearchCandidate] = matches.enumerated().compactMap { index, selection in
            guard let page = selection.pages.first else { return nil }
            let pageIndex = document.index(for: page)
            let bounds = selection.bounds(for: page)
            let pageDistance = abs(pageIndex - currentPageIndex)

            let localDistance: CGFloat
            if pageDistance == 0, let anchorPoint {
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                localDistance = hypot(center.x - anchorPoint.x, center.y - anchorPoint.y)
            } else {
                localDistance = .greatestFiniteMagnitude
            }

            return SearchCandidate(
                index: index,
                pageIndex: pageIndex,
                pageDistance: pageDistance,
                localDistance: localDistance,
                bounds: bounds
            )
        }

        guard !candidates.isEmpty else { return matches.isEmpty ? nil : 0 }

        let best = candidates.min { lhs, rhs in
            if lhs.pageDistance != rhs.pageDistance {
                return lhs.pageDistance < rhs.pageDistance
            }
            if abs(lhs.localDistance - rhs.localDistance) > 0.1 {
                return lhs.localDistance < rhs.localDistance
            }
            if lhs.pageIndex != rhs.pageIndex {
                return lhs.pageIndex < rhs.pageIndex
            }
            if abs(lhs.bounds.minY - rhs.bounds.minY) > 0.1 {
                return lhs.bounds.minY > rhs.bounds.minY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }

        return best?.index
    }

    private func focusSearchMatch(at index: Int, animate: Bool) {
        guard searchMatches.indices.contains(index) else { return }
        let selection = searchMatches[index]
        setCurrentSelection(selection, animate: animate)
        go(to: selection)
    }

    private func navigateSearchMatch(step: Int) {
        guard !searchMatches.isEmpty else {
            NSSound.beep()
            return
        }

        let count = searchMatches.count
        let baseIndex = currentSearchMatchIndex ?? nearestSearchMatchIndex(in: searchMatches) ?? 0
        let nextIndex = (baseIndex + step + count) % count
        currentSearchMatchIndex = nextIndex
        focusSearchMatch(at: nextIndex, animate: true)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let selectionText = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lastSelectionText = selectionText
        contextMenuAnnotation = annotation(at: event)

        menu.items.removeAll { $0.tag == 9100 }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        if !menu.items.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        let askItem = NSMenuItem(title: "Ask LLM", action: #selector(handleAskLLM), keyEquivalent: "")
        askItem.target = self
        askItem.isEnabled = !selectionText.isEmpty
        askItem.tag = 9100
        menu.addItem(askItem)

        retargetAnnotationMenuItems(in: menu)
        return menu
    }

    private func retargetAnnotationMenuItems(in menu: NSMenu) {
        replaceSystemMarkupStylePicker(in: menu)
        for item in menu.items {
            if let submenu = item.submenu {
                retargetAnnotationMenuItems(in: submenu)
            }

            let lowerTitle = item.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let isRemoveAnnotationAction = lowerTitle == "remove annotation"
                || lowerTitle == "remove highlight"
                || lowerTitle == "remove underline"
                || lowerTitle == "remove strikethrough"
            if isRemoveAnnotationAction {
                item.action = #selector(handleRemoveAnnotation)
                item.target = self
                continue
            }

            if let colorAction = colorActionForContextMenuItem(item) {
                item.action = #selector(handleContextColorSelection(_:))
                item.target = self
                item.representedObject = colorAction
                continue
            }

            if lowerTitle == "add note" {
                item.action = #selector(handleAddNoteFromContextMenu(_:))
                item.target = self
                continue
            }

            if isUnderlineContextItem(item, lowerTitle: lowerTitle) {
                item.action = #selector(handleContextUnderlineToggle(_:))
                item.target = self
                continue
            }

            if isStrikeContextItem(item, lowerTitle: lowerTitle) {
                item.action = #selector(handleContextStrikeToggle(_:))
                item.target = self
            }
        }
    }

    private func replaceSystemMarkupStylePicker(in menu: NSMenu) {
        guard let pickerIndex = menu.items.firstIndex(where: { item in
            guard let view = item.view else { return false }
            return String(describing: type(of: view)).contains("PDFMarkupStylePicker")
        }) else {
            return
        }

        let replacementItem = NSMenuItem()
        replacementItem.view = makeMarkupStylePickerView()
        menu.removeItem(at: pickerIndex)
        menu.insertItem(replacementItem, at: pickerIndex)
    }

    private func makeMarkupStylePickerView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        let colorButtons: [(PDFAnnotationAction, NSColor)] = [
            (.highlightYellow, NSColor.systemYellow),
            (.highlightGreen, NSColor.systemGreen),
            (.highlightBlue, NSColor.systemBlue),
            (.highlightPink, NSColor.systemPink),
            (.highlightPurple, NSColor.systemPurple),
        ]

        for (action, color) in colorButtons {
            stack.addArrangedSubview(makeColorPickerButton(action: action, color: color))
        }
        stack.addArrangedSubview(makeTextStylePickerButton(action: .underline, text: "U", underline: true))
        stack.addArrangedSubview(makeTextStylePickerButton(action: .strikeOut, text: "S", underline: false))

        return container
    }

    private func makeColorPickerButton(action: PDFAnnotationAction, color: NSColor) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(handleMarkupStylePickerButton(_:)))
        button.tag = markupPickerTag(for: action)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = color.cgColor
        button.layer?.cornerRadius = 10
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
        return button
    }

    private func makeTextStylePickerButton(
        action: PDFAnnotationAction,
        text: String,
        underline: Bool
    ) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(handleMarkupStylePickerButton(_:)))
        button.tag = markupPickerTag(for: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small

        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        if underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        button.attributedTitle = NSAttributedString(string: text, attributes: attributes)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
        return button
    }

    private func markupPickerTag(for action: PDFAnnotationAction) -> Int {
        switch action {
        case .highlightYellow:
            return 9401
        case .highlightGreen:
            return 9402
        case .highlightBlue:
            return 9403
        case .highlightPink:
            return 9404
        case .highlightPurple:
            return 9405
        case .underline:
            return 9406
        case .strikeOut:
            return 9407
        }
    }

    private func markupPickerAction(for tag: Int) -> PDFAnnotationAction? {
        switch tag {
        case 9401:
            return .highlightYellow
        case 9402:
            return .highlightGreen
        case 9403:
            return .highlightBlue
        case 9404:
            return .highlightPink
        case 9405:
            return .highlightPurple
        case 9406:
            return .underline
        case 9407:
            return .strikeOut
        default:
            return nil
        }
    }

    @objc private func handleMarkupStylePickerButton(_ sender: NSButton) {
        guard let action = markupPickerAction(for: sender.tag) else { return }
        switch action {
        case .underline:
            applyContextUnderlineToggle()
        case .strikeOut:
            applyContextStrikeToggle()
        case .highlightYellow, .highlightGreen, .highlightBlue, .highlightPink, .highlightPurple:
            applyContextColorAction(action)
        }
        sender.enclosingMenuItem?.menu?.cancelTracking()
    }

    private func contextMenuDebugSummary(for item: NSMenuItem, index: Int) -> String {
        let title = item.title.replacingOccurrences(of: "\"", with: "\\\"")
        let attributedTitle = item.attributedTitle?.string.replacingOccurrences(of: "\"", with: "\\\"") ?? ""
        let actionName = item.action.map { NSStringFromSelector($0) } ?? "nil"
        let representedType = item.representedObject.map { String(describing: type(of: $0)) } ?? "nil"
        let hasImage = item.image != nil
        let submenuTitle = item.submenu?.title ?? "nil"
        let viewSummary = item.view.map { debugViewSummary($0) } ?? "nil"

        return "[\(index)] title=\"\(title)\" attributed=\"\(attributedTitle)\" action=\(actionName) represented=\(representedType) image=\(hasImage) separator=\(item.isSeparatorItem) submenu=\(submenuTitle) view=\(viewSummary)"
    }

    private func debugViewSummary(_ view: NSView) -> String {
        var parts: [String] = []
        appendDebugViewTree(view, depth: 0, maxDepth: 3, into: &parts)
        return parts.joined(separator: " | ")
    }

    private func appendDebugViewTree(
        _ view: NSView,
        depth: Int,
        maxDepth: Int,
        into parts: inout [String]
    ) {
        let className = String(describing: type(of: view))
        var node = "\(String(repeating: ">", count: depth))\(className)"

        if let button = view as? NSButton {
            let buttonTitle = button.title.replacingOccurrences(of: "\"", with: "\\\"")
            let buttonAction = button.action.map { NSStringFromSelector($0) } ?? "nil"
            node += "(title=\"\(buttonTitle)\", action=\(buttonAction), tag=\(button.tag), state=\(button.state.rawValue))"
        } else if let control = view as? NSControl {
            node += "(tag=\(control.tag))"
        }

        if let toolTip = view.toolTip, !toolTip.isEmpty {
            let escaped = toolTip.replacingOccurrences(of: "\"", with: "\\\"")
            node += "(toolTip=\"\(escaped)\")"
        }

        parts.append(node)

        guard depth < maxDepth else { return }
        for subview in view.subviews {
            appendDebugViewTree(subview, depth: depth + 1, maxDepth: maxDepth, into: &parts)
        }
    }

    private func colorActionForContextMenuItem(_ item: NSMenuItem) -> PDFAnnotationAction? {
        let lowerTitle = item.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let selectorName = (item.action.map { NSStringFromSelector($0) } ?? "").lowercased()

        if lowerTitle.contains("yellow") || selectorName.contains("yellow") {
            return .highlightYellow
        }
        if lowerTitle.contains("green") || selectorName.contains("green") {
            return .highlightGreen
        }
        if lowerTitle.contains("blue") || selectorName.contains("blue") {
            return .highlightBlue
        }
        if lowerTitle.contains("pink") || selectorName.contains("pink") {
            return .highlightPink
        }
        if lowerTitle.contains("purple") || selectorName.contains("purple") {
            return .highlightPurple
        }
        return nil
    }

    private func isUnderlineContextItem(_ item: NSMenuItem, lowerTitle: String) -> Bool {
        if lowerTitle.contains("underline") {
            return true
        }
        let selectorName = (item.action.map { NSStringFromSelector($0) } ?? "").lowercased()
        return selectorName.contains("underline")
    }

    private func isStrikeContextItem(_ item: NSMenuItem, lowerTitle: String) -> Bool {
        if lowerTitle.contains("strikethrough") || lowerTitle.contains("strike") {
            return true
        }
        let selectorName = (item.action.map { NSStringFromSelector($0) } ?? "").lowercased()
        return selectorName.contains("strike")
    }

    @objc private func handleAskLLM() {
        let selection = lastSelectionText.isEmpty
            ? currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : lastSelectionText
        guard !selection.isEmpty else {
            return
        }
        onAskLLM?(selection)
    }

    @objc private func handleRemoveAnnotation() {
        guard let page = contextMenuPage ?? contextMenuAnnotation?.page ?? currentPage else { return }
        var removedAny = false

        if let point = contextMenuPointOnPage {
            let pointHits = removableAnnotations(at: point, on: page)
            removedAny = removeAnnotationCluster(seedAnnotations: pointHits, on: page)
        }

        if !removedAny, let selection = currentSelection {
            let selectionHits = removableAnnotations(intersecting: selection, on: page)
            removedAny = removeAnnotationCluster(seedAnnotations: selectionHits, on: page)
        }

        if !removedAny, let annotation = contextMenuAnnotation {
            removedAny = removeAnnotationCluster(seedAnnotations: [annotation], on: page)
                || removeAnnotation(annotation, from: page)
        }

        if removedAny {
            contextMenuAnnotation = nil
        } else {
            NSSound.beep()
        }
    }

    @objc private func handleContextColorSelection(_ sender: Any?) {
        let action: PDFAnnotationAction?
        if let item = sender as? NSMenuItem {
            action = item.representedObject as? PDFAnnotationAction
        } else if let button = sender as? NSButton {
            action = markupPickerAction(for: button.tag)
        } else {
            action = nil
        }
        guard let action else { return }
        applyContextColorAction(action)
    }

    private func applyContextColorAction(_ action: PDFAnnotationAction) {
        guard let (page, seeds) = contextMarkupTargets() else {
            // When no existing markup is under the cursor, apply to selected text.
            applyAnnotation(action, selection: currentSelection, beepOnEmpty: true)
            return
        }

        currentAnnotationAction = action
        let cluster = connectedRemovableAnnotations(from: seeds, on: page)
        let anchorBounds = uniqueBounds(from: cluster.isEmpty ? seeds : cluster)
        guard !anchorBounds.isEmpty else {
            NSSound.beep()
            return
        }

        let highlights = markupAnnotations(
            on: page,
            subtype: .highlight,
            overlappingAny: anchorBounds
        )
        let newColor = annotationStyle(for: action).color

        if highlights.isEmpty {
            let groupID = UUID().uuidString
            var addedAny = false
            for bounds in anchorBounds {
                if hasEquivalentAnnotation(on: page, action: action, bounds: bounds) {
                    continue
                }
                let annotation = makeAnnotation(for: action, bounds: bounds)
                setMarkupGroupID(groupID, on: annotation)
                page.addAnnotation(annotation)
                addedAny = true
            }
            if addedAny {
                notifyAnnotationsDidChange()
            }
            return
        }

        for annotation in highlights {
            annotation.color = newColor
        }
        notifyAnnotationsDidChange()
    }

    @objc private func handleAddNoteFromContextMenu(_ sender: NSMenuItem) {
        let targetPage = contextMenuPage ?? contextMenuAnnotation?.page ?? currentPage
        let targetMarkup = contextMenuAnnotation

        _ = NSApp.sendAction(NSSelectorFromString("_addNote:"), to: nil, from: sender)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.normalizeRelatedNoteColors(on: targetPage, targetMarkup: targetMarkup)
            self.notifyAnnotationsDidChange()
        }
    }

    @objc private func handleContextUnderlineToggle(_ sender: NSMenuItem) {
        applyContextUnderlineToggle()
    }

    @objc private func handleContextStrikeToggle(_ sender: NSMenuItem) {
        applyContextStrikeToggle()
    }

    private func applyContextUnderlineToggle() {
        if contextMarkupTargets() != nil {
            toggleOverlayMarkup(.underline)
            return
        }
        applyAnnotation(.underline, selection: currentSelection, beepOnEmpty: true)
    }

    private func applyContextStrikeToggle() {
        if contextMarkupTargets() != nil {
            toggleOverlayMarkup(.strikeOut)
            return
        }
        applyAnnotation(.strikeOut, selection: currentSelection, beepOnEmpty: true)
    }

    private func registerAnnotationObserver() {
        annotationObserver = NotificationCenter.default.addObserver(
            forName: .pdfSetAnnotationAction,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let action = note.object as? PDFAnnotationAction else { return }
            self?.currentAnnotationAction = action
        }

        highlighterPrimaryObserver = NotificationCenter.default.addObserver(
            forName: .pdfHighlighterPrimaryAction,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let action = note.object as? PDFAnnotationAction {
                self.currentAnnotationAction = action
            }
            self.handleHighlighterPrimaryAction()
        }
    }

    private func registerSaveObserver() {
        saveObserver = NotificationCenter.default.addObserver(
            forName: .pdfSaveDocument,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveCurrentDocument()
        }
    }

    private func registerSearchNavigationObservers() {
        searchNextObserver = NotificationCenter.default.addObserver(
            forName: .pdfSearchNext,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.navigateSearchMatch(step: 1)
        }

        searchPreviousObserver = NotificationCenter.default.addObserver(
            forName: .pdfSearchPrevious,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.navigateSearchMatch(step: -1)
        }
    }

    private func registerSelectionObserver() {
        selectionChangedObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.PDFViewSelectionChanged,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleHighlighterModeApply()
        }
    }

    private func scheduleHighlighterModeApply() {
        pendingModeApplyWorkItem?.cancel()
        guard isHighlighterModeEnabled else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyHighlighterModeIfNeeded(self.currentSelection)
        }
        pendingModeApplyWorkItem = workItem
        // Wait for selection updates to settle so highlight is applied once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func contextMarkupTargets() -> (page: PDFPage, seeds: [PDFAnnotation])? {
        guard let page = contextMenuPage ?? contextMenuAnnotation?.page ?? currentPage else {
            return nil
        }

        if let point = contextMenuPointOnPage {
            let hits = removableAnnotations(at: point, on: page)
            if !hits.isEmpty {
                return (page, hits)
            }
        }

        if let selection = currentSelection {
            let hits = removableAnnotations(intersecting: selection, on: page)
            if !hits.isEmpty {
                return (page, hits)
            }
        }

        if let annotation = contextMenuAnnotation, isRemovableMarkup(annotation) {
            return (page, [annotation])
        }

        return nil
    }

    private func toggleOverlayMarkup(_ subtype: PDFAnnotationSubtype) {
        guard let (page, seeds) = contextMarkupTargets() else {
            NSSound.beep()
            return
        }

        let cluster = connectedRemovableAnnotations(from: seeds, on: page)
        let anchorCluster = cluster.isEmpty ? seeds : cluster
        let anchorBounds = preferredOverlayAnchorBounds(from: anchorCluster, on: page)
        guard !anchorBounds.isEmpty else {
            NSSound.beep()
            return
        }

        let allBoundsHaveOverlay = anchorBounds.allSatisfy { bounds in
            !matchingMarkupAnnotations(on: page, subtype: subtype, around: bounds).isEmpty
        }

        if allBoundsHaveOverlay {
            var removed = Set<ObjectIdentifier>()
            for bounds in anchorBounds {
                let overlays = matchingMarkupAnnotations(on: page, subtype: subtype, around: bounds)
                for annotation in overlays {
                    let id = ObjectIdentifier(annotation)
                    if !removed.insert(id).inserted {
                        continue
                    }
                    removeAnnotationAndRelatedNotes(annotation, from: page)
                }
            }
            return
        }

        let overlayGroupID = UUID().uuidString
        var addedAny = false
        for bounds in anchorBounds {
            let overlays = matchingMarkupAnnotations(on: page, subtype: subtype, around: bounds)
            if !overlays.isEmpty {
                continue
            }
            let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
            annotation.color = preferredOverlayColor(on: page, bounds: bounds)
            setMarkupGroupID(overlayGroupID, on: annotation)
            page.addAnnotation(annotation)
            addedAny = true
        }
        if addedAny {
            notifyAnnotationsDidChange()
        }
    }

    private func preferredOverlayAnchorBounds(from cluster: [PDFAnnotation], on page: PDFPage) -> [CGRect] {
        let baseBounds = uniqueBounds(from: cluster)
        let highlightBounds = uniqueBounds(
            from: markupAnnotations(on: page, subtype: .highlight, overlappingAny: baseBounds)
        )
        return highlightBounds.isEmpty ? baseBounds : highlightBounds
    }

    private func preferredOverlayColor(on page: PDFPage, bounds: CGRect) -> NSColor {
        return annotationStyle(for: .underline).color
    }

    private func matchingMarkupAnnotations(
        on page: PDFPage,
        subtype: PDFAnnotationSubtype,
        around bounds: CGRect
    ) -> [PDFAnnotation] {
        let expanded = bounds.insetBy(dx: -2.0, dy: -2.0)
        return page.annotations.filter { annotation in
            guard annotationTypeMatches(annotation, subtype: subtype) else { return false }
            return boundsAreClose(annotation.bounds, bounds) || expanded.intersects(annotation.bounds)
        }
    }

    private func markupAnnotations(
        on page: PDFPage,
        subtype: PDFAnnotationSubtype,
        overlappingAny boundsList: [CGRect]
    ) -> [PDFAnnotation] {
        guard !boundsList.isEmpty else { return [] }
        return page.annotations.filter { annotation in
            guard annotationTypeMatches(annotation, subtype: subtype) else { return false }
            return boundsList.contains(where: { bounds in
                let expanded = bounds.insetBy(dx: -2.0, dy: -2.0)
                return expanded.intersects(annotation.bounds) || boundsAreClose(annotation.bounds, bounds)
            })
        }
    }

    private func uniqueBounds(from annotations: [PDFAnnotation]) -> [CGRect] {
        var result: [CGRect] = []
        for annotation in annotations {
            if result.contains(where: { boundsAreClose($0, annotation.bounds) }) {
                continue
            }
            result.append(annotation.bounds)
        }
        return result
    }

    private func applyAnnotation(_ action: PDFAnnotationAction) {
        applyAnnotation(action, selection: currentSelection, beepOnEmpty: true)
    }

    private func applyAnnotation(_ action: PDFAnnotationAction, selection: PDFSelection?, beepOnEmpty: Bool) {
        guard let selection else {
            if beepOnEmpty {
                NSSound.beep()
            }
            return
        }

        let lineSelections = selection.selectionsByLine()
        if lineSelections.isEmpty {
            if beepOnEmpty {
                NSSound.beep()
            }
            return
        }

        let groupID = UUID().uuidString
        var addedAny = false
        for lineSelection in lineSelections {
            guard let page = lineSelection.pages.first else { continue }
            let bounds = lineSelection.bounds(for: page)
            if bounds.isNull || bounds.isInfinite || bounds.isEmpty {
                continue
            }
            if hasEquivalentAnnotation(on: page, action: action, bounds: bounds) {
                continue
            }
            let annotation = makeAnnotation(for: action, bounds: bounds)
            setMarkupGroupID(groupID, on: annotation)
            page.addAnnotation(annotation)
            addedAny = true
        }
        if addedAny {
            notifyAnnotationsDidChange()
        }
    }

    private func handleHighlighterPrimaryAction() {
        if hasNonEmptySelection(currentSelection) {
            applyAnnotation(currentAnnotationAction, selection: currentSelection, beepOnEmpty: true)
            return
        }
        toggleHighlighterMode()
    }

    private func toggleHighlighterMode() {
        isHighlighterModeEnabled.toggle()
        if !isHighlighterModeEnabled {
            pendingModeApplyWorkItem?.cancel()
            lastModeSelectionFingerprint = nil
        }
        NotificationCenter.default.post(name: .pdfHighlighterModeChanged, object: isHighlighterModeEnabled)
    }

    private func applyHighlighterModeIfNeeded(_ selection: PDFSelection?) {
        guard isHighlighterModeEnabled else {
            lastModeSelectionFingerprint = nil
            return
        }
        guard !isApplyingFromMode else { return }
        guard let selection, hasNonEmptySelection(selection) else {
            return
        }

        let fingerprint = selectionFingerprint(selection)
        guard fingerprint != lastModeSelectionFingerprint else { return }
        lastModeSelectionFingerprint = fingerprint

        isApplyingFromMode = true
        applyAnnotation(currentAnnotationAction, selection: selection, beepOnEmpty: false)
        isApplyingFromMode = false
    }

    private func hasNonEmptySelection(_ selection: PDFSelection?) -> Bool {
        let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !text.isEmpty
    }

    private func selectionFingerprint(_ selection: PDFSelection) -> String {
        let pageParts = selection.selectionsByLine().compactMap { lineSelection -> String? in
            guard let page = lineSelection.pages.first else { return nil }
            let bounds = lineSelection.bounds(for: page)
            return "\(Unmanaged.passUnretained(page).toOpaque())|\(bounds.origin.x)|\(bounds.origin.y)|\(bounds.size.width)|\(bounds.size.height)"
        }
        let text = selection.string ?? ""
        return "\(pageParts.joined(separator: ";"))|\(text)"
    }

    private func makeAnnotation(for action: PDFAnnotationAction, bounds: CGRect) -> PDFAnnotation {
        let style = annotationStyle(for: action)
        let annotation = PDFAnnotation(bounds: bounds, forType: style.type, withProperties: nil)
        annotation.color = style.color
        return annotation
    }

    private func annotationStyle(for action: PDFAnnotationAction) -> (type: PDFAnnotationSubtype, color: NSColor) {
        switch action {
        case .highlightYellow:
            return (.highlight, baseColor(for: .highlightYellow).withAlphaComponent(0.35))
        case .highlightGreen:
            return (.highlight, baseColor(for: .highlightGreen).withAlphaComponent(0.35))
        case .highlightBlue:
            return (.highlight, baseColor(for: .highlightBlue).withAlphaComponent(0.35))
        case .highlightPink:
            return (.highlight, baseColor(for: .highlightPink).withAlphaComponent(0.35))
        case .highlightPurple:
            return (.highlight, baseColor(for: .highlightPurple).withAlphaComponent(0.35))
        case .underline:
            return (.underline, NSColor.systemRed)
        case .strikeOut:
            return (.strikeOut, NSColor.systemRed)
        }
    }

    private func hasEquivalentAnnotation(on page: PDFPage, action: PDFAnnotationAction, bounds: CGRect) -> Bool {
        let expected = annotationStyle(for: action)
        return page.annotations.contains { annotation in
            guard annotationTypeMatches(annotation, subtype: expected.type) else { return false }
            guard boundsAreClose(annotation.bounds, bounds) else { return false }
            if action == .underline || action == .strikeOut {
                return true
            }
            return colorsAreClose(annotation.color, expected.color)
        }
    }

    private func baseColor(for action: PDFAnnotationAction) -> NSColor {
        switch action {
        case .highlightYellow:
            return NSColor.systemYellow
        case .highlightGreen:
            return NSColor.systemGreen
        case .highlightBlue:
            return NSColor.systemBlue
        case .highlightPink:
            return NSColor.systemPink
        case .highlightPurple:
            return NSColor.systemPurple
        case .underline, .strikeOut:
            return NSColor.systemRed
        }
    }

    private func normalizeRelatedNoteColors(on page: PDFPage?, targetMarkup: PDFAnnotation?) {
        guard let page else { return }

        for annotation in page.annotations {
            let typeName = (annotation.type ?? "").lowercased()
            guard typeName.contains("text") || typeName.contains("popup") else { continue }

            let parent = annotation.value(forAnnotationKey: .parent) as? PDFAnnotation
            let popupParent = annotation.value(forAnnotationKey: .popup) as? PDFAnnotation

            let isRelatedToTarget =
                (targetMarkup != nil && (parent === targetMarkup || popupParent === targetMarkup))
                || (targetMarkup != nil && parent.map { annotationsLikelySame($0, targetMarkup!) } == true)

            let isMarkupNote = parent.map(isRemovableMarkup) ?? false

            guard isRelatedToTarget || isMarkupNote else { continue }

            annotation.color = NSColor.white
            if let popup = annotation.popup {
                popup.color = NSColor.white
            }
        }

        if let popup = targetMarkup?.popup {
            popup.color = NSColor.white
        }
    }

    private func notifyAnnotationsDidChange() {
        guard let document else { return }
        NotificationCenter.default.post(name: .pdfAnnotationsDidChange, object: document)
    }

    private func annotationTypeMatches(_ annotation: PDFAnnotation, subtype: PDFAnnotationSubtype) -> Bool {
        let typeName = (annotation.type ?? "").lowercased()
        switch subtype {
        case .highlight:
            return typeName.contains("highlight")
        case .underline:
            return typeName.contains("underline")
        case .strikeOut:
            return typeName.contains("strike")
        default:
            return typeName == subtype.rawValue.lowercased()
        }
    }

    private func boundsAreClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 0.5
        return abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.size.width - rhs.size.width) <= tolerance
            && abs(lhs.size.height - rhs.size.height) <= tolerance
    }

    private func annotation(at event: NSEvent) -> PDFAnnotation? {
        let pointInView = convert(event.locationInWindow, from: nil)
        guard let page = page(for: pointInView, nearest: true) else {
            contextMenuPage = nil
            contextMenuPointOnPage = nil
            return nil
        }
        contextMenuPage = page
        let pointOnPage = convert(pointInView, to: page)
        contextMenuPointOnPage = pointOnPage
        return page.annotation(at: pointOnPage)
    }

    private func removableAnnotations(at point: CGPoint, on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.reversed().filter { annotation in
            guard isRemovableMarkup(annotation) else { return false }
            return annotation.bounds.insetBy(dx: -6.0, dy: -6.0).contains(point)
        }
    }

    private func removableAnnotations(intersecting selection: PDFSelection, on page: PDFPage) -> [PDFAnnotation] {
        var matches: [PDFAnnotation] = []
        let lineSelections = selection.selectionsByLine().filter { $0.pages.first === page }
        for annotation in page.annotations {
            guard isRemovableMarkup(annotation) else { continue }
            if lineSelections.contains(where: { line in
                let lineBounds = line.bounds(for: page).insetBy(dx: -2.0, dy: -2.0)
                return lineBounds.intersects(annotation.bounds)
            }) {
                matches.append(annotation)
            }
        }
        return matches
    }

    private func removeAnnotationCluster(seedAnnotations: [PDFAnnotation], on page: PDFPage) -> Bool {
        let cluster = connectedRemovableAnnotations(from: seedAnnotations, on: page)
        guard !cluster.isEmpty else { return false }

        var removedAny = false
        for annotation in cluster {
            removedAny = removeAnnotation(annotation, from: page) || removedAny
        }
        return removedAny
    }

    private func connectedRemovableAnnotations(from seeds: [PDFAnnotation], on page: PDFPage) -> [PDFAnnotation] {
        let removable = page.annotations.filter(isRemovableMarkup)
        var result: [PDFAnnotation] = []
        var visited = Set<ObjectIdentifier>()
        for annotation in seeds where isRemovableMarkup(annotation) {
            for grouped in groupedAnnotations(for: annotation, in: removable) {
                let annotationID = ObjectIdentifier(grouped)
                guard visited.insert(annotationID).inserted else { continue }
                result.append(grouped)
            }
        }
        return result
    }

    private func groupedAnnotations(for seed: PDFAnnotation, in candidates: [PDFAnnotation]) -> [PDFAnnotation] {
        guard let groupID = markupGroupID(of: seed) else {
            return [seed]
        }
        let seedType = (seed.type ?? "").lowercased()
        return candidates.filter { candidate in
            let candidateType = (candidate.type ?? "").lowercased()
            guard candidateType == seedType else { return false }
            return markupGroupID(of: candidate) == groupID
        }
    }

    private func setMarkupGroupID(_ groupID: String, on annotation: PDFAnnotation) {
        annotation.userName = "\(Self.markupGroupPrefix)\(groupID)"
    }

    private func markupGroupID(of annotation: PDFAnnotation) -> String? {
        guard let userName = annotation.userName else { return nil }
        guard userName.hasPrefix(Self.markupGroupPrefix) else { return nil }
        return String(userName.dropFirst(Self.markupGroupPrefix.count))
    }

    private func isRemovableMarkup(_ annotation: PDFAnnotation) -> Bool {
        let typeName = (annotation.type ?? "").lowercased()
        return typeName.contains("highlight")
            || typeName.contains("underline")
            || typeName.contains("strike")
    }

    private func colorsAreClose(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        let lhsRGB = lhs.usingColorSpace(.deviceRGB)
        let rhsRGB = rhs.usingColorSpace(.deviceRGB)
        guard let lhsRGB, let rhsRGB else { return false }

        let threshold: CGFloat = 0.08
        return abs(lhsRGB.redComponent - rhsRGB.redComponent) <= threshold
            && abs(lhsRGB.greenComponent - rhsRGB.greenComponent) <= threshold
            && abs(lhsRGB.blueComponent - rhsRGB.blueComponent) <= threshold
            && abs(lhsRGB.alphaComponent - rhsRGB.alphaComponent) <= threshold
    }

    private func removeAnnotation(_ target: PDFAnnotation, from page: PDFPage) -> Bool {
        if let exact = page.annotations.first(where: { $0 === target }) {
            removeAnnotationAndRelatedNotes(exact, from: page)
            return true
        }
        if let matched = page.annotations.first(where: { annotationsLikelySame($0, target) }) {
            removeAnnotationAndRelatedNotes(matched, from: page)
            return true
        }
        return false
    }

    private func removeAnnotationAndRelatedNotes(_ target: PDFAnnotation, from page: PDFPage) {
        var toRemove: [PDFAnnotation] = [target]

        if let popup = target.value(forAnnotationKey: .popup) as? PDFAnnotation {
            toRemove.append(popup)
        }

        for candidate in page.annotations {
            if let parent = candidate.value(forAnnotationKey: .parent) as? PDFAnnotation {
                if parent === target || annotationsLikelySame(parent, target) {
                    toRemove.append(candidate)
                }
            }
        }

        var removed = Set<ObjectIdentifier>()
        for annotation in toRemove {
            let id = ObjectIdentifier(annotation)
            guard removed.insert(id).inserted else { continue }
            page.removeAnnotation(annotation)
        }

        if !removed.isEmpty {
            notifyAnnotationsDidChange()
        }
    }

    private func annotationsLikelySame(_ lhs: PDFAnnotation, _ rhs: PDFAnnotation) -> Bool {
        let lhsType = lhs.type ?? ""
        let rhsType = rhs.type ?? ""
        if lhsType != rhsType {
            return false
        }

        let dx = abs(lhs.bounds.origin.x - rhs.bounds.origin.x)
        let dy = abs(lhs.bounds.origin.y - rhs.bounds.origin.y)
        let dw = abs(lhs.bounds.size.width - rhs.bounds.size.width)
        let dh = abs(lhs.bounds.size.height - rhs.bounds.size.height)

        return dx < 0.5 && dy < 0.5 && dw < 0.5 && dh < 0.5
    }

    private func saveCurrentDocument() {
        guard let document = document, let url = document.documentURL else {
            NSSound.beep()
            return
        }

        if !document.write(to: url) {
            let alert = NSAlert()
            alert.messageText = "Save Failed"
            alert.informativeText = "Could not save changes to:\n\(url.path)"
            alert.runModal()
        }
    }
}

struct PDFEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.title2)
            Text(message)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
