import Combine
import Foundation

struct ChatSession: Identifiable {
    let id: UUID
    var title: String
    let provider: LLMProvider
    var createdAt: Date
    var contextText: String
    var messages: [ChatMessage]
    var selectedModel: LLMModel
    var customModelId: String
    var openPDFPath: String?
}

final class SessionStore: ObservableObject {
    let provider: LLMProvider

    @Published private(set) var sessions: [ChatSession] = []
    @Published var activeSessionId: UUID?

    private var sessionCounter = 0

    init(provider: LLMProvider) {
        self.provider = provider
    }

    var activeSession: ChatSession? {
        guard let activeSessionId else { return nil }
        return sessions.first(where: { $0.id == activeSessionId })
    }

    @discardableResult
    func createSession(
        contextText: String,
        model: LLMModel,
        customModelId: String = "",
        openPDFPath: String? = nil,
        activate: Bool = true
    ) -> ChatSession {
        let resolvedModel = model.provider == provider
            ? model
            : LLMModel.defaultModel(for: provider)
        let session = ChatSession(
            id: UUID(),
            title: nextSessionTitle(),
            provider: provider,
            createdAt: Date(),
            contextText: contextText,
            messages: [],
            selectedModel: resolvedModel,
            customModelId: resolvedModel.isCustom ? customModelId : "",
            openPDFPath: openPDFPath
        )
        sessions.append(session)
        if activate {
            activeSessionId = session.id
        }
        return session
    }

    func selectSession(_ id: UUID) {
        activeSessionId = id
    }

    func updateActiveSessionContext(_ contextText: String) {
        updateActiveSession { session in
            session.contextText = contextText
        }
    }

    func updateActiveSessionModel(_ model: LLMModel) {
        updateActiveSession { session in
            session.selectedModel = model
            if !model.isCustom {
                session.customModelId = ""
            }
        }
    }

    func updateActiveSessionCustomModelId(_ customModelId: String) {
        updateActiveSession { session in
            session.customModelId = customModelId
        }
    }

    func updateActiveSessionOpenPDFPath(_ openPDFPath: String?) {
        updateActiveSession { session in
            session.openPDFPath = openPDFPath
        }
    }

    func clearActiveSessionMessages() {
        updateActiveSession { session in
            session.messages.removeAll()
        }
    }

    func appendMessage(_ message: ChatMessage) {
        updateActiveSession { session in
            session.messages.append(message)
        }
    }

    func updateAssistantMessage(id: UUID, update: (inout ChatMessage) -> Void) {
        updateActiveSession { session in
            guard let index = session.messages.firstIndex(where: { $0.id == id }) else { return }
            update(&session.messages[index])
        }
    }

    func removeTrailingAssistantMessage() {
        updateActiveSession { session in
            if let last = session.messages.last, last.role == .assistant {
                session.messages.removeLast()
            }
        }
    }

    private func updateActiveSession(_ mutation: (inout ChatSession) -> Void) {
        guard let index = activeSessionIndex else { return }
        var session = sessions[index]
        mutation(&session)
        sessions[index] = session
    }

    private var activeSessionIndex: Int? {
        guard let activeSessionId else { return nil }
        return sessions.firstIndex(where: { $0.id == activeSessionId })
    }

    func latestSession(matchingPDFPath path: String) -> ChatSession? {
        sessions
            .filter { $0.openPDFPath == path }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    private func nextSessionTitle() -> String {
        sessionCounter += 1
        return "Session \(sessionCounter)"
    }
}
