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
            CommandGroup(after: .textEditing) {
                Button("Find in PDF") {
                    NotificationCenter.default.post(name: .pdfFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command])
            }
            TextEditingCommands()
        }
    }
}

struct AppShellView: View {
    @State private var isPickingFile = false
    @State private var fileURL: URL? = nil
    @State private var isChatVisible = false
    @State private var isAnnotationPreviewVisible = false
    @State private var isSessionSidebarVisible = true
    @State private var selectionText = ""
    @State private var annotationSelection: AnnotationRenderSelection?
    @State private var openErrorMessage = ""
    @State private var isShowingOpenError = false
    @State private var selectedProvider: LLMProvider = .openAI
    @State private var selectedAnnotationAction: PDFAnnotationAction = .highlightYellow
    @State private var isHighlighterModeEnabled = false
    @State private var selectedPDFSidebarMode: PDFSidebarMode = .thumbnails
    @State private var searchQuery = ""
    @State private var searchMode: PDFSearchMode = .exactPhrase
    @State private var keyEventMonitor: Any?
    @State private var searchFocusRequestID = 0
    @StateObject private var openAISessionStore = SessionStore(provider: .openAI)
    @StateObject private var claudeSessionStore = SessionStore(provider: .claude)
    @StateObject private var geminiSessionStore = SessionStore(provider: .gemini)
    private let renderPipeline = RenderPipeline()

    var body: some View {
        HSplitView {
            PDFViewer(
                fileURL: fileURL,
                onAskLLM: handleAskLLM,
                onAnnotationSelectionChanged: handleAnnotationSelectionChanged,
                searchQuery: searchQuery,
                searchMode: searchMode,
                sidebarMode: selectedPDFSidebarMode
            )
            .frame(minWidth: 360)

            if isChatVisible {
                activeChatPanel
                    .frame(minWidth: 320)
            } else {
                EmptyChatPlaceholder()
                    .frame(minWidth: 320)
            }

            if isAnnotationPreviewVisible {
                AnnotationPreviewPanel(
                    selection: annotationSelection,
                    pipeline: renderPipeline,
                    onClose: { isAnnotationPreviewVisible = false }
                )
                .frame(minWidth: 280)
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
                HStack(spacing: 0) {
                    Button(action: handleHighlighterPrimaryAction) {
                        Image(systemName: "highlighter")
                            .symbolVariant(isHighlighterModeEnabled ? .fill : .none)
                            .foregroundColor(isHighlighterModeEnabled ? .accentColor : .primary)
                    }
                    .help(isHighlighterModeEnabled ? "Highlighter mode enabled" : "Apply selected highlighter style")

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
                        Text("")
                    }
                }
                .padding(.horizontal, 4)
                .onAppear {
                    postSelectedAnnotationAction()
                }
                Menu {
                    Toggle("Chat Panel", isOn: $isChatVisible)
                    Toggle("Sessions Sidebar", isOn: $isSessionSidebarVisible)
                        .disabled(!isChatVisible)
                    Toggle("Annotation Preview", isOn: $isAnnotationPreviewVisible)
                    Divider()
                    pdfSidebarModeMenuItem(.hidden)
                    pdfSidebarModeMenuItem(.thumbnails)
                    pdfSidebarModeMenuItem(.tableOfContents)
                    pdfSidebarModeMenuItem(.highlightsAndNotes)
                    pdfSidebarModeMenuItem(.bookmarks)
                } label: {
                    Image(systemName: "sidebar.squares.left")
                }
                PDFSearchToolbarField(
                    query: $searchQuery,
                    mode: $searchMode,
                    focusRequestID: searchFocusRequestID
                )
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
        .onReceive(NotificationCenter.default.publisher(for: .pdfHighlighterModeChanged)) { notification in
            if let enabled = notification.object as? Bool {
                isHighlighterModeEnabled = enabled
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pdfFocusSearch)) { _ in
            requestSearchFocus()
        }
        .onAppear {
            installFindShortcutMonitorIfNeeded()
        }
        .onDisappear {
            removeFindShortcutMonitor()
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
        annotationSelection = nil
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
            annotationSelection = nil
            return
        }
        let nextURL = URL(fileURLWithPath: path)
        if fileURL?.path != nextURL.path {
            fileURL = nextURL
            selectionText = ""
            annotationSelection = nil
        }
    }

    private func handleAnnotationSelectionChanged(_ selection: AnnotationRenderSelection?) {
        annotationSelection = selection
        if selection != nil {
            isAnnotationPreviewVisible = true
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

    private func selectAnnotationAction(_ action: PDFAnnotationAction) {
        selectedAnnotationAction = action
        postSelectedAnnotationAction()
    }

    private func postSelectedAnnotationAction() {
        NotificationCenter.default.post(name: .pdfSetAnnotationAction, object: selectedAnnotationAction)
    }

    private func handleHighlighterPrimaryAction() {
        NotificationCenter.default.post(name: .pdfHighlighterPrimaryAction, object: selectedAnnotationAction)
    }

    private func annotationSelectionBinding(_ action: PDFAnnotationAction) -> Binding<Bool> {
        Binding(
            get: { selectedAnnotationAction == action },
            set: { _ in
                selectAnnotationAction(action)
            }
        )
    }

    @ViewBuilder
    private func pdfSidebarModeMenuItem(_ mode: PDFSidebarMode) -> some View {
        Button {
            selectedPDFSidebarMode = mode
        } label: {
            if selectedPDFSidebarMode == mode {
                Label(mode.title, systemImage: "checkmark")
            } else {
                Text(mode.title)
            }
        }
    }

    private func installFindShortcutMonitorIfNeeded() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isFindShortcut = modifiers.contains(.command)
                && !modifiers.contains(.control)
                && !modifiers.contains(.option)
                && event.charactersIgnoringModifiers?.lowercased() == "f"
            if isFindShortcut {
                requestSearchFocus()
                return nil
            }
            return event
        }
    }

    private func removeFindShortcutMonitor() {
        guard let keyEventMonitor else { return }
        NSEvent.removeMonitor(keyEventMonitor)
        self.keyEventMonitor = nil
    }

    private func requestSearchFocus() {
        searchFocusRequestID &+= 1
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

private struct PDFSearchToolbarField: View {
    @Binding var query: String
    @Binding var mode: PDFSearchMode
    let focusRequestID: Int

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(PDFSearchMode.allCases) { option in
                    Button {
                        mode = option
                    } label: {
                        if mode == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "magnifyingglass")
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            PDFSearchTextField(
                text: $query,
                focusRequestID: focusRequestID
            )
            .frame(minWidth: 160)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    Color.secondary.opacity(0.35),
                    lineWidth: 1
                )
        )
        .frame(width: 260)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PDF Search")
    }
}

private struct PDFSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let focusRequestID: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(frame: .zero)
        field.placeholderString = "Search"
        field.bezelStyle = .roundedBezel
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchTextChanged(_:))
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
                if let editor = nsView.currentEditor() {
                    editor.selectedRange = NSRange(location: 0, length: nsView.stringValue.count)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PDFSearchTextField
        var lastFocusRequestID: Int = -1

        init(_ parent: PDFSearchTextField) {
            self.parent = parent
        }

        @objc func searchTextChanged(_ sender: NSSearchField) {
            parent.text = sender.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let isEnter =
                commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertLineBreak(_:))
            guard isEnter else { return false }

            let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if modifiers.contains(.shift) {
                NotificationCenter.default.post(name: .pdfSearchPrevious, object: nil)
            } else {
                NotificationCenter.default.post(name: .pdfSearchNext, object: nil)
            }
            return true
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
