import SwiftUI

struct ChatPanel: View {
    let selectionText: String
    let onClose: () -> Void

    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isSending = false
    @State private var errorMessage: String? = nil
    @State private var retryPrompt: String? = nil
    @State private var lastContext = ""

    var body: some View {
        VStack(spacing: 16) {
            header
            contextCard
            Divider()
            messageList
            errorBanner
            inputBar
        }
        .padding(20)
        .onAppear {
            resetConversationIfNeeded()
        }
        .onChange(of: selectionText) { _ in
            resetConversationIfNeeded()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chat")
                    .font(.title2)
                Text("Model: GPT (mock)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Close") {
                onClose()
            }
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
                    if isSending {
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
                    if retryPrompt != nil {
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
                .disabled(isSending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
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

        let prompt = trimmed
        inputText = ""
        errorMessage = nil
        isSending = true
        messages.append(ChatMessage(role: .user, text: prompt))
        retryPrompt = prompt

        simulateResponse(for: prompt)
    }

    private func retrySend() {
        guard let retryPrompt else { return }
        errorMessage = nil
        isSending = true
        simulateResponse(for: retryPrompt)
    }

    private func simulateResponse(for prompt: String) {
        let shouldFail = prompt.lowercased().contains("fail") || prompt.lowercased().contains("error")
        let selectionLength = selectionText.count
        let contextSnapshot = selectionText

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard contextSnapshot == selectionText else { return }
            isSending = false
            if shouldFail {
                errorMessage = "Mock LLM request failed. Retry to send again."
            } else {
                let reply = """
                Mock reply. Selection length: \(selectionLength) characters.
                Prompt: \(prompt)
                """
                messages.append(ChatMessage(role: .assistant, text: reply))
            }
        }
    }

    private func resetConversationIfNeeded() {
        guard selectionText != lastContext else { return }
        lastContext = selectionText
        messages.removeAll()
        inputText = ""
        isSending = false
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
    let id = UUID()
    let role: ChatRole
    let text: String
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
