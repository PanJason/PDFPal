import AppKit
import PDFKit
import SwiftUI

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

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let selectionText = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lastSelectionText = selectionText

        menu.items.removeAll { $0.title == "Ask LLM" }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        if !menu.items.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }

        let askItem = NSMenuItem(title: "Ask LLM", action: #selector(handleAskLLM), keyEquivalent: "")
        askItem.target = self
        askItem.isEnabled = !selectionText.isEmpty
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
