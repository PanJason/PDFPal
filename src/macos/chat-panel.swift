import SwiftUI

struct ChatPanel: View {
    let documentId: String
    let selectionText: String
    let provider: LLMProvider
    let onClose: () -> Void

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isSending = false
    @State private var errorMessage: String? = nil
    @State private var retryPrompt: String? = nil
    @State private var lastContext = ""
    @State private var selectedModel: LLMModel
    @State private var customModelId = ""
    @State private var isAPIKeyAvailable = false
    @State private var isShowingKeyPrompt = false
    @State private var keyPromptModel: LLMModel
    @State private var streamTask: Task<Void, Never>? = nil
    @State private var activeStreamId: UUID? = nil
    @State private var hasReceivedDelta = false

    init(
        documentId: String,
        selectionText: String,
        provider: LLMProvider,
        onClose: @escaping () -> Void
    ) {
        self.documentId = documentId
        self.selectionText = selectionText
        self.provider = provider
        self.onClose = onClose
        let defaultModel = LLMModel.defaultModel(for: provider)
        _selectedModel = State(initialValue: defaultModel)
        _keyPromptModel = State(initialValue: defaultModel)
    }

    var body: some View {
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
        .onAppear {
            resetConversationIfNeeded()
            updateKeyAvailability(for: selectedModel)
            promptForKeyIfNeeded(for: selectedModel)
        }
        .onChange(of: selectionText) { _ in
            resetConversationIfNeeded()
        }
        .onChange(of: selectedModel) { newValue in
            updateKeyAvailability(for: newValue)
            promptForKeyIfNeeded(for: newValue)
        }
        .onChange(of: provider) { newValue in
            let defaultModel = LLMModel.defaultModel(for: newValue)
            selectedModel = defaultModel
            keyPromptModel = defaultModel
            customModelId = ""
            resetConversation()
            updateKeyAvailability(for: defaultModel)
            promptForKeyIfNeeded(for: defaultModel)
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
                    if messages.isEmpty && !isSending {
                        Text("Ask a question about the selection to start the conversation.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    ForEach(messages) { message in
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
            .onChange(of: messages.count) { _ in
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

    private var isSendDisabled: Bool {
        if isSending { return true }
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if selectedModel.isCustom && resolvedModelId() == nil { return true }
        return false
    }

    private var contextText: String {
        selectionText.isEmpty
            ? "Select text in the PDF and choose Ask LLM to seed the conversation."
            : selectionText
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
            messages.append(ChatMessage(role: .user, text: prompt))
        }

        let streamId = UUID()
        activeStreamId = streamId
        let assistantId = UUID()

        let request = LLMRequest(
            documentId: documentId,
            selectionText: selectionText,
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
            messages.append(ChatMessage(id: assistantId, role: .assistant, text: delta))
            hasReceivedDelta = true
        } else if let index = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[index].text += delta
        }
    }

    private func finalizeAssistantMessage(_ text: String, assistantId: UUID) {
        if !hasReceivedDelta {
            messages.append(ChatMessage(id: assistantId, role: .assistant, text: text))
            hasReceivedDelta = true
        } else if let index = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[index].text = text
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
        if let last = messages.last, last.role == .assistant {
            messages.removeLast()
        }
        hasReceivedDelta = false
    }

    private func resetConversationIfNeeded() {
        guard selectionText != lastContext else { return }
        lastContext = selectionText
        resetConversation()
    }

    private func resetConversation() {
        messages.removeAll()
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
}

struct ChatMessage: Identifiable {
    let id: UUID
    let role: ChatRole
    var text: String

    init(id: UUID = UUID(), role: ChatRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

enum ChatRole {
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

enum LLMProvider: String, CaseIterable, Identifiable, Hashable {
    case openAI
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .claude:
            return "Claude"
        }
    }

    var apiKeyName: String {
        switch self {
        case .openAI:
            return "OPENAI_API_KEY"
        case .claude:
            return "ANTHROPIC_API_KEY"
        }
    }

    var environmentKey: String {
        switch self {
        case .openAI:
            return "OPENAI_API_KEY"
        case .claude:
            return "ANTHROPIC_API_KEY"
        }
    }
}

struct LLMModel: Identifiable, Hashable {
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

    static func defaultModel(for provider: LLMProvider) -> LLMModel {
        switch provider {
        case .openAI:
            return defaultOpenAI
        case .claude:
            return defaultClaude
        }
    }

    static func models(for provider: LLMProvider) -> [LLMModel] {
        switch provider {
        case .openAI:
            return openAIModels
        case .claude:
            return claudeModels
        }
    }
}
