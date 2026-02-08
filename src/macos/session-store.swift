import Combine
import Foundation

struct ChatSession: Identifiable, Codable {
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
    private let persistenceURL: URL
    private var isLoading = false
    private var cancellables = Set<AnyCancellable>()

    init(provider: LLMProvider) {
        self.provider = provider
        self.persistenceURL = SessionStore.persistenceURL(for: provider)
        loadSessions()
        startPersistence()
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

    func deleteSession(_ id: UUID) {
        let wasActive = (activeSessionId == id)
        sessions.removeAll { $0.id == id }
        if wasActive {
            activeSessionId = sessions
                .sorted { $0.createdAt > $1.createdAt }
                .first?
                .id
        }
    }

    func persistNow() {
        persistSessions()
    }

    func updateActiveSessionContext(_ contextText: String) {
        updateActiveSession { session in
            session.contextText = contextText
        }
    }

    func updateSessionTitle(_ id: UUID, title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var session = sessions[index]
        session.title = trimmed
        sessions[index] = session
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

private extension SessionStore {
    struct PersistedSessions: Codable {
        let activeSessionId: UUID?
        let sessions: [ChatSession]
    }

    static func persistenceURL(for provider: LLMProvider) -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let directory = base.appendingPathComponent("LLMPaperReadingHelper", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory.appendingPathComponent("sessions-\(provider.rawValue).json")
    }

    func loadSessions() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: persistenceURL) else { return }
        do {
            let payload = try JSONDecoder().decode(PersistedSessions.self, from: data)
            sessions = payload.sessions
            activeSessionId = payload.activeSessionId ?? sessions.first?.id
            sessionCounter = max(sessionCounter, sessions.count)
        } catch {
            sessions = []
            activeSessionId = nil
        }
    }

    func startPersistence() {
        $sessions
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.persistSessions()
            }
            .store(in: &cancellables)

        $activeSessionId
            .dropFirst()
            .sink { [weak self] _ in
                self?.persistSessions()
            }
            .store(in: &cancellables)
    }

    func persistSessions() {
        guard !isLoading else { return }
        let payload = PersistedSessions(activeSessionId: activeSessionId, sessions: sessions)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: persistenceURL, options: [.atomic])
        } catch {
            return
        }
    }
}
