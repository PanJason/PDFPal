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
    static let pdfGoToCitationDestination = Notification.Name("PDFGoToCitationDestination")
}

struct PDFViewer: View {
    let fileURL: URL?
    let onAskLLM: (String) -> Void
    let onAnnotationSelectionChanged: AnnotationSelectionHandler
    let onCitationSelectionChanged: CitationSelectionHandler
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
                    onAnnotationSelectionChanged: onAnnotationSelectionChanged,
                    onCitationSelectionChanged: onCitationSelectionChanged,
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
    let onAnnotationSelectionChanged: AnnotationSelectionHandler
    let onCitationSelectionChanged: CitationSelectionHandler
    let searchQuery: String
    let searchMode: PDFSearchMode
    let sidebarMode: PDFSidebarMode

    func makeNSView(context: Context) -> PDFReaderContainerView {
        let container = PDFReaderContainerView()
        container.update(
            document: document,
            onAskLLM: onAskLLM,
            onAnnotationSelectionChanged: onAnnotationSelectionChanged,
            onCitationSelectionChanged: onCitationSelectionChanged,
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
            onAnnotationSelectionChanged: onAnnotationSelectionChanged,
            onCitationSelectionChanged: onCitationSelectionChanged,
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
        onAnnotationSelectionChanged: @escaping AnnotationSelectionHandler,
        onCitationSelectionChanged: @escaping CitationSelectionHandler,
        searchQuery: String,
        searchMode: PDFSearchMode,
        sidebarMode: PDFSidebarMode
    ) {
        let documentChanged = pdfView.document !== document
        if documentChanged {
            pdfView.document = document
            hasBoundThumbnailView = false
            lastAnnotationSidebarSignature = nil
            pdfView.normalizeMarkupNotes(in: document)
        }

        pdfView.onAskLLM = onAskLLM
        pdfView.onAnnotationSelectionChanged = onAnnotationSelectionChanged
        pdfView.onCitationSelectionChanged = onCitationSelectionChanged
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
                    self?.publishAnnotationSelection(for: item)
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
                if isNote,
                   let parent = annotation.value(forAnnotationKey: .parent) as? PDFAnnotation,
                   isSidebarMarkupAnnotation(parent) {
                    continue
                }

                let annotationGroup = relatedSidebarAnnotations(for: annotation, on: page)
                let annotationKey = sidebarAnnotationKey(for: annotation, relatedAnnotations: annotationGroup)
                guard seenAnnotationKeys.insert(annotationKey).inserted else { continue }

                items.append(
                    PDFAnnotationSidebarItem(
                        id: annotationKey,
                        pageLabel: "Page \(index + 1)",
                        authorName: sidebarAuthorName(for: annotationGroup),
                        excerpt: sidebarExcerpt(for: annotationGroup, on: page),
                        note: sidebarNote(for: annotationGroup, on: page),
                        accentColor: sidebarAccentColor(for: annotationGroup, isNote: isNote),
                        page: page,
                        annotation: annotation
                    )
                )
            }
        }
        return items
    }

    private func isSidebarMarkupAnnotation(_ annotation: PDFAnnotation) -> Bool {
        let typeName = (annotation.type ?? "").lowercased()
        return typeName.contains("highlight")
            || typeName.contains("underline")
            || typeName.contains("strike")
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
        let fragments = annotations.compactMap { annotation -> String? in
            // When a single annotation covers multiple lines via quadrilateralPoints,
            // extract text per quad rect so we only capture the highlighted portions,
            // not the full union bounding box (which would include non-highlighted text).
            if let quadValues = annotation.quadrilateralPoints,
               quadValues.count >= 8, quadValues.count % 4 == 0 {
                // Quad points are stored relative to the annotation's bounds.origin,
                // so translate back to absolute page coordinates before querying text.
                let ox = annotation.bounds.minX
                let oy = annotation.bounds.minY
                let pts = quadValues.map { $0.pointValue }
                let lineTexts = stride(from: 0, to: pts.count, by: 4).compactMap { i -> String? in
                    // Quad order: top-left, top-right, bottom-left, bottom-right.
                    let minX = min(pts[i].x, pts[i + 2].x) + ox
                    let maxX = max(pts[i + 1].x, pts[i + 3].x) + ox
                    let minY = min(pts[i + 2].y, pts[i + 3].y) + oy
                    let maxY = max(pts[i].y, pts[i + 1].y) + oy
                    let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                    return page.selection(for: rect)?
                        .string?
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                return lineTexts.isEmpty ? nil : lineTexts.joined(separator: " ")
            }
            return page.selection(for: annotation.bounds)?
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

    private func sidebarNote(for annotations: [PDFAnnotation], on page: PDFPage) -> String? {
        for annotation in annotations {
            let note = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !note.isEmpty {
                return note
            }

            let popupContents = annotation.popup?.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !popupContents.isEmpty {
                return popupContents
            }
        }

        let relatedNoteMarkers = page.annotations.filter { candidate in
            let typeName = (candidate.type ?? "").lowercased()
            guard typeName.contains("text") else { return false }
            guard let parent = candidate.value(forAnnotationKey: .parent) as? PDFAnnotation else { return false }

            return annotations.contains(where: { parent === $0 || sidebarAnnotationsLikelySame(parent, $0) })
        }

        for marker in relatedNoteMarkers {
            let note = marker.contents?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            if !note.isEmpty {
                return note
            }

            let popupContents = marker.popup?.contents?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            if !popupContents.isEmpty {
                return popupContents
            }
        }
        return nil
    }

    private func sidebarAnnotationsLikelySame(_ lhs: PDFAnnotation, _ rhs: PDFAnnotation) -> Bool {
        guard lhs.type == rhs.type else { return false }

        let dx = abs(lhs.bounds.origin.x - rhs.bounds.origin.x)
        let dy = abs(lhs.bounds.origin.y - rhs.bounds.origin.y)
        let dw = abs(lhs.bounds.size.width - rhs.bounds.size.width)
        let dh = abs(lhs.bounds.size.height - rhs.bounds.size.height)

        return dx < 0.5 && dy < 0.5 && dw < 0.5 && dh < 0.5
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

    private func publishAnnotationSelection(for item: PDFAnnotationSidebarItem) {
        guard let annotation = item.annotation else {
            pdfView.onAnnotationSelectionChanged?(nil)
            return
        }
        pdfView.publishAnnotationSelection(
            for: annotation,
            fallbackPage: item.page
        )
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
                if isNote,
                   let parent = annotation.value(forAnnotationKey: .parent) as? PDFAnnotation,
                   isSidebarMarkupAnnotation(parent) {
                    continue
                }

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
    var onAnnotationSelectionChanged: AnnotationSelectionHandler?
    var onCitationSelectionChanged: CitationSelectionHandler?
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
    private var citationNavigationObserver: NSObjectProtocol?
    private var pendingModeApplyWorkItem: DispatchWorkItem?
    private var currentAnnotationAction: PDFAnnotationAction = .highlightYellow
    private var isHighlighterModeEnabled = false
    private var isApplyingFromMode = false
    private var lastModeSelectionFingerprint: String?
    private var lastSearchSignature: String = ""
    private var searchMatches: [PDFSelection] = []
    private var currentSearchMatchIndex: Int?
    private var pendingActionAnnotation: PDFAnnotation?
    private var shouldSuppressMouseUpAfterCitationIntercept = false
    // Active-annotation live note polling
    private var activeAnnotation: PDFAnnotation?
    private var activeFallbackPage: PDFPage?
    private var lastPublishedNoteContents: String = ""
    private var activeAnnotationMonitorTimer: Timer?
    private var lastPublishedSelectionBase: AnnotationRenderSelection?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerAnnotationObserver()
        registerSelectionObserver()
        registerSaveObserver()
        registerSearchNavigationObservers()
        registerCitationNavigationObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerAnnotationObserver()
        registerSelectionObserver()
        registerSaveObserver()
        registerSearchNavigationObservers()
        registerCitationNavigationObserver()
    }

    deinit {
        pendingModeApplyWorkItem?.cancel()
        activeAnnotationMonitorTimer?.invalidate()
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
        if let citationNavigationObserver {
            NotificationCenter.default.removeObserver(citationNavigationObserver)
        }
    }

    override func setCurrentSelection(_ selection: PDFSelection?, animate: Bool) {
        super.setCurrentSelection(selection, animate: animate)
    }

    override func mouseDown(with event: NSEvent) {
        pendingActionAnnotation = annotation(at: event)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if shouldSuppressMouseUpAfterCitationIntercept {
            shouldSuppressMouseUpAfterCitationIntercept = false
            pendingActionAnnotation = nil
            return
        }

        super.mouseUp(with: event)
        pendingActionAnnotation = nil
        let clickedAnnotation = annotation(at: event)
        onCitationSelectionChanged?(nil)
        publishAnnotationSelection(for: clickedAnnotation, fallbackPage: contextMenuPage)
    }

    override func perform(_ action: PDFAction) {
        defer { pendingActionAnnotation = nil }

        if let citationSelection = resolvedCitationLinkSelection(
            for: pendingActionAnnotation,
            fallbackPage: pendingActionAnnotation?.page ?? contextMenuPage
        ) {
            shouldSuppressMouseUpAfterCitationIntercept = true
            publishAnnotationSelection(for: nil, fallbackPage: nil)
            onCitationSelectionChanged?(citationSelection)
            return
        }

        super.perform(action)
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
        publishAnnotationSelection(for: contextMenuAnnotation, fallbackPage: contextMenuPage)

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
        let noteTarget = contextMarkupNoteTarget()
        var sawRemoveNoteItem = false
        var addNoteItemIndex: Int?

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
                if noteTarget?.noteText?.isEmpty == false {
                    item.title = "Remove Note"
                    item.action = #selector(handleRemoveNoteFromContextMenu(_:))
                    sawRemoveNoteItem = true
                } else {
                    item.action = #selector(handleAddNoteFromContextMenu(_:))
                }
                item.target = self
                addNoteItemIndex = menu.index(of: item)
                continue
            }

            if lowerTitle == "remove note" {
                item.action = #selector(handleRemoveNoteFromContextMenu(_:))
                item.target = self
                item.isEnabled = noteTarget?.noteText?.isEmpty == false
                sawRemoveNoteItem = true
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

        if noteTarget?.noteText?.isEmpty == false,
           !sawRemoveNoteItem {
            let removeItem = NSMenuItem(title: "Remove Note", action: #selector(handleRemoveNoteFromContextMenu(_:)), keyEquivalent: "")
            removeItem.target = self

            if let addNoteItemIndex {
                menu.insertItem(removeItem, at: addNoteItemIndex + 1)
            } else {
                menu.addItem(removeItem)
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

        // Ensure the PDFView is first responder before dispatching _addNote: so the
        // action reaches PDFKit regardless of what held focus before the right-click.
        window?.makeFirstResponder(self)
        _ = NSApp.sendAction(NSSelectorFromString("_addNote:"), to: nil, from: sender)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.normalizeRelatedNoteColors(on: targetPage, targetMarkup: targetMarkup)
            self.notifyAnnotationsDidChange()
        }
    }

    @objc private func handleRemoveNoteFromContextMenu(_ sender: NSMenuItem) {
        guard let noteTarget = contextMarkupNoteTarget() else {
            NSSound.beep()
            return
        }
        guard noteTarget.noteText?.isEmpty == false else {
            NSSound.beep()
            return
        }

        removeNote(forMarkupCluster: noteTarget.cluster, on: noteTarget.page)
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

    private func registerCitationNavigationObserver() {
        citationNavigationObserver = NotificationCenter.default.addObserver(
            forName: .pdfGoToCitationDestination,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let selection = note.object as? CitationLinkSelection else { return }
            self?.goToCitationDestination(selection)
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

    private struct MarkupNoteTarget {
        let page: PDFPage
        let cluster: [PDFAnnotation]
        let noteText: String?
    }

    private struct ResolvedAnnotationRenderTarget {
        let page: PDFPage
        let bounds: CGRect
        let rawText: String
        let authorName: String?
    }

    private struct ResolvedCitationLinkTarget {
        let sourcePage: PDFPage
        let sourceBounds: CGRect
        let labelText: String
        let kind: CitationLinkKind
        let destinationPage: PDFPage?
        let destinationPoint: CGPoint?
        let externalURL: URL?
        let referenceText: String?
    }

    private struct CitationLinkDestinationSignature: Hashable {
        let kind: CitationLinkKind
        let destinationPageIndex: Int?
        let xBucket: Int?
        let yBucket: Int?
        let externalURL: String?
    }

    private struct CitationLabelFingerprint {
        let authorToken: String?
        let yearToken: String?
    }

    private struct ReferenceLineCandidate {
        let text: String
        let range: NSRange
    }

    private func contextMarkupNoteTarget() -> MarkupNoteTarget? {
        if let annotation = contextMenuAnnotation {
            if isRemovableMarkup(annotation), let page = annotation.page {
                let cluster = markupCluster(for: annotation, on: page)
                guard !cluster.isEmpty else { return nil }
                return MarkupNoteTarget(
                    page: page,
                    cluster: cluster,
                    noteText: noteText(forMarkupCluster: cluster, on: page)
                )
            }

            if let parent = annotation.value(forAnnotationKey: .parent) as? PDFAnnotation,
               isRemovableMarkup(parent),
               let page = parent.page ?? contextMenuPage {
                let cluster = markupCluster(for: parent, on: page)
                guard !cluster.isEmpty else { return nil }
                return MarkupNoteTarget(
                    page: page,
                    cluster: cluster,
                    noteText: noteText(forMarkupCluster: cluster, on: page)
                )
            }
        }

        guard let (page, seeds) = contextMarkupTargets() else { return nil }
        let cluster = connectedRemovableAnnotations(from: seeds, on: page)
        let resolvedCluster = cluster.isEmpty ? seeds.filter(isRemovableMarkup) : cluster
        guard !resolvedCluster.isEmpty else { return nil }
        return MarkupNoteTarget(
            page: page,
            cluster: resolvedCluster,
            noteText: noteText(forMarkupCluster: resolvedCluster, on: page)
        )
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

        // Group line rects by page in document order, then create one annotation per page
        // with quadrilateralPoints encoding each line rect. This matches how Preview creates
        // multi-line highlights (one annotation, multiple quads) so that other PDF readers
        // show a single sidebar entry per highlight instead of one entry per line.
        var pageOrder: [PDFPage] = []
        var lineRectsByPage: [ObjectIdentifier: (page: PDFPage, rects: [CGRect])] = [:]

        for lineSelection in lineSelections {
            guard let page = lineSelection.pages.first else { continue }
            let bounds = lineSelection.bounds(for: page)
            guard !bounds.isNull, !bounds.isInfinite, !bounds.isEmpty else { continue }
            let pageID = ObjectIdentifier(page)
            if lineRectsByPage[pageID] == nil {
                lineRectsByPage[pageID] = (page: page, rects: [])
                pageOrder.append(page)
            }
            lineRectsByPage[pageID]!.rects.append(bounds)
        }

        var addedAny = false
        for page in pageOrder {
            guard let entry = lineRectsByPage[ObjectIdentifier(page)] else { continue }
            let lineRects = entry.rects
            let unionBounds = lineRects.dropFirst().reduce(lineRects[0]) { $0.union($1) }

            if hasEquivalentAnnotation(on: page, action: action, bounds: unionBounds) {
                continue
            }

            let annotation = makeAnnotation(for: action, bounds: unionBounds)

            // Store per-line quad points when multiple lines are highlighted so only
            // the individual text lines are visually highlighted, not the whole union rect.
            // PDFKit interprets quadrilateralPoints relative to the annotation's bounds.origin,
            // not as absolute page coordinates, so subtract the origin before storing.
            // PDF quad point order: top-left, top-right, bottom-left, bottom-right.
            if lineRects.count > 1 {
                let ox = unionBounds.minX
                let oy = unionBounds.minY
                annotation.quadrilateralPoints = lineRects.flatMap { rect -> [NSValue] in [
                    NSValue(point: NSPoint(x: rect.minX - ox, y: rect.maxY - oy)),
                    NSValue(point: NSPoint(x: rect.maxX - ox, y: rect.maxY - oy)),
                    NSValue(point: NSPoint(x: rect.minX - ox, y: rect.minY - oy)),
                    NSValue(point: NSPoint(x: rect.maxX - ox, y: rect.minY - oy)),
                ]}
            }

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

            normalizeMarkupNoteAnnotation(annotation, targetMarkup: targetMarkup)
            if let popup = annotation.popup {
                popup.color = NSColor.white
            }
        }

        if let popup = targetMarkup?.popup {
            popup.color = NSColor.white
        }
        if let targetMarkup {
            _ = synchronizeMarkupNoteMarker(for: targetMarkup, on: page)
        }

        refreshAnnotationRendering(on: page)
    }

    private func relatedNoteMarkerColor(for annotation: PDFAnnotation, targetMarkup: PDFAnnotation?) -> NSColor {
        if let parent = annotation.value(forAnnotationKey: .parent) as? PDFAnnotation {
            return parent.color.withAlphaComponent(1.0)
        }
        if let popupParent = annotation.value(forAnnotationKey: .popup) as? PDFAnnotation {
            return popupParent.color.withAlphaComponent(1.0)
        }
        if let targetMarkup {
            return targetMarkup.color.withAlphaComponent(1.0)
        }
        return NSColor.systemYellow
    }

    fileprivate func normalizeMarkupNotes(in document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let markupAnnotations = page.annotations.filter(isRemovableMarkup)
            let normalizedAny = markupAnnotations.reduce(false) { partialResult, markup in
                synchronizeMarkupNoteMarker(for: markup, on: page) || partialResult
            }

            if normalizedAny {
                refreshAnnotationRendering(on: page)
            }
        }
    }

    @discardableResult
    private func synchronizeMarkupNoteMarker(for markup: PDFAnnotation, on page: PDFPage) -> Bool {
        let noteText = noteText(for: markup)
        let markers = markupNoteMarkers(for: markup, on: page)

        guard let noteText, !noteText.isEmpty else {
            var removedAny = false
            for marker in markers {
                page.removeAnnotation(marker)
                removedAny = true
            }
            return removedAny
        }

        let marker = markers.first ?? makeMarkupNoteMarker(for: markup, on: page)
        let markerWasNew = markers.isEmpty
        normalizeMarkupNoteAnnotation(marker, targetMarkup: markup)
        marker.contents = noteText
        marker.bounds = markupNoteMarkerBounds(for: markup, on: page)

        if markerWasNew {
            page.addAnnotation(marker)
        }

        if markers.count > 1 {
            for extraMarker in markers.dropFirst() {
                page.removeAnnotation(extraMarker)
            }
        }

        return markerWasNew || markers.count > 1
    }

    private func noteText(for markup: PDFAnnotation) -> String? {
        let directContents = markup.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !directContents.isEmpty {
            return directContents
        }

        let popupContents = markup.popup?.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !popupContents.isEmpty {
            return popupContents
        }

        return nil
    }

    private func markupNoteMarkers(for markup: PDFAnnotation, on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { annotation in
            let typeName = (annotation.type ?? "").lowercased()
            guard typeName.contains("text") else { return false }

            if let parent = annotation.value(forAnnotationKey: .parent) as? PDFAnnotation {
                return parent === markup || annotationsLikelySame(parent, markup)
            }
            return false
        }
    }

    private func makeMarkupNoteMarker(for markup: PDFAnnotation, on page: PDFPage) -> PDFAnnotation {
        let marker = PDFAnnotation(
            bounds: markupNoteMarkerBounds(for: markup, on: page),
            forType: .text,
            withProperties: nil
        )
        _ = marker.setValue(markup, forAnnotationKey: .parent)
        return marker
    }

    private func markupNoteMarkerBounds(for markup: PDFAnnotation, on page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .cropBox)
        let markerSize = CGSize(width: 18, height: 18)

        let proposedX = markup.bounds.maxX + 6
        let proposedY = markup.bounds.maxY - markerSize.height

        let clampedX = min(max(pageBounds.minX, proposedX), pageBounds.maxX - markerSize.width)
        let clampedY = min(max(pageBounds.minY, proposedY), pageBounds.maxY - markerSize.height)

        return CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: markerSize)
    }

    private func normalizeMarkupNoteAnnotation(_ annotation: PDFAnnotation, targetMarkup: PDFAnnotation?) {
        annotation.shouldDisplay = true
        annotation.color = relatedNoteMarkerColor(
            for: annotation,
            targetMarkup: targetMarkup
        )

        let typeName = (annotation.type ?? "").lowercased()
        if typeName.contains("text") {
            annotation.iconType = .note
        }
    }

    private func noteText(forMarkupCluster cluster: [PDFAnnotation], on page: PDFPage) -> String? {
        for markup in cluster {
            let directContents = markup.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !directContents.isEmpty {
                return directContents
            }

            let popupContents = markup.popup?.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !popupContents.isEmpty {
                return popupContents
            }
        }

        for marker in markupNoteMarkers(forMarkupCluster: cluster, on: page) {
            let markerContents = marker.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !markerContents.isEmpty {
                return markerContents
            }

            let popupContents = marker.popup?.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !popupContents.isEmpty {
                return popupContents
            }
        }

        return nil
    }

    private func markupNoteMarkers(forMarkupCluster cluster: [PDFAnnotation], on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { annotation in
            let typeName = (annotation.type ?? "").lowercased()
            guard typeName.contains("text") else { return false }
            guard let parent = annotation.value(forAnnotationKey: .parent) as? PDFAnnotation else { return false }

            return cluster.contains(where: { parent === $0 || annotationsLikelySame(parent, $0) })
        }
    }

    private func removeNote(forMarkupCluster cluster: [PDFAnnotation], on page: PDFPage) {
        var changedAny = false
        let markers = markupNoteMarkers(forMarkupCluster: cluster, on: page)

        for marker in markers {
            removeAnnotationAndRelatedNotes(marker, from: page, notifyChange: false)
            changedAny = true
        }

        let strayPopups = page.annotations.filter { annotation in
            let typeName = (annotation.type ?? "").lowercased()
            guard typeName.contains("popup") else { return false }
            guard let parent = annotation.value(forAnnotationKey: .parent) as? PDFAnnotation else { return false }

            if cluster.contains(where: { parent === $0 || annotationsLikelySame(parent, $0) }) {
                return true
            }

            return markers.contains(where: { parent === $0 || annotationsLikelySame(parent, $0) })
        }
        for popup in strayPopups {
            page.removeAnnotation(popup)
            changedAny = true
        }

        for markup in cluster {
            if markup.contents?.isEmpty == false {
                markup.contents = nil
                changedAny = true
            }

            if let popup = markup.popup {
                popup.contents = nil
                if page.annotations.contains(where: { $0 === popup }) {
                    page.removeAnnotation(popup)
                }
                markup.popup = nil
                changedAny = true
            }
        }

        if changedAny {
            refreshAnnotationRendering(on: page)
            notifyAnnotationsDidChange()
            onAnnotationSelectionChanged?(nil)
        } else {
            NSSound.beep()
        }
    }

    func publishAnnotationSelection(for annotation: PDFAnnotation, fallbackPage: PDFPage? = nil) {
        publishAnnotationSelection(for: Optional(annotation), fallbackPage: fallbackPage)
    }

    private func publishAnnotationSelection(for annotation: PDFAnnotation?, fallbackPage: PDFPage?) {
        guard let target = resolvedAnnotationRenderTarget(for: annotation, fallbackPage: fallbackPage) else {
            activeAnnotation = nil
            activeFallbackPage = nil
            lastPublishedNoteContents = ""
            lastPublishedSelectionBase = nil
            stopActiveAnnotationMonitoring()
            onAnnotationSelectionChanged?(nil)
            return
        }
        activeAnnotation = annotation
        activeFallbackPage = fallbackPage
        lastPublishedNoteContents = target.rawText
        let documentPath = document?.documentURL?.path ?? ""
        let pageIndex = document.flatMap { $0.index(for: target.page) } ?? 0
        let selection = AnnotationRenderSelection(
            documentPath: documentPath,
            pageIndex: pageIndex,
            annotationBounds: target.bounds,
            rawText: target.rawText,
            authorName: target.authorName
        )
        lastPublishedSelectionBase = selection
        startActiveAnnotationMonitoring()
        onAnnotationSelectionChanged?(selection)
    }

    private func startActiveAnnotationMonitoring() {
        guard activeAnnotationMonitorTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.pollActiveAnnotationNote()
        }
        RunLoop.main.add(timer, forMode: .common)
        activeAnnotationMonitorTimer = timer
    }

    private func stopActiveAnnotationMonitoring() {
        activeAnnotationMonitorTimer?.invalidate()
        activeAnnotationMonitorTimer = nil
    }

    // Returns the live string from whichever NSTextView PDFKit is using to
    // edit the annotation note right now.  PDFKit may open a floating popup
    // window (different NSWindow) or edit inline inside the PDFView itself.
    private func liveEditingText() -> String? {
        // Floating popup: PDFKit opens a separate NSWindow/NSPanel for the note.
        if let keyWindow = NSApp.keyWindow,
           keyWindow !== self.window,
           let textView = keyWindow.firstResponder as? NSTextView {
            return textView.string
        }
        // Inline editing: the editor NSTextView is a descendant of this PDFView.
        if let textView = self.window?.firstResponder as? NSTextView,
           textView.isDescendant(of: self) {
            return textView.string
        }
        return nil
    }

    private func pollActiveAnnotationNote() {
        guard let annotation = activeAnnotation else {
            stopActiveAnnotationMonitoring()
            return
        }
        // While the PDFKit popup/inline editor is open, read live text from the
        // first responder — annotation.contents is only committed on popup close.
        if let live = liveEditingText() {
            publishNoteContentsUpdate(live)
            return
        }
        // Popup is closed — fall back to committed annotation.contents.
        guard let target = resolvedAnnotationRenderTarget(for: annotation, fallbackPage: activeFallbackPage) else {
            return
        }
        guard target.rawText != lastPublishedNoteContents else { return }
        lastPublishedNoteContents = target.rawText
        let documentPath = document?.documentURL?.path ?? ""
        let pageIndex = document.flatMap { $0.index(for: target.page) } ?? 0
        let selection = AnnotationRenderSelection(
            documentPath: documentPath,
            pageIndex: pageIndex,
            annotationBounds: target.bounds,
            rawText: target.rawText,
            authorName: target.authorName
        )
        lastPublishedSelectionBase = selection
        onAnnotationSelectionChanged?(selection)
    }

    private func publishNoteContentsUpdate(_ text: String) {
        guard let base = lastPublishedSelectionBase,
              text != lastPublishedNoteContents else { return }
        lastPublishedNoteContents = text
        onAnnotationSelectionChanged?(
            AnnotationRenderSelection(
                documentPath: base.documentPath,
                pageIndex: base.pageIndex,
                annotationBounds: base.annotationBounds,
                rawText: text,
                authorName: base.authorName
            )
        )
    }

    private func goToCitationDestination(_ selection: CitationLinkSelection) {
        guard let document,
              document.documentURL?.path == selection.documentPath,
              let destinationPageIndex = selection.destinationPageIndex,
              let page = document.page(at: destinationPageIndex)
        else {
            return
        }

        if let point = selection.destinationPoint {
            go(to: PDFDestination(page: page, at: point))
        } else {
            go(to: page)
        }
    }

    private func resolvedCitationLinkSelection(
        for annotation: PDFAnnotation?,
        fallbackPage: PDFPage?
    ) -> CitationLinkSelection? {
        guard let target = resolvedCitationLinkTarget(for: annotation, fallbackPage: fallbackPage),
              looksLikeCitationLabel(target.labelText)
        else {
            return nil
        }

        let documentPath = document?.documentURL?.path ?? ""
        let sourcePageIndex = document.flatMap { $0.index(for: target.sourcePage) } ?? 0
        let destinationPageIndex = target.destinationPage.flatMap { page in
            document?.index(for: page)
        }

        return CitationLinkSelection(
            documentPath: documentPath,
            sourcePageIndex: sourcePageIndex,
            sourceBounds: target.sourceBounds,
            labelText: target.labelText,
            linkKind: target.kind,
            destinationPageIndex: destinationPageIndex,
            destinationPoint: target.destinationPoint,
            externalURL: target.externalURL,
            referenceText: target.referenceText
        )
    }

    private func resolvedAnnotationRenderTarget(
        for annotation: PDFAnnotation?,
        fallbackPage: PDFPage?
    ) -> ResolvedAnnotationRenderTarget? {
        guard let annotation else { return nil }

        if isRemovableMarkup(annotation),
           let page = annotation.page ?? fallbackPage {
            let cluster = markupCluster(for: annotation, on: page)
            let resolvedCluster = cluster.isEmpty ? [annotation] : cluster
            guard let rawText = noteText(forMarkupCluster: resolvedCluster, on: page)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawText.isEmpty
            else {
                return nil
            }
            let bounds = resolvedCluster.reduce(annotation.bounds) { partialResult, item in
                partialResult.union(item.bounds)
            }
            return ResolvedAnnotationRenderTarget(
                page: page,
                bounds: bounds,
                rawText: rawText,
                authorName: authorName(for: resolvedCluster)
            )
        }

        if let parent = annotation.value(forAnnotationKey: .parent) as? PDFAnnotation,
           isRemovableMarkup(parent),
           let page = parent.page ?? fallbackPage {
            let cluster = markupCluster(for: parent, on: page)
            let resolvedCluster = cluster.isEmpty ? [parent] : cluster
            guard let rawText = noteText(forMarkupCluster: resolvedCluster, on: page)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawText.isEmpty
            else {
                return nil
            }
            let bounds = resolvedCluster.reduce(parent.bounds) { partialResult, item in
                partialResult.union(item.bounds)
            }
            return ResolvedAnnotationRenderTarget(
                page: page,
                bounds: bounds,
                rawText: rawText,
                authorName: authorName(for: [annotation] + resolvedCluster)
            )
        }

        guard let page = annotation.page ?? fallbackPage else { return nil }
        let directContents = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let popupContents = annotation.popup?.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawText = !directContents.isEmpty ? directContents : popupContents
        guard !rawText.isEmpty else { return nil }

        return ResolvedAnnotationRenderTarget(
            page: page,
            bounds: annotation.bounds,
            rawText: rawText,
            authorName: authorName(for: [annotation])
        )
    }

    private func resolvedCitationLinkTarget(
        for annotation: PDFAnnotation?,
        fallbackPage: PDFPage?
    ) -> ResolvedCitationLinkTarget? {
        guard let annotation,
              let page = annotation.page ?? fallbackPage
        else {
            return nil
        }

        let typeName = (annotation.type ?? "").lowercased()
        guard typeName.contains("link") else { return nil }

        let kind: CitationLinkKind
        let destinationPage: PDFPage?
        let destinationPoint: CGPoint?
        let externalURL: URL?

        if let action = annotation.action as? PDFActionGoTo {
            kind = .internalReference
            destinationPage = action.destination.page
            destinationPoint = action.destination.point
            externalURL = nil
        } else if let destination = annotation.destination {
            kind = .internalReference
            destinationPage = destination.page
            destinationPoint = destination.point
            externalURL = nil
        } else if let action = annotation.action as? PDFActionURL {
            kind = .externalURL
            destinationPage = nil
            destinationPoint = nil
            externalURL = action.url
        } else {
            return nil
        }

        let cluster = citationLinkCluster(
            containing: annotation,
            on: page,
            kind: kind,
            destinationPage: destinationPage,
            destinationPoint: destinationPoint,
            externalURL: externalURL
        )
        let sourceBounds = cluster.reduce(annotation.bounds) { partialResult, item in
            partialResult.union(item.bounds)
        }
        let labelText = resolvedCitationLabel(
            from: cluster,
            primaryAnnotation: annotation,
            on: page
        )
        guard !labelText.isEmpty else { return nil }

        return ResolvedCitationLinkTarget(
            sourcePage: page,
            sourceBounds: sourceBounds,
            labelText: labelText,
            kind: kind,
            destinationPage: destinationPage,
            destinationPoint: destinationPoint,
            externalURL: externalURL,
            referenceText: destinationPage.map {
                referenceContextText(
                    around: destinationPoint,
                    on: $0,
                    matching: labelText
                )
            }
        )
    }

    private func citationLabelText(for annotation: PDFAnnotation, on page: PDFPage) -> String {
        let raw = page.selection(for: annotation.bounds)?.string
            ?? annotation.contents
            ?? ""
        return raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func citationLinkCluster(
        containing annotation: PDFAnnotation,
        on page: PDFPage,
        kind: CitationLinkKind,
        destinationPage: PDFPage?,
        destinationPoint: CGPoint?,
        externalURL: URL?
    ) -> [PDFAnnotation] {
        let signature = citationDestinationSignature(
            kind: kind,
            destinationPage: destinationPage,
            destinationPoint: destinationPoint,
            externalURL: externalURL
        )
        let candidates = page.annotations
            .filter { candidate in
                let typeName = (candidate.type ?? "").lowercased()
                guard typeName.contains("link") else { return false }
                return citationDestinationSignature(for: candidate) == signature
            }
            .sorted { lhs, rhs in
                if abs(lhs.bounds.midY - rhs.bounds.midY) > 2 {
                    return lhs.bounds.midY > rhs.bounds.midY
                }
                return lhs.bounds.minX < rhs.bounds.minX
            }

        guard let seedIndex = candidates.firstIndex(where: { $0 === annotation || annotationsLikelySame($0, annotation) }) else {
            return [annotation]
        }

        var cluster: [PDFAnnotation] = [candidates[seedIndex]]
        var leftIndex = seedIndex - 1
        while leftIndex >= 0 {
            let candidate = candidates[leftIndex]
            guard citationAnnotationsAreAdjacent(candidate, cluster.first!) else { break }
            cluster.insert(candidate, at: 0)
            leftIndex -= 1
        }

        var rightIndex = seedIndex + 1
        while rightIndex < candidates.count {
            let candidate = candidates[rightIndex]
            guard citationAnnotationsAreAdjacent(cluster.last!, candidate) else { break }
            cluster.append(candidate)
            rightIndex += 1
        }

        return cluster
    }

    private func citationAnnotationsAreAdjacent(_ lhs: PDFAnnotation, _ rhs: PDFAnnotation) -> Bool {
        let verticalGap = abs(lhs.bounds.midY - rhs.bounds.midY)
        let horizontalGap = rhs.bounds.minX - lhs.bounds.maxX
        return verticalGap <= 4 && horizontalGap <= 18
    }

    private func citationDestinationSignature(
        for annotation: PDFAnnotation
    ) -> CitationLinkDestinationSignature? {
        if let action = annotation.action as? PDFActionGoTo {
            return citationDestinationSignature(
                kind: .internalReference,
                destinationPage: action.destination.page,
                destinationPoint: action.destination.point,
                externalURL: nil
            )
        }
        if let destination = annotation.destination {
            return citationDestinationSignature(
                kind: .internalReference,
                destinationPage: destination.page,
                destinationPoint: destination.point,
                externalURL: nil
            )
        }
        if let action = annotation.action as? PDFActionURL {
            return citationDestinationSignature(
                kind: .externalURL,
                destinationPage: nil,
                destinationPoint: nil,
                externalURL: action.url
            )
        }
        return nil
    }

    private func citationDestinationSignature(
        kind: CitationLinkKind,
        destinationPage: PDFPage?,
        destinationPoint: CGPoint?,
        externalURL: URL?
    ) -> CitationLinkDestinationSignature {
        let destinationPageIndex = destinationPage.flatMap { page in
            document?.index(for: page)
        }
        let xBucket = destinationPoint.map { Int(($0.x / 6).rounded()) }
        let yBucket = destinationPoint.map { Int(($0.y / 6).rounded()) }
        return CitationLinkDestinationSignature(
            kind: kind,
            destinationPageIndex: destinationPageIndex,
            xBucket: xBucket,
            yBucket: yBucket,
            externalURL: externalURL?.absoluteString
        )
    }

    private func resolvedCitationLabel(
        from cluster: [PDFAnnotation],
        primaryAnnotation: PDFAnnotation,
        on page: PDFPage
    ) -> String {
        let combinedLabel = cleanCitationText(
            cluster.map { citationLabelText(for: $0, on: page) }.joined(separator: " ")
        )
        if looksLikeCitationLabel(combinedLabel) {
            return combinedLabel
        }

        let bounds = cluster.reduce(primaryAnnotation.bounds) { partialResult, item in
            partialResult.union(item.bounds)
        }
        let contexts = citationLineContexts(around: bounds, on: page)
        let primaryLabel = cleanCitationText(citationLabelText(for: primaryAnnotation, on: page))

        if let inferred = inferCitationLabel(
            current: combinedLabel.isEmpty ? primaryLabel : combinedLabel,
            primaryFragment: primaryLabel,
            leftContext: contexts.left,
            rightContext: contexts.right
        ) {
            return inferred
        }

        return combinedLabel.isEmpty ? primaryLabel : combinedLabel
    }

    private func citationLineContexts(
        around bounds: CGRect,
        on page: PDFPage
    ) -> (left: String, right: String) {
        let samplePoint = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let lineSelection = page.selectionForLine(at: samplePoint) else {
            return ("", "")
        }

        let lineBounds = lineSelection.bounds(for: page).insetBy(dx: -2, dy: -1)
        let leftRect = CGRect(
            x: lineBounds.minX,
            y: lineBounds.minY,
            width: max(0, bounds.minX - lineBounds.minX),
            height: lineBounds.height
        )
        let rightRect = CGRect(
            x: bounds.maxX,
            y: lineBounds.minY,
            width: max(0, lineBounds.maxX - bounds.maxX),
            height: lineBounds.height
        )

        let leftText = cleanCitationText(page.selection(for: leftRect)?.string ?? "")
        let rightText = cleanCitationText(page.selection(for: rightRect)?.string ?? "")
        return (leftText, rightText)
    }

    private func inferCitationLabel(
        current: String,
        primaryFragment: String,
        leftContext: String,
        rightContext: String
    ) -> String? {
        let currentTrimmed = cleanCitationText(current)
        let fragmentTrimmed = cleanCitationText(primaryFragment)

        if fragmentTrimmed.range(of: #"^[a-z]$"#, options: .regularExpression) != nil,
           let inherited = inheritedAuthorYearPrefix(from: leftContext) {
            return "\(inherited.authorPart)\(inherited.year)\(fragmentTrimmed)"
        }

        if fragmentTrimmed.range(of: #"^(19|20)\d{2}[a-z]?$"#, options: .regularExpression) != nil,
           let authorPart = inheritedAuthorYearPrefix(from: leftContext)?.authorPart {
            return cleanCitationText("\(authorPart)\(fragmentTrimmed)")
        }

        if !looksLikeCitationLabel(currentTrimmed),
           let authorPart = trailingAuthorCitationPrefix(from: leftContext),
           let yearFragment = leadingYearFragment(from: rightContext) {
            return cleanCitationText("\(authorPart)\(yearFragment)")
        }

        return looksLikeCitationLabel(currentTrimmed) ? currentTrimmed : nil
    }

    private func inheritedAuthorYearPrefix(from leftContext: String) -> (authorPart: String, year: String)? {
        let pattern = #"([A-Z][A-Za-z0-9 .,&'’\-]+?(?:et al\.,?\s*|and [A-Z][A-Za-z0-9 .,&'’\-]+\s*,?\s*|,\s*))((?:19|20)\d{2})[a-z]?\s*[,;]?\s*$"#
        guard let match = citationRegexMatch(pattern, in: leftContext),
              match.count > 2 else {
            return nil
        }
        return (cleanCitationText(match[1]), match[2])
    }

    private func trailingAuthorCitationPrefix(from leftContext: String) -> String? {
        let patterns = [
            #"([A-Z][A-Za-z0-9 .,&'’\-]+?et al\.,?\s*)$"#,
            #"([A-Z][A-Za-z0-9 .,&'’\-]+?,\s*)$"#
        ]

        for pattern in patterns {
            if let match = citationRegexMatch(pattern, in: leftContext), match.count > 1 {
                return cleanCitationText(match[1])
            }
        }
        return nil
    }

    private func leadingYearFragment(from rightContext: String) -> String? {
        let patterns = [
            #"^((?:19|20)\d{2}[a-z]?)"#,
            #"^,\s*((?:19|20)\d{2}[a-z]?)"#
        ]

        for pattern in patterns {
            if let match = citationRegexMatch(pattern, in: rightContext), match.count > 1 {
                return cleanCitationText(match[1])
            }
        }
        return nil
    }

    private func citationRegexMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let nsRange = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else {
            return nil
        }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func cleanCitationText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,;:.])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func referenceContextText(
        around point: CGPoint?,
        on page: PDFPage,
        matching labelText: String
    ) -> String {
        let nearbyLines = nearbyReferenceLines(around: point, on: page)
        if let matchedEntry = bestMatchingReferenceEntry(
            for: labelText,
            among: nearbyLines
        ) {
            return matchedEntry
        }

        let seedPoint = point ?? CGPoint(
            x: page.bounds(for: .cropBox).midX,
            y: page.bounds(for: .cropBox).midY
        )
        guard let firstLine = page.selectionForLine(at: seedPoint),
              let firstRange = referenceLineRange(for: firstLine, on: page)
        else {
            return ""
        }

        let pageString = page.string ?? ""
        var lines: [String] = [cleanCitationText(firstLine.string ?? "")]
        var nextIndex = NSMaxRange(firstRange)

        for _ in 0..<4 {
            nextIndex = nextNonWhitespaceCharacterIndex(in: pageString, from: nextIndex)
            guard nextIndex < page.numberOfCharacters,
                  let nextLine = lineSelection(atCharacterIndex: nextIndex, on: page),
                  let nextRange = referenceLineRange(for: nextLine, on: page)
            else {
                break
            }

            let nextText = cleanCitationText(nextLine.string ?? "")
            guard !nextText.isEmpty else { break }
            if looksLikeNewReferenceEntry(nextText), !lines.isEmpty {
                break
            }
            if lines.last == nextText {
                break
            }

            lines.append(nextText)
            nextIndex = NSMaxRange(nextRange)
        }

        return lines.joined(separator: " ")
    }

    private func nearbyReferenceLines(
        around point: CGPoint?,
        on page: PDFPage
    ) -> [ReferenceLineCandidate] {
        let pageBounds = page.bounds(for: .cropBox)
        let anchorY = point?.y ?? pageBounds.midY
        let scanRect = CGRect(
            x: pageBounds.minX,
            y: max(pageBounds.minY, anchorY - 120),
            width: pageBounds.width,
            height: min(pageBounds.height, 240)
        )

        guard let selection = page.selection(for: scanRect) else { return [] }
        let lines = selection.selectionsByLine()
            .filter { $0.pages.first === page }
            .compactMap { lineSelection -> ReferenceLineCandidate? in
                guard let range = referenceLineRange(for: lineSelection, on: page) else {
                    return nil
                }
                let text = cleanCitationText(lineSelection.string ?? "")
                guard !text.isEmpty else { return nil }
                return ReferenceLineCandidate(text: text, range: range)
            }

        return lines.sorted { lhs, rhs in
            lhs.range.location < rhs.range.location
        }
    }

    private func bestMatchingReferenceEntry(
        for labelText: String,
        among lines: [ReferenceLineCandidate]
    ) -> String? {
        guard !lines.isEmpty else { return nil }
        let fingerprint = citationLabelFingerprint(from: labelText)
        var bestEntry: String?
        var bestScore = Int.min

        for startIndex in lines.indices {
            let entry = collectReferenceEntry(startingAt: startIndex, from: lines)
            let score = referenceEntryScore(entry, fingerprint: fingerprint)
            if score > bestScore {
                bestScore = score
                bestEntry = entry
            }
        }

        return bestScore > 0 ? bestEntry : nil
    }

    private func collectReferenceEntry(
        startingAt startIndex: Int,
        from lines: [ReferenceLineCandidate]
    ) -> String {
        guard lines.indices.contains(startIndex) else { return "" }
        var collected = [lines[startIndex].text]
        var nextIndex = startIndex + 1

        while nextIndex < lines.count {
            let nextLine = lines[nextIndex].text
            if looksLikeNewReferenceEntry(nextLine) {
                break
            }
            if collected.last == nextLine {
                break
            }
            collected.append(nextLine)
            nextIndex += 1
        }

        return collected.joined(separator: " ")
    }

    private func citationLabelFingerprint(from labelText: String) -> CitationLabelFingerprint {
        let cleaned = cleanCitationText(labelText)

        let yearToken = citationRegexMatch(
            #"((?:19|20)\d{2}[a-z]?)"#,
            in: cleaned
        )?.dropFirst().first.map { String($0) }

        let authorPatterns = [
            #"([A-Z][A-Za-z'’\-]+)\s+et al\."#,
            #"([A-Z][A-Za-z'’\-]+)\s+and\s+[A-Z][A-Za-z'’\-]+"#,
            #"([A-Z][A-Za-z'’\-]+),"#
        ]

        var authorToken: String?
        for pattern in authorPatterns {
            if let match = citationRegexMatch(pattern, in: cleaned),
               match.count > 1 {
                authorToken = match[1].lowercased()
                break
            }
        }

        return CitationLabelFingerprint(
            authorToken: authorToken,
            yearToken: yearToken?.lowercased()
        )
    }

    private func referenceEntryScore(
        _ entry: String,
        fingerprint: CitationLabelFingerprint
    ) -> Int {
        let normalizedEntry = cleanCitationText(entry).lowercased()
        guard !normalizedEntry.isEmpty else { return Int.min }

        var score = 0

        if let authorToken = fingerprint.authorToken {
            if normalizedEntry.range(of: "\\b\(NSRegularExpression.escapedPattern(for: authorToken))\\b", options: .regularExpression) != nil {
                score += 5
            } else {
                score -= 4
            }
        }

        if let yearToken = fingerprint.yearToken {
            if normalizedEntry.contains(yearToken) {
                score += 8
            } else if normalizedEntry.contains(String(yearToken.prefix(4))) {
                score += 3
            } else {
                score -= 6
            }
        }

        if looksLikeNewReferenceEntry(entry) {
            score += 1
        }

        return score
    }

    private func lineSelection(atCharacterIndex index: Int, on page: PDFPage) -> PDFSelection? {
        guard index >= 0, index < page.numberOfCharacters else { return nil }
        guard let selection = page.selection(for: NSRange(location: index, length: 1)) else {
            return nil
        }
        selection.extendForLineBoundaries()
        return selection
    }

    private func referenceLineRange(for selection: PDFSelection, on page: PDFPage) -> NSRange? {
        guard selection.pages.contains(where: { $0 === page }),
              selection.numberOfTextRanges(on: page) > 0
        else {
            return nil
        }
        return selection.range(at: 0, on: page)
    }

    private func nextNonWhitespaceCharacterIndex(in text: String, from start: Int) -> Int {
        guard start < text.count else { return start }
        let characters = Array(text)
        var index = start
        while index < characters.count {
            if !characters[index].isWhitespace && characters[index] != "\n" && characters[index] != "\r" {
                return index
            }
            index += 1
        }
        return index
    }

    private func looksLikeNewReferenceEntry(_ text: String) -> Bool {
        let patterns = [
            #"^[A-Z][A-Za-z'’\-]+,\s*[A-Z]"#,
            #"^[A-Z][A-Za-z'’\-]+(?:\s+[A-Z][A-Za-z'’\-]+)*,\s*(?:[A-Z]\.)"#,
            #"^[A-Z][A-Za-z0-9 .,&'’\-]+?\.\s*(19|20)\d{2}[a-z]?\."#,
            #"^(?:[A-Z][A-Za-z'’\-]+(?:\s+[A-Z][A-Za-z'’\-]+)+,\s*){2,}"#,
            #"^(?:[A-Z]\.\s*)?[A-Z][A-Za-z'’\-]+,\s+(?:[A-Z][A-Za-z'’\-]+\s+){1,3}[A-Z][A-Za-z'’\-]+(?:,\s*(?:and\s+)?){1}"#
        ]

        for pattern in patterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    private func looksLikeCitationLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { return false }

        let patterns = [
            #"\b(19|20)\d{2}[a-z]?\b"#,
            #"\bet al\.\b"#,
            #"\[[0-9,\-\s]+\]"#,
            #"\([A-Z][^)]*?\d{4}[^)]*\)"#
        ]

        for pattern in patterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    private func authorName(for annotations: [PDFAnnotation]) -> String? {
        for annotation in annotations {
            guard let userName = annotation.userName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !userName.isEmpty,
                  !userName.hasPrefix(Self.markupGroupPrefix)
            else {
                continue
            }
            return userName
        }
        return nil
    }

    private func refreshAnnotationRendering(on page: PDFPage) {
        annotationsChanged(on: page)
        needsDisplay = true
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

    private func markupCluster(for seed: PDFAnnotation, on page: PDFPage) -> [PDFAnnotation] {
        let removable = page.annotations.filter(isRemovableMarkup)
        let cluster = groupedAnnotations(for: seed, in: removable)
        return cluster.sorted { lhs, rhs in
            if abs(lhs.bounds.maxY - rhs.bounds.maxY) > 0.5 {
                return lhs.bounds.maxY > rhs.bounds.maxY
            }
            return lhs.bounds.minX < rhs.bounds.minX
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

    private func removeAnnotationAndRelatedNotes(_ target: PDFAnnotation, from page: PDFPage, notifyChange: Bool = true) {
        var toRemove: [PDFAnnotation] = [target]

        if let popup = target.value(forAnnotationKey: .popup) as? PDFAnnotation {
            toRemove.append(popup)
        }

        for candidate in page.annotations {
            guard candidate !== target else { continue }
            let parentRef = candidate.value(forAnnotationKey: .parent) as? PDFAnnotation
            let popupRef  = candidate.value(forAnnotationKey: .popup)  as? PDFAnnotation
            // Notes can be linked to their parent markup via .parent (app-created markers) or
            // via .popup (system _addNote: notes). Both cases must be caught here, mirroring
            // the same dual-check already used in normalizeRelatedNoteColors.
            let linkedViaParent = parentRef.map { $0 === target || annotationsLikelySame($0, target) } == true
            let linkedViaPopup  = popupRef.map  { $0 === target || annotationsLikelySame($0, target) } == true
            guard linkedViaParent || linkedViaPopup else { continue }
            toRemove.append(candidate)
            // Also remove this child's own popup window (e.g. the floating note editor
            // attached to a text/note-icon annotation).
            if let childPopup = candidate.value(forAnnotationKey: .popup) as? PDFAnnotation,
               childPopup !== target {
                toRemove.append(childPopup)
            }
        }

        var removed = Set<ObjectIdentifier>()
        for annotation in toRemove {
            let id = ObjectIdentifier(annotation)
            guard removed.insert(id).inserted else { continue }
            page.removeAnnotation(annotation)
        }

        if notifyChange, !removed.isEmpty {
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
