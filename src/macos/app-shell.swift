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

    var body: some View {
        HSplitView {
            PDFViewer(fileURL: fileURL, onAskLLM: handleAskLLM)
            .frame(minWidth: 360)

            if isChatVisible {
                OpenAILLMChatServing(
                    documentId: documentId,
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

    private var documentId: String {
        fileURL?.lastPathComponent ?? "document"
    }
}

private enum ChatScrollAnchor {
    static let bottom = "chat-bottom"
}

struct OpenAILLMChatServing: View {
    let documentId: String
    let selectionText: String
    let onClose: () -> Void

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isSending = false
    @State private var errorMessage: String? = nil
    @State private var retryPrompt: String? = nil
    @State private var lastContext = ""
    @State private var selectedModel: LLMModel = .defaultOpenAI
    @State private var customModelId = ""
    @State private var isAPIKeyAvailable = false
    @State private var isShowingKeyPrompt = false
    @State private var keyPromptModel: LLMModel = .defaultOpenAI
    @State private var streamTask: Task<Void, Never>? = nil
    @State private var activeStreamId: UUID? = nil
    @State private var hasReceivedDelta = false

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
                Text("OpenAI LLM Chat")
                    .font(.footnote)
                    .foregroundColor(.secondary)
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
                HStack {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(LLMModel.openAIModels) { model in
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
        }
    }

    private func keyStore(for model: LLMModel) -> any APIKeyStore {
        switch model.provider {
        case .openAI:
            let config = OpenAIClientConfiguration.load()
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
