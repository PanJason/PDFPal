import AppKit
import SwiftUI

struct ChatPanel: View {
    let documentId: String
    let selectionText: String
    let openPDFPath: String?
    let onClose: () -> Void
    @ObservedObject var sessionStore: SessionStore

    @State private var inputText = ""
    @State private var isSending = false
    @State private var errorMessage: String? = nil
    @State private var retryPrompt: String? = nil
    @State private var selectedModel: LLMModel
    @State private var customModelId = ""
    @State private var isAPIKeyAvailable = false
    @State private var isShowingKeyPrompt = false
    @State private var keyPromptModel: LLMModel
    @State private var streamTask: Task<Void, Never>? = nil
    @State private var activeStreamId: UUID? = nil
    @State private var hasReceivedDelta = false
    @State private var isSessionSidebarVisible = true
    @State private var isHoveringFoldHandle = false

    init(
        documentId: String,
        selectionText: String,
        openPDFPath: String?,
        sessionStore: SessionStore,
        onClose: @escaping () -> Void
    ) {
        self.documentId = documentId
        self.selectionText = selectionText
        self.openPDFPath = openPDFPath
        self.sessionStore = sessionStore
        self.onClose = onClose
        let session = sessionStore.activeSession
        _selectedModel = State(initialValue: session?.selectedModel ?? LLMModel.defaultModel(for: sessionStore.provider))
        _customModelId = State(initialValue: session?.customModelId ?? "")
        _keyPromptModel = State(initialValue: session?.selectedModel ?? LLMModel.defaultModel(for: sessionStore.provider))
    }

    private var provider: LLMProvider {
        sessionStore.provider
    }

    private var activeMessages: [ChatMessage] {
        sessionStore.activeSession?.messages ?? []
    }

    private var activeMessagesCount: Int {
        sessionStore.activeSession?.messages.count ?? 0
    }

    private var activeContext: String {
        sessionStore.activeSession?.contextText ?? selectionText
    }

    var body: some View {
        HStack(spacing: 0) {
            chatContent
            if isSessionSidebarVisible {
                Divider()
                sessionSidebar
            }
        }
        .onAppear {
            syncContextWithSelection()
            loadSessionState()
        }
        .onChange(of: selectionText) { newText in
            syncContextWithSelection(using: newText)
        }
        .onChange(of: sessionStore.activeSessionId) { _ in
            loadSessionState()
        }
        .onChange(of: selectedModel) { newValue in
            sessionStore.updateActiveSessionModel(newValue)
            if !newValue.isCustom {
                customModelId = ""
            }
            updateKeyAvailability(for: newValue)
            promptForKeyIfNeeded(for: newValue)
        }
        .onChange(of: customModelId) { newValue in
            sessionStore.updateActiveSessionCustomModelId(newValue)
        }
        .sheet(isPresented: $isShowingKeyPrompt) {
            APIKeyPrompt(
                providerName: keyPromptModel.provider.displayName,
                apiKeyName: keyPromptModel.provider.apiKeyName,
                onSave: saveAPIKey,
                onCancel: { isShowingKeyPrompt = false }
            )
        }
        .onDisappear {
            cancelStream()
        }
    }

