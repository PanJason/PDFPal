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
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    NotificationCenter.default.post(name: .pdfSaveDocument, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
            TextEditingCommands()
        }
    }
}

struct AppShellView: View {
    @State private var isPickingFile = false
    @State private var fileURL: URL? = nil
    @State private var isChatVisible = false
    @State private var isSessionSidebarVisible = true
    @State private var selectionText = ""
    @State private var openErrorMessage = ""
    @State private var isShowingOpenError = false
    @State private var selectedProvider: LLMProvider = .openAI
    @State private var selectedAnnotationAction: PDFAnnotationAction = .highlightYellow
    @StateObject private var openAISessionStore = SessionStore(provider: .openAI)
    @StateObject private var claudeSessionStore = SessionStore(provider: .claude)
    @StateObject private var geminiSessionStore = SessionStore(provider: .gemini)

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
                Menu {
                    Toggle(isOn: annotationSelectionBinding(.highlightYellow)) {
                        HStack {
                            annotationColorIcon(.systemYellow)
                            Text("Yellow")
                        }
                    }
                    Toggle(isOn: annotationSelectionBinding(.highlightGreen)) {
                        HStack {
                            annotationColorIcon(.systemGreen)
                            Text("Green")
                        }
                    }
                    Toggle(isOn: annotationSelectionBinding(.highlightBlue)) {
                        HStack {
                            annotationColorIcon(.systemBlue)
                            Text("Blue")
                        }
                    }
                    Toggle(isOn: annotationSelectionBinding(.highlightPink)) {
                        HStack {
                            annotationColorIcon(.systemPink)
                            Text("Pink")
                        }
                    }
                    Toggle(isOn: annotationSelectionBinding(.highlightPurple)) {
                        HStack {
                            annotationColorIcon(.systemPurple)
                            Text("Purple")
                        }
                    }
                    Divider()
                    Toggle(isOn: annotationSelectionBinding(.underline)) {
                        HStack {
                            Image(systemName: "underline")
                                .foregroundColor(.primary)
                            Text("Underline")
                        }
                    }
                    Toggle(isOn: annotationSelectionBinding(.strikeOut)) {
                        HStack {
                            Image(systemName: "strikethrough")
                                .foregroundColor(.primary)
                            Text("Strikethrough")
                        }
                    }
                } label: {
                    Image(systemName: "highlighter")
                }
                Menu {
                    Toggle("Chat Panel", isOn: $isChatVisible)
                    Toggle("Sessions Sidebar", isOn: $isSessionSidebarVisible)
                        .disabled(!isChatVisible)
                } label: {
                    Image(systemName: "sidebar.squares.left")
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .onReceive(openAISessionStore.$activeSessionId) { _ in
            syncFileURLForActiveSession(in: openAISessionStore)
        }
        .onReceive(claudeSessionStore.$activeSessionId) { _ in
            syncFileURLForActiveSession(in: claudeSessionStore)
        }
        .onReceive(geminiSessionStore.$activeSessionId) { _ in
            syncFileURLForActiveSession(in: geminiSessionStore)
        }
        .onChange(of: selectedProvider) { _ in
            syncFileURLForActiveSession(in: activeSessionStore)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            openAISessionStore.persistNow()
            claudeSessionStore.persistNow()
            geminiSessionStore.persistNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            openAISessionStore.persistNow()
            claudeSessionStore.persistNow()
            geminiSessionStore.persistNow()
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
        case .gemini:
            return geminiSessionStore
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
        case .gemini:
            let config = GeminiClientConfiguration.load()
            return CompositeAPIKeyProvider(providers: [
                KeychainAPIKeyProvider(service: config.keychainService, account: config.keychainAccount),
                EnvironmentAPIKeyProvider(environmentKey: provider.environmentKey)
            ])
        }
    }

    private func applyPDFAnnotation(_ action: PDFAnnotationAction) {
        NotificationCenter.default.post(name: .pdfApplyAnnotation, object: action)
    }

    private func applyAndSelectPDFAnnotation(_ action: PDFAnnotationAction) {
        selectedAnnotationAction = action
        applyPDFAnnotation(action)
    }

    private func annotationSelectionBinding(_ action: PDFAnnotationAction) -> Binding<Bool> {
        Binding(
            get: { selectedAnnotationAction == action },
            set: { _ in
                applyAndSelectPDFAnnotation(action)
            }
        )
    }

    private func annotationColorIcon(_ color: NSColor) -> Image {
        Image(nsImage: colorCircleImage(color))
            .renderingMode(.original)
    }

    private func colorCircleImage(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 11, height: 11)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        color.setFill()
        let circle = NSBezierPath(ovalIn: rect)
        circle.fill()

        NSColor.black.withAlphaComponent(0.25).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
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
                isSessionSidebarVisible: $isSessionSidebarVisible,
                onClose: { isChatVisible = false }
            )
        case .claude:
            ClaudeLLMChatServing(
                documentId: documentId,
                selectionText: selectionText,
                openPDFPath: fileURL?.path,
                sessionStore: claudeSessionStore,
                isSessionSidebarVisible: $isSessionSidebarVisible,
                onClose: { isChatVisible = false }
            )
        case .gemini:
            GeminiLLMChatServing(
                documentId: documentId,
                selectionText: selectionText,
                openPDFPath: fileURL?.path,
                sessionStore: geminiSessionStore,
                isSessionSidebarVisible: $isSessionSidebarVisible,
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
    let isSessionSidebarVisible: Binding<Bool>
    let onClose: () -> Void

    var body: some View {
        ChatPanel(
            documentId: documentId,
            selectionText: selectionText,
            openPDFPath: openPDFPath,
            sessionStore: sessionStore,
            isSessionSidebarVisible: isSessionSidebarVisible,
            onClose: onClose
        )
    }
}

struct ClaudeLLMChatServing: View {
    let documentId: String
    let selectionText: String
    let openPDFPath: String?
    let sessionStore: SessionStore
    let isSessionSidebarVisible: Binding<Bool>
    let onClose: () -> Void

    var body: some View {
        ChatPanel(
            documentId: documentId,
            selectionText: selectionText,
            openPDFPath: openPDFPath,
            sessionStore: sessionStore,
            isSessionSidebarVisible: isSessionSidebarVisible,
            onClose: onClose
        )
    }
}

struct GeminiLLMChatServing: View {
    let documentId: String
    let selectionText: String
    let openPDFPath: String?
    let sessionStore: SessionStore
    let isSessionSidebarVisible: Binding<Bool>
    let onClose: () -> Void

    var body: some View {
        ChatPanel(
            documentId: documentId,
            selectionText: selectionText,
            openPDFPath: openPDFPath,
            sessionStore: sessionStore,
            isSessionSidebarVisible: isSessionSidebarVisible,
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
