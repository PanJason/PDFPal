import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct LLMPaperReadingHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppShellView()
        }
        .commands {
            TextEditingCommands()
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
    @State private var selectedProvider: LLMProvider = .openAI

    var body: some View {
        HSplitView {
            PDFViewer(fileURL: fileURL, onAskLLM: handleAskLLM)
            .frame(minWidth: 360)

            if isChatVisible {
                activeChatPanel
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
                Picker("Model Family", selection: $selectedProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
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

    private var documentId: String {
        fileURL?.lastPathComponent ?? "document"
    }

    @ViewBuilder
    private var activeChatPanel: some View {
        switch selectedProvider {
        case .openAI:
            OpenAILLMChatServing(
                documentId: documentId,
                selectionText: selectionText,
                onClose: { isChatVisible = false }
            )
        case .claude:
            ClaudeLLMChatServing(
                documentId: documentId,
                selectionText: selectionText,
                onClose: { isChatVisible = false }
            )
        }
    }
}

struct OpenAILLMChatServing: View {
    let documentId: String
    let selectionText: String
    let onClose: () -> Void

    var body: some View {
        ChatPanel(
            documentId: documentId,
            selectionText: selectionText,
            provider: .openAI,
            onClose: onClose
        )
    }
}

struct ClaudeLLMChatServing: View {
    let documentId: String
    let selectionText: String
    let onClose: () -> Void

    var body: some View {
        ChatPanel(
            documentId: documentId,
            selectionText: selectionText,
            provider: .claude,
            onClose: onClose
        )
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
