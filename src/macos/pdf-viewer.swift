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

extension Notification.Name {
    static let pdfApplyAnnotation = Notification.Name("PDFApplyAnnotation")
    static let pdfSaveDocument = Notification.Name("PDFSaveDocument")
}

struct PDFViewer: View {
    let fileURL: URL?
    let onAskLLM: (String) -> Void

    @State private var document: PDFDocument? = nil
    @State private var loadErrorMessage: String? = nil

    var body: some View {
        ZStack {
            if let document = document {
                PDFKitContainer(document: document, onAskLLM: onAskLLM)
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

    func makeNSView(context: Context) -> PDFKitView {
        let pdfView = PDFKitView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = document
        pdfView.onAskLLM = onAskLLM
        return pdfView
    }

    func updateNSView(_ pdfView: PDFKitView, context: Context) {
        pdfView.document = document
        pdfView.onAskLLM = onAskLLM
    }
}

final class PDFKitView: PDFView {
    var onAskLLM: ((String) -> Void)?
    private var lastSelectionText: String = ""
    private var contextMenuAnnotation: PDFAnnotation?
    private var contextMenuPage: PDFPage?
    private var contextMenuPointOnPage: CGPoint?
    private var annotationObserver: NSObjectProtocol?
    private var saveObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerAnnotationObserver()
        registerSaveObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerAnnotationObserver()
        registerSaveObserver()
    }

    deinit {
        if let annotationObserver {
            NotificationCenter.default.removeObserver(annotationObserver)
        }
        if let saveObserver {
            NotificationCenter.default.removeObserver(saveObserver)
        }
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

        retargetRemoveAnnotationItems(in: menu)
        return menu
    }

    private func retargetRemoveAnnotationItems(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu {
                retargetRemoveAnnotationItems(in: submenu)
            }

            let lowerTitle = item.title.lowercased()
            let isRemoveAnnotationAction = lowerTitle == "remove annotation"
                || lowerTitle == "remove highlight"
                || lowerTitle == "remove underline"
                || lowerTitle == "remove strikethrough"
            guard isRemoveAnnotationAction else { continue }

            item.action = #selector(handleRemoveAnnotation)
            item.target = self
        }
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

    private func registerAnnotationObserver() {
        annotationObserver = NotificationCenter.default.addObserver(
            forName: .pdfApplyAnnotation,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let action = note.object as? PDFAnnotationAction else { return }
            self?.applyAnnotation(action)
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

    private func applyAnnotation(_ action: PDFAnnotationAction) {
        guard let selection = currentSelection else {
            NSSound.beep()
            return
        }

        let lineSelections = selection.selectionsByLine()
        if lineSelections.isEmpty {
            NSSound.beep()
            return
        }

        for lineSelection in lineSelections {
            guard let page = lineSelection.pages.first else { continue }
            let bounds = lineSelection.bounds(for: page)
            if bounds.isNull || bounds.isInfinite || bounds.isEmpty {
                continue
            }
            let annotation = makeAnnotation(for: action, bounds: bounds)
            page.addAnnotation(annotation)
        }
    }

    private func makeAnnotation(for action: PDFAnnotationAction, bounds: CGRect) -> PDFAnnotation {
        let annotationType: PDFAnnotationSubtype
        let color: NSColor

        switch action {
        case .highlightYellow:
            annotationType = .highlight
            color = NSColor.systemYellow.withAlphaComponent(0.35)
        case .highlightGreen:
            annotationType = .highlight
            color = NSColor.systemGreen.withAlphaComponent(0.35)
        case .highlightBlue:
            annotationType = .highlight
            color = NSColor.systemBlue.withAlphaComponent(0.35)
        case .highlightPink:
            annotationType = .highlight
            color = NSColor.systemPink.withAlphaComponent(0.35)
        case .highlightPurple:
            annotationType = .highlight
            color = NSColor.systemPurple.withAlphaComponent(0.35)
        case .underline:
            annotationType = .underline
            color = NSColor.systemYellow
        case .strikeOut:
            annotationType = .strikeOut
            color = NSColor.systemRed
        }

        let annotation = PDFAnnotation(bounds: bounds, forType: annotationType, withProperties: nil)
        annotation.color = color
        return annotation
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
        guard !removable.isEmpty else { return [] }

        var result: [PDFAnnotation] = []
        var visited = Set<ObjectIdentifier>()
        var queue = seeds.filter(isRemovableMarkup)
        if queue.isEmpty { return [] }

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let currentID = ObjectIdentifier(current)
            guard visited.insert(currentID).inserted else { continue }
            result.append(current)

            for candidate in removable {
                let candidateID = ObjectIdentifier(candidate)
                if visited.contains(candidateID) {
                    continue
                }
                if isSameMarkupGroup(candidate, as: current)
                    && areAnnotationsConnected(current, candidate) {
                    queue.append(candidate)
                }
            }
        }

        return result
    }

    private func isRemovableMarkup(_ annotation: PDFAnnotation) -> Bool {
        let typeName = (annotation.type ?? "").lowercased()
        return typeName.contains("highlight")
            || typeName.contains("underline")
            || typeName.contains("strike")
    }

    private func isSameMarkupGroup(_ lhs: PDFAnnotation, as rhs: PDFAnnotation) -> Bool {
        let lhsType = (lhs.type ?? "").lowercased()
        let rhsType = (rhs.type ?? "").lowercased()
        guard lhsType == rhsType else { return false }
        return colorsAreClose(lhs.color, rhs.color)
    }

    private func areAnnotationsConnected(_ lhs: PDFAnnotation, _ rhs: PDFAnnotation) -> Bool {
        let lhsBounds = lhs.bounds
        let rhsBounds = rhs.bounds
        let expandedLHS = lhsBounds.insetBy(dx: -2.0, dy: -6.0)
        if expandedLHS.intersects(rhsBounds) {
            return true
        }

        let overlapWidth = max(
            0.0,
            min(lhsBounds.maxX, rhsBounds.maxX) - max(lhsBounds.minX, rhsBounds.minX)
        )
        let minWidth = max(1.0, min(lhsBounds.width, rhsBounds.width))
        let horizontalOverlapRatio = overlapWidth / minWidth
        let verticalGap = max(
            0.0,
            max(lhsBounds.minY - rhsBounds.maxY, rhsBounds.minY - lhsBounds.maxY)
        )

        return horizontalOverlapRatio > 0.5 && verticalGap <= 10.0
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
