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

        let annotateItem = NSMenuItem(title: "Annotate Selection", action: nil, keyEquivalent: "")
        annotateItem.tag = 9100
        annotateItem.submenu = makeAnnotateMenu()
        annotateItem.isEnabled = !selectionText.isEmpty
        menu.addItem(annotateItem)

        if contextMenuAnnotation != nil {
            let noteTitle = hasAnnotationNote() ? "Edit Note..." : "Add Note..."
            let noteItem = NSMenuItem(title: noteTitle, action: #selector(handleEditAnnotationNote), keyEquivalent: "")
            noteItem.target = self
            noteItem.tag = 9100
            menu.addItem(noteItem)
        }

        let askItem = NSMenuItem(title: "Ask LLM", action: #selector(handleAskLLM), keyEquivalent: "")
        askItem.target = self
        askItem.isEnabled = !selectionText.isEmpty
        askItem.tag = 9100
        menu.addItem(askItem)

        return menu
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

    @objc private func applyYellowHighlight() {
        applyAnnotation(.highlightYellow)
    }

    @objc private func applyGreenHighlight() {
        applyAnnotation(.highlightGreen)
    }

    @objc private func applyBlueHighlight() {
        applyAnnotation(.highlightBlue)
    }

    @objc private func applyPinkHighlight() {
        applyAnnotation(.highlightPink)
    }

    @objc private func applyPurpleHighlight() {
        applyAnnotation(.highlightPurple)
    }

    @objc private func applyUnderline() {
        applyAnnotation(.underline)
    }

    @objc private func applyStrikeOut() {
        applyAnnotation(.strikeOut)
    }

    @objc private func handleEditAnnotationNote() {
        guard let annotation = contextMenuAnnotation else { return }

        let alert = NSAlert()
        alert.messageText = "Annotation Note"
        alert.informativeText = "Add or edit note text for this annotation."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isRichText = false
        textView.string = annotation.contents ?? ""
        scrollView.documentView = textView
        alert.accessoryView = scrollView

        if alert.runModal() == .alertFirstButtonReturn {
            let note = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            annotation.contents = note.isEmpty ? nil : note
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

    private func makeAnnotateMenu() -> NSMenu {
        let menu = NSMenu()

        let yellow = NSMenuItem(title: "Highlight Yellow", action: #selector(applyYellowHighlight), keyEquivalent: "")
        yellow.target = self
        yellow.tag = 9100
        menu.addItem(yellow)

        let green = NSMenuItem(title: "Highlight Green", action: #selector(applyGreenHighlight), keyEquivalent: "")
        green.target = self
        green.tag = 9100
        menu.addItem(green)

        let pink = NSMenuItem(title: "Highlight Pink", action: #selector(applyPinkHighlight), keyEquivalent: "")
        pink.target = self
        pink.tag = 9100
        menu.addItem(pink)

        menu.addItem(NSMenuItem.separator())

        let underline = NSMenuItem(title: "Underline", action: #selector(applyUnderline), keyEquivalent: "")
        underline.target = self
        underline.tag = 9100
        menu.addItem(underline)

        let strikeOut = NSMenuItem(title: "Strikethrough", action: #selector(applyStrikeOut), keyEquivalent: "")
        strikeOut.target = self
        strikeOut.tag = 9100
        menu.addItem(strikeOut)

        return menu
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
        guard let page = page(for: pointInView, nearest: true) else { return nil }
        let pointOnPage = convert(pointInView, to: page)
        return page.annotation(at: pointOnPage)
    }

    private func hasAnnotationNote() -> Bool {
        guard let text = contextMenuAnnotation?.contents else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
