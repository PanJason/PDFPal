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
    static let pdfSetAnnotationAction = Notification.Name("PDFSetAnnotationAction")
    static let pdfHighlighterPrimaryAction = Notification.Name("PDFHighlighterPrimaryAction")
    static let pdfHighlighterModeChanged = Notification.Name("PDFHighlighterModeChanged")
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
    private var highlighterPrimaryObserver: NSObjectProtocol?
    private var selectionChangedObserver: NSObjectProtocol?
    private var saveObserver: NSObjectProtocol?
    private var pendingModeApplyWorkItem: DispatchWorkItem?
    private var currentAnnotationAction: PDFAnnotationAction = .highlightYellow
    private var isHighlighterModeEnabled = false
    private var isApplyingFromMode = false
    private var lastModeSelectionFingerprint: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerAnnotationObserver()
        registerSelectionObserver()
        registerSaveObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerAnnotationObserver()
        registerSelectionObserver()
        registerSaveObserver()
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
    }

    override func setCurrentSelection(_ selection: PDFSelection?, animate: Bool) {
        super.setCurrentSelection(selection, animate: animate)
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

        let itemSummaries = menu.items.enumerated().map { (index, item) in
            contextMenuDebugSummary(for: item, index: index)
        }
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
            for bounds in anchorBounds {
                if hasEquivalentAnnotation(on: page, action: action, bounds: bounds) {
                    continue
                }
                let annotation = makeAnnotation(for: action, bounds: bounds)
                page.addAnnotation(annotation)
            }
            return
        }

        for annotation in highlights {
            annotation.color = newColor
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

        for bounds in anchorBounds {
            let overlays = matchingMarkupAnnotations(on: page, subtype: subtype, around: bounds)
            if !overlays.isEmpty {
                continue
            }
            let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
            annotation.color = preferredOverlayColor(on: page, bounds: bounds)
            page.addAnnotation(annotation)
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
        let highlights = matchingMarkupAnnotations(on: page, subtype: .highlight, around: bounds)
        if let color = highlights.first?.color {
            return color
        }
        switch currentAnnotationAction {
        case .highlightYellow, .highlightGreen, .highlightBlue, .highlightPink, .highlightPurple:
            return annotationStyle(for: currentAnnotationAction).color
        case .underline, .strikeOut:
            return annotationStyle(for: .highlightYellow).color
        }
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
            page.addAnnotation(annotation)
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
            return (.highlight, NSColor.systemYellow.withAlphaComponent(0.35))
        case .highlightGreen:
            return (.highlight, NSColor.systemGreen.withAlphaComponent(0.35))
        case .highlightBlue:
            return (.highlight, NSColor.systemBlue.withAlphaComponent(0.35))
        case .highlightPink:
            return (.highlight, NSColor.systemPink.withAlphaComponent(0.35))
        case .highlightPurple:
            return (.highlight, NSColor.systemPurple.withAlphaComponent(0.35))
        case .underline:
            return (.underline, NSColor.systemYellow)
        case .strikeOut:
            return (.strikeOut, NSColor.systemRed)
        }
    }

    private func hasEquivalentAnnotation(on page: PDFPage, action: PDFAnnotationAction, bounds: CGRect) -> Bool {
        let expected = annotationStyle(for: action)
        return page.annotations.contains { annotation in
            guard annotationTypeMatches(annotation, subtype: expected.type) else { return false }
            guard boundsAreClose(annotation.bounds, bounds) else { return false }
            return colorsAreClose(annotation.color, expected.color)
        }
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