    private var chatContent: some View {
        VStack(spacing: 16) {
            header
            modelSelector
            contextCard
            Divider()
            messageList
            errorBanner
            inputBar
        }
        .padding(20)
        .overlay(alignment: .topTrailing) {
            foldHandle
                .padding(.top, 6)
                .padding(.trailing, 6)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chat")
                    .font(.title2)
            }
            Spacer()
            Button("Close") {
                onClose()
            }
        }
    }

    private var modelSelector: some View {
        GroupBox(label: Label("Model", systemImage: "cpu")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Family: \(provider.displayName)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                HStack {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(LLMModel.models(for: provider)) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Button("Set API Key") {
                        presentKeyPrompt(for: selectedModel)
                    }
                }

                if selectedModel.isCustom {
                    TextField("Enter custom model id", text: $customModelId)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 8) {
                    Text("API Key:")
                        .foregroundColor(.secondary)
                    Text(isAPIKeyAvailable ? "Stored" : "Missing")
                        .foregroundColor(isAPIKeyAvailable ? .green : .red)
                    Text(selectedModel.provider.apiKeyName)
                        .foregroundColor(.secondary)
                }
                .font(.footnote)
            }
            .padding(.vertical, 4)
        }
    }

    private var contextCard: some View {
        GroupBox(label: Label("Context", systemImage: "doc.text.magnifyingglass")) {
            ScrollView {
                Text(contextText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .frame(maxHeight: 140)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if activeMessages.isEmpty && !isSending {
                        Text("Ask a question about the selection to start the conversation.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    ForEach(activeMessages) { message in
                        ChatMessageRow(message: message)
                    }
                    if isSending && !hasReceivedDelta {
                        ChatLoadingRow()
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(ChatScrollAnchor.bottom)
                }
                .padding(.vertical, 8)
            }
            .onChange(of: activeMessagesCount) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: isSending) { _ in
                scrollToBottom(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorBanner: some View {
        Group {
            if let errorMessage {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if retryPrompt != nil && !isSending {
                        Button("Retry") {
                            retrySend()
                        }
                    }
                    Button("Dismiss") {
                        self.errorMessage = nil
                    }
                }
                .padding(10)
                .background(Color.red.opacity(0.12))
                .cornerRadius(8)
            }
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Ask a question or add more context...")
                        .foregroundColor(.secondary)
                        .padding(8)
                }
                TextEditor(text: $inputText)
                    .frame(minHeight: 72, maxHeight: 100)
                    .padding(4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3))
            )

            HStack {
                Text("Cmd-Return to send")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Send") {
                    sendMessage()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isSendDisabled)
            }
        }
    }

    private var sessionSidebar: some View {
        SessionSidebar(
            sessions: sessionStore.sessions,
            activeSessionId: sessionStore.activeSessionId,
            onSelect: { sessionId in
                sessionStore.selectSession(sessionId)
            },
            onNewSession: createNewSession,
            onDeleteSession: deleteSession,
            onRenameSession: renameSession,
            canCreateSession: isAPIKeyAvailable
        )
        .frame(width: 220)
    }

    private var foldHandle: some View {
        let iconName = isSessionSidebarVisible ? "sidebar.right" : "sidebar.left"
        return ZStack {
            Rectangle()
                .fill(Color.clear)
            Button {
                isSessionSidebarVisible.toggle()
            } label: {
                Image(systemName: iconName)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .opacity(isHoveringFoldHandle ? 1 : 0)
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringFoldHandle = hovering
        }
        .accessibilityLabel(isSessionSidebarVisible ? "Hide sessions" : "Show sessions")
    }

    private var isSendDisabled: Bool {
        if isSending { return true }
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if selectedModel.isCustom && resolvedModelId() == nil { return true }
        return false
    }

    private var contextText: String {
        activeContext.isEmpty
            ? "Select text in the PDF and choose Ask LLM to seed the conversation."
            : activeContext
    }

    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a message before sending."
            retryPrompt = nil
            return
        }

        guard validateModelSelection() else { return }
        inputText = ""
        startStreaming(prompt: trimmed, appendUserMessage: true)
    }

    private func retrySend() {
        guard let retryPrompt else { return }
        guard validateModelSelection() else { return }
        errorMessage = nil
        removeTrailingAssistantMessage()
        startStreaming(prompt: retryPrompt, appendUserMessage: false)
    }

    private func validateModelSelection() -> Bool {
        guard let modelId = resolvedModelId(), !modelId.isEmpty else {
            errorMessage = "Enter a model id before sending."
            return false
        }

        guard ensureAPIKeyAvailable(for: selectedModel) else { return false }
        return true
    }

    private func startStreaming(prompt: String, appendUserMessage: Bool) {
        guard let modelId = resolvedModelId(), !modelId.isEmpty else { return }
        cancelStream()
        errorMessage = nil
        isSending = true
        retryPrompt = prompt
        hasReceivedDelta = false

        if appendUserMessage {
            sessionStore.appendMessage(ChatMessage(role: .user, text: prompt))
        }

        let streamId = UUID()
        activeStreamId = streamId
        let assistantId = UUID()

        let request = LLMRequest(
            documentId: documentId,
            selectionText: activeContext,
            userPrompt: prompt,
            context: nil
        )
        let client = makeClient(for: selectedModel, modelId: modelId)

        streamTask = Task {
            do {
                for try await event in client.stream(request: request) {
                    try Task.checkCancellation()
                    await MainActor.run {
                        guard activeStreamId == streamId else { return }
                        handleStreamEvent(event, assistantId: assistantId)
                    }
                }
            } catch {
                if error is CancellationError { return }
                await MainActor.run {
                    handleStreamError(error, streamId: streamId)
                }
            }
        }
    }

    private func handleStreamEvent(_ event: LLMStreamEvent, assistantId: UUID) {
        switch event {
        case .textDelta(let delta):
            appendAssistantDelta(delta, assistantId: assistantId)
        case .completed(let response):
            finalizeAssistantMessage(response.replyText, assistantId: assistantId)
            isSending = false
            activeStreamId = nil
        }
    }

    private func appendAssistantDelta(_ delta: String, assistantId: UUID) {
        if !hasReceivedDelta {
            sessionStore.appendMessage(ChatMessage(id: assistantId, role: .assistant, text: delta))
            hasReceivedDelta = true
        } else {
            sessionStore.updateAssistantMessage(id: assistantId) { message in
                message.text += delta
            }
        }
    }

    private func finalizeAssistantMessage(_ text: String, assistantId: UUID) {
        if !hasReceivedDelta {
            sessionStore.appendMessage(ChatMessage(id: assistantId, role: .assistant, text: text))
            hasReceivedDelta = true
        } else {
            sessionStore.updateAssistantMessage(id: assistantId) { message in
                message.text = text
            }
        }
    }

    private func handleStreamError(_ error: Error, streamId: UUID) {
        guard activeStreamId == streamId else { return }
        isSending = false
        activeStreamId = nil
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
    }

    private func resolvedModelId() -> String? {
        if selectedModel.isCustom {
            let trimmed = customModelId.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return selectedModel.id
    }

    private func createNewSession() {
        guard isAPIKeyAvailable else { return }
        cancelStream()
        let context = selectionText.isEmpty ? activeContext : selectionText
        sessionStore.createSession(
            contextText: context,
            model: selectedModel,
            customModelId: customModelId,
            openPDFPath: openPDFPath,
            activate: true
        )
    }

    private func makeClient(for model: LLMModel, modelId: String) -> any LLMClient {
        switch model.provider {
        case .openAI:
            let base = OpenAIClientConfiguration.load()
            let config = OpenAIClientConfiguration(
                endpoint: base.endpoint,
                model: modelId,
                timeout: base.timeout,
                keychainService: base.keychainService,
                keychainAccount: base.keychainAccount
            )
            return OpenAIStreamingClient(configuration: config)
        case .claude:
            let base = ClaudeClientConfiguration.load()
            let config = ClaudeClientConfiguration(
                endpoint: base.endpoint,
                model: modelId,
                timeout: base.timeout,
                apiVersion: base.apiVersion,
                maxTokens: base.maxTokens,
                keychainService: base.keychainService,
                keychainAccount: base.keychainAccount
            )
            return ClaudeStreamingClient(configuration: config)
        case .gemini:
            let base = GeminiClientConfiguration.load()
            let config = GeminiClientConfiguration(
                endpoint: base.endpoint,
                model: modelId,
                timeout: base.timeout,
                maxTokens: base.maxTokens,
                keychainService: base.keychainService,
                keychainAccount: base.keychainAccount
            )
            return GeminiStreamingClient(configuration: config)
        }
    }

    private func ensureAPIKeyAvailable(for model: LLMModel) -> Bool {
        let hasKey = hasAPIKey(for: model)
        isAPIKeyAvailable = hasKey
        if !hasKey {
            errorMessage = "API key required for \(model.provider.displayName). Set \(model.provider.apiKeyName)."
            promptForKeyIfNeeded(for: model)
        }
        return hasKey
    }

    private func updateKeyAvailability(for model: LLMModel) {
        isAPIKeyAvailable = hasAPIKey(for: model)
    }

    private func hasAPIKey(for model: LLMModel) -> Bool {
        do {
            _ = try keyProvider(for: model).loadAPIKey()
            return true
        } catch {
            return false
        }
    }

    private func promptForKeyIfNeeded(for model: LLMModel) {
        guard !hasAPIKey(for: model) else { return }
        guard !isShowingKeyPrompt else { return }
        presentKeyPrompt(for: model)
    }

    private func presentKeyPrompt(for model: LLMModel) {
        keyPromptModel = model
        isShowingKeyPrompt = true
    }

    private func saveAPIKey(_ key: String) throws {
        let store = keyStore(for: keyPromptModel)
        try store.saveAPIKey(key)
        isShowingKeyPrompt = false
        updateKeyAvailability(for: keyPromptModel)
        createSessionIfNeededAfterKeySave()
    }

    private func keyProvider(for model: LLMModel) -> any APIKeyProvider {
        switch model.provider {
        case .openAI:
            let config = OpenAIClientConfiguration.load()
            return CompositeAPIKeyProvider(providers: [
                KeychainAPIKeyProvider(service: config.keychainService, account: config.keychainAccount),
                EnvironmentAPIKeyProvider(environmentKey: model.provider.environmentKey)
            ])
        case .claude:
            let config = ClaudeClientConfiguration.load()
            return CompositeAPIKeyProvider(providers: [
                KeychainAPIKeyProvider(service: config.keychainService, account: config.keychainAccount),
                EnvironmentAPIKeyProvider(environmentKey: model.provider.environmentKey)
            ])
        case .gemini:
            let config = GeminiClientConfiguration.load()
            return CompositeAPIKeyProvider(providers: [
                KeychainAPIKeyProvider(service: config.keychainService, account: config.keychainAccount),
                EnvironmentAPIKeyProvider(environmentKey: model.provider.environmentKey)
            ])
        }
    }

    private func keyStore(for model: LLMModel) -> any APIKeyStore {
        switch model.provider {
        case .openAI:
            let config = OpenAIClientConfiguration.load()
            return KeychainAPIKeyStore(service: config.keychainService, account: config.keychainAccount)
        case .claude:
            let config = ClaudeClientConfiguration.load()
            return KeychainAPIKeyStore(service: config.keychainService, account: config.keychainAccount)
        case .gemini:
            let config = GeminiClientConfiguration.load()
            return KeychainAPIKeyStore(service: config.keychainService, account: config.keychainAccount)
        }
    }

    private func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        activeStreamId = nil
        hasReceivedDelta = false
        isSending = false
    }

    private func removeTrailingAssistantMessage() {
        sessionStore.removeTrailingAssistantMessage()
        hasReceivedDelta = false
    }

    private func deleteSession(_ sessionId: UUID) {
        cancelStream()
        sessionStore.deleteSession(sessionId)
    }

    private func renameSession(_ sessionId: UUID, title: String) {
        sessionStore.updateSessionTitle(sessionId, title: title)
    }

    private func syncContextWithSelection(using text: String? = nil) {
        let newContext = text ?? selectionText
        let trimmed = newContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard newContext != activeContext else { return }
        sessionStore.updateActiveSessionContext(newContext)
        resetConversation()
    }

    private func loadSessionState() {
        resetTransientState()
        guard let session = sessionStore.activeSession else {
            updateKeyAvailability(for: selectedModel)
            return
        }
        selectedModel = session.selectedModel
        customModelId = session.customModelId
        keyPromptModel = session.selectedModel
        updateKeyAvailability(for: session.selectedModel)
        promptForKeyIfNeeded(for: session.selectedModel)
    }

    private func resetConversation() {
        sessionStore.clearActiveSessionMessages()
        resetTransientState()
    }

    private func resetTransientState() {
        inputText = ""
        cancelStream()
        errorMessage = nil
        retryPrompt = nil
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
        }
    }

    private func createSessionIfNeededAfterKeySave() {
        guard sessionStore.activeSession == nil else { return }
        guard let openPDFPath, !openPDFPath.isEmpty else { return }
        sessionStore.createSession(
            contextText: selectionText,
            model: selectedModel,
            customModelId: customModelId,
            openPDFPath: openPDFPath,
            activate: true
        )
    }
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: ChatRole
    var text: String

    init(id: UUID = UUID(), role: ChatRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

enum ChatRole: String, Codable {
    case user
    case assistant
}

private enum ChatScrollAnchor {
    static let bottom = "chat-bottom"
}

struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble
                Spacer(minLength: 32)
            } else {
                Spacer(minLength: 32)
                bubble
            }
        }
    }

    private var bubble: some View {
        Text(message.text)
            .font(.body)
            .padding(12)
            .background(bubbleColor)
            .cornerRadius(12)
            .frame(maxWidth: 360, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.06))
            )
    }

    private var bubbleColor: Color {
        message.role == .user
            ? Color.accentColor.opacity(0.18)
            : Color.secondary.opacity(0.12)
    }
}

