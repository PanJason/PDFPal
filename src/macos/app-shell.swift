import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        applyAppIcon()
    }

    private func applyAppIcon() {
        if let image = loadAppIconImage() {
            NSApp.applicationIconImage = image
        }
    }

    private func loadAppIconImage() -> NSImage? {
        if let bundleURL = Bundle.main.url(forResource: "app_icon", withExtension: "png") {
            return NSImage(contentsOf: bundleURL)
        }

        let currentDirectory = FileManager.default.currentDirectoryPath
        let fallbackURL = URL(fileURLWithPath: "resource/app_icon.png", relativeTo: URL(fileURLWithPath: currentDirectory))
        return NSImage(contentsOf: fallbackURL)
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
    @StateObject private var openAISessionStore = SessionStore(provider: .openAI)
    @StateObject private var claudeSessionStore = SessionStore(provider: .claude)

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
        .onChange(of: openAISessionStore.activeSessionId) { _ in
            syncFileURLForActiveSession(in: openAISessionStore)
        }
        .onChange(of: claudeSessionStore.activeSessionId) { _ in
            syncFileURLForActiveSession(in: claudeSessionStore)
        }
        .onChange(of: selectedProvider) { _ in
            syncFileURLForActiveSession(in: activeSessionStore)
        }
        .alert("Could not open PDF", isPresented: $isShowingOpenError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openErrorMessage)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            handleOpenFile(url)
        case .failure(let error):
            openErrorMessage = error.localizedDescription
            isShowingOpenError = true
        }
    }

    private func handleAskLLM(_ text: String) {
        guard let path = fileURL?.path else { return }
        if let activeSession = activeSessionStore.activeSession,
           activeSession.openPDFPath == path {
            selectionText = text
            activeSessionStore.updateActiveSessionContext(text)
            isChatVisible = true
            return
        }

        guard activeSessionStore.activeSession == nil else { return }
        guard hasAPIKey(for: selectedProvider) else { return }

        selectionText = text
        let session = activeSessionStore.createSession(
            contextText: text,
            model: LLMModel.defaultModel(for: selectedProvider),
            openPDFPath: path,
            activate: true
        )
        activeSessionStore.selectSession(session.id)
        isChatVisible = true
    }

    private var documentId: String {
        fileURL?.lastPathComponent ?? "document"
    }

    private var activeSessionStore: SessionStore {
        switch selectedProvider {
        case .openAI:
            return openAISessionStore
        case .claude:
            return claudeSessionStore
        }
    }

    private func handleOpenFile(_ url: URL) {
        fileURL = url
        selectionText = ""
        let path = url.path
        if let existingSession = activeSessionStore.latestSession(matchingPDFPath: path) {
            activeSessionStore.selectSession(existingSession.id)
            activeSessionStore.updateActiveSessionOpenPDFPath(path)
            isChatVisible = true
            return
        }

        if hasAPIKey(for: selectedProvider) {
            let session = activeSessionStore.createSession(
                contextText: "",
                model: LLMModel.defaultModel(for: selectedProvider),
                openPDFPath: path,
                activate: true
            )
            activeSessionStore.selectSession(session.id)
            isChatVisible = true
        } else {
            isChatVisible = false
        }
    }

    private func syncFileURLForActiveSession(in store: SessionStore) {
        guard store.provider == selectedProvider else { return }
        guard let path = store.activeSession?.openPDFPath else {
            fileURL = nil
            selectionText = ""
            return
        }
        let nextURL = URL(fileURLWithPath: path)
        if fileURL?.path != nextURL.path {
            fileURL = nextURL
            selectionText = ""
        }
    }

    private func hasAPIKey(for provider: LLMProvider) -> Bool {
        do {
            _ = try keyProvider(for: provider).loadAPIKey()
            return true
        } catch {
            return false
        }
    }

    private func keyProvider(for provider: LLMProvider) -> any APIKeyProvider {
        switch provider {
        case .openAI:
            let config = OpenAIClientConfiguration.load()
            return CompositeAPIKeyProvider(providers: [
                KeychainAPIKeyProvider(service: config.keychainService, account: config.keychainAccount),
                EnvironmentAPIKeyProvider(environmentKey: provider.environmentKey)
            ])
        case .claude:
            let config = ClaudeClientConfiguration.load()
            return CompositeAPIKeyProvider(providers: [
                KeychainAPIKeyProvider(service: config.keychainService, account: config.keychainAccount),
                EnvironmentAPIKeyProvider(environmentKey: provider.environmentKey)
            ])
        }
    }

    @ViewBuilder
    private var activeChatPanel: some View {
        switch selectedProvider {
        case .openAI:
            OpenAILLMChatServing(
                documentId: documentId,
                selectionText: selectionText,
                openPDFPath: fileURL?.path,
                sessionStore: openAISessionStore,
                onClose: { isChatVisible = false }
            )
        case .claude:
            ClaudeLLMChatServing(
                documentId: documentId,
                selectionText: selectionText,
                openPDFPath: fileURL?.path,
                sessionStore: claudeSessionStore,
                onClose: { isChatVisible = false }
            )
        }
    }
}

struct OpenAILLMChatServing: View {
    let documentId: String
    let selectionText: String
    let openPDFPath: String?
    let sessionStore: SessionStore
    let onClose: () -> Void

    var body: some View {
        ChatPanel(
            documentId: documentId,
            selectionText: selectionText,
            openPDFPath: openPDFPath,
            sessionStore: sessionStore,
            onClose: onClose
        )
    }
}

struct ClaudeLLMChatServing: View {
    let documentId: String
    let selectionText: String
    let openPDFPath: String?
    let sessionStore: SessionStore
    let onClose: () -> Void

    var body: some View {
        ChatPanel(
            documentId: documentId,
            selectionText: selectionText,
            openPDFPath: openPDFPath,
            sessionStore: sessionStore,
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
