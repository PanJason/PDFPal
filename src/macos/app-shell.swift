import SwiftUI
import UniformTypeIdentifiers

@main
struct LLMPaperReadingHelperApp: App {
    var body: some Scene {
        WindowGroup {
            AppShellView()
        }
    }
}

struct AppShellView: View {
    @State private var isPickingFile = false
    @State private var fileURL: URL? = nil
    @State private var isChatVisible = false
    @State private var selectionText = ""
    @State private var openErrorMessage = ""
    @State private var isShowingOpenError = false

    var body: some View {
        HSplitView {
            PDFViewer(fileURL: fileURL, onAskLLM: handleAskLLM)
            .frame(minWidth: 360)

            if isChatVisible {
                ChatPanelPlaceholder(
                    selectionText: selectionText,
                    onClose: { isChatVisible = false }
                )
                .frame(minWidth: 320)
            } else {
                EmptyChatPlaceholder()
                    .frame(minWidth: 320)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open PDF") {
                    isPickingFile = true
                }
                Toggle("Show Chat", isOn: $isChatVisible)
            }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .alert("Could not open PDF", isPresented: $isShowingOpenError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openErrorMessage)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            fileURL = urls.first
        case .failure(let error):
            openErrorMessage = error.localizedDescription
            isShowingOpenError = true
        }
    }

    private func handleAskLLM(_ text: String) {
        selectionText = text
        isChatVisible = true
    }
}

struct ChatPanelPlaceholder: View {
    let selectionText: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Chat Panel")
                    .font(.title2)
                Spacer()
                Button("Close") {
                    onClose()
                }
            }

            Text("Selection context:")
                .font(.headline)

            ScrollView {
                Text(selectionText.isEmpty ? "No selection provided." : selectionText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
            }

            Text("Chat UI will be implemented in chat-panel.swift.")
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(20)
    }
}

struct EmptyChatPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Chat Panel")
                .font(.title2)
            Text("Use Ask LLM to open the chat panel.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