struct ChatLoadingRow: View {
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Waiting for the response...")
            }
            .padding(12)
            .background(Color.secondary.opacity(0.12))
            .cornerRadius(12)
            Spacer(minLength: 32)
        }
    }
}

struct APIKeyPrompt: View {
    let providerName: String
    let apiKeyName: String
    let onSave: (String) throws -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKeyInput = ""
    @State private var errorMessage: String? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("API Key Required")
                .font(.title2)

            Text("Enter your \(providerName) key (\(apiKeyName)). It will be stored in Keychain.")
                .font(.body)
                .foregroundColor(.secondary)

            SecureField("API key", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                Spacer()
                Button("Save Key") {
                    do {
                        try onSave(apiKeyInput)
                        dismiss()
                    } catch {
                        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .onAppear {
            DispatchQueue.main.async {
                isFocused = true
            }
        }
    }
}

struct SessionSidebar: View {
    let sessions: [ChatSession]
    let activeSessionId: UUID?
    let onSelect: (UUID) -> Void
    let onNewSession: () -> Void
    let onDeleteSession: (UUID) -> Void
    let onRenameSession: (UUID, String) -> Void
    let canCreateSession: Bool

    @State private var hoveringSessionId: UUID? = nil
    @State private var renamingSessionId: UUID? = nil
    @State private var renameDraft = ""
    @State private var expandedPathSessionIds: Set<UUID> = []

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Sessions")
                    .font(.headline)
                Spacer()
                Button {
                    onNewSession()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!canCreateSession)
                .foregroundColor(canCreateSession ? .primary : .secondary)
                .opacity(canCreateSession ? 1 : 0.5)
            }
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sessions) { session in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                if renamingSessionId == session.id {
                                    TextField("Session name", text: $renameDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit {
                                            commitRename(for: session)
                                        }
                                } else {
                                    Text(session.title)
                                        .font(.subheadline)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.selectedModel.displayName)
                                    if let fileName = sessionFileName(session) {
                                        HStack(spacing: 6) {
                                            Text(fileName)
                                            if let directoryURL = sessionDirectoryURL(session) {
                                                Button {
                                                    NSWorkspace.shared.open(directoryURL)
                                                } label: {
                                                    Image(systemName: "doc")
                                                }
                                                .buttonStyle(.plain)
                                                .foregroundColor(.secondary)
                                                .accessibilityLabel("Open containing folder")
                                            }
                                            Button {
                                                togglePathExpansion(for: session.id)
                                            } label: {
                                                Image(systemName: "triangle")
                                                    .rotationEffect(.degrees(180))
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundColor(.secondary)
                                            .accessibilityLabel(expandedPathSessionIds.contains(session.id) ? "Hide full path" : "Show full path")
                                        }
                                        if expandedPathSessionIds.contains(session.id),
                                           let fullPath = sessionFullPath(session) {
                                            HStack(spacing: 6) {
                                                Text(fullPath)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(2)
                                                    .truncationMode(.middle)
                                                Button {
                                                    NSPasteboard.general.clearContents()
                                                    NSPasteboard.general.setString(fullPath, forType: .string)
                                                } label: {
                                                    Image(systemName: "doc.on.doc")
                                                }
                                                .buttonStyle(.plain)
                                                .foregroundColor(.secondary)
                                                .accessibilityLabel("Copy full path")
                                            }
                                        }
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            if hoveringSessionId == session.id {
                                Button {
                                    startRename(for: session)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(.secondary)
                                .accessibilityLabel("Rename session")

                                Button {
                                    onDeleteSession(session.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .foregroundColor(.secondary)
                                .accessibilityLabel("Delete session")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(backgroundColor(for: session))
                        .cornerRadius(8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(session.id)
                        }
                        .onHover { hovering in
                            hoveringSessionId = hovering ? session.id : nil
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func backgroundColor(for session: ChatSession) -> Color {
        session.id == activeSessionId
            ? Color.accentColor.opacity(0.16)
            : Color.secondary.opacity(0.08)
    }

    private func sessionFileName(_ session: ChatSession) -> String? {
        guard let path = session.openPDFPath else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func sessionDirectoryURL(_ session: ChatSession) -> URL? {
        guard let path = session.openPDFPath else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    private func sessionFullPath(_ session: ChatSession) -> String? {
        session.openPDFPath
    }

    private func startRename(for session: ChatSession) {
        renamingSessionId = session.id
        renameDraft = session.title
    }

    private func commitRename(for session: ChatSession) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            renameDraft = session.title
        } else {
            onRenameSession(session.id, trimmed)
        }
        renamingSessionId = nil
    }

    private func togglePathExpansion(for sessionId: UUID) {
        if expandedPathSessionIds.contains(sessionId) {
            expandedPathSessionIds.remove(sessionId)
        } else {
            expandedPathSessionIds.insert(sessionId)
        }
    }
}

enum LLMProvider: String, CaseIterable, Identifiable, Hashable, Codable {
    case openAI
    case claude
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .claude:
            return "Claude"
        case .gemini:
            return "Gemini"
        }
    }

    var apiKeyName: String {
        switch self {
        case .openAI:
            return "OPENAI_API_KEY"
        case .claude:
            return "ANTHROPIC_API_KEY"
        case .gemini:
            return "GEMINI_API_KEY"
        }
    }

    var environmentKey: String {
        switch self {
        case .openAI:
            return "OPENAI_API_KEY"
        case .claude:
            return "ANTHROPIC_API_KEY"
        case .gemini:
            return "GEMINI_API_KEY"
        }
    }
}

struct LLMModel: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let provider: LLMProvider
    let isCustom: Bool

    static let defaultOpenAI = LLMModel(
        id: "gpt-4o",
        displayName: "GPT-4o",
        provider: .openAI,
        isCustom: false
    )

    static let defaultClaude = LLMModel(
        id: "claude-sonnet-4-5-20250929",
        displayName: "Claude Sonnet 4.5",
        provider: .claude,
        isCustom: false
    )

    static let defaultGemini = LLMModel(
        id: "gemini-1.5-flash",
        displayName: "Gemini 1.5 Flash",
        provider: .gemini,
        isCustom: false
    )

    static let openAIModels: [LLMModel] = [
        defaultOpenAI,
        LLMModel(
            id: "gpt-4o-mini",
            displayName: "GPT-4o mini",
            provider: .openAI,
            isCustom: false
        ),
        LLMModel(
            id: "custom-openai",
            displayName: "Custom (OpenAI)",
            provider: .openAI,
            isCustom: true
        )
    ]

    static let claudeModels: [LLMModel] = [
        defaultClaude,
        LLMModel(
            id: "claude-opus-4-5-20251101",
            displayName: "Claude Opus 4.5",
            provider: .claude,
            isCustom: false
        ),
        LLMModel(
            id: "claude-haiku-4-5-20251001",
            displayName: "Claude Haiku 4.5",
            provider: .claude,
            isCustom: false
        ),
        LLMModel(
            id: "claude-sonnet-4-20250514",
            displayName: "Claude Sonnet 4",
            provider: .claude,
            isCustom: false
        ),
        LLMModel(
            id: "custom-claude",
            displayName: "Custom (Claude)",
            provider: .claude,
            isCustom: true
        )
    ]

    static let geminiModels: [LLMModel] = [
        defaultGemini,
        LLMModel(
            id: "gemini-1.5-pro",
            displayName: "Gemini 1.5 Pro",
            provider: .gemini,
            isCustom: false
        ),
        LLMModel(
            id: "custom-gemini",
            displayName: "Custom (Gemini)",
            provider: .gemini,
            isCustom: true
        )
    ]

    static func defaultModel(for provider: LLMProvider) -> LLMModel {
        switch provider {
        case .openAI:
            return defaultOpenAI
        case .claude:
            return defaultClaude
        case .gemini:
            return defaultGemini
        }
    }

    static func models(for provider: LLMProvider) -> [LLMModel] {
        switch provider {
        case .openAI:
            return openAIModels
        case .claude:
            return claudeModels
        case .gemini:
            return geminiModels
        }
    }
}
