import Foundation
import Security

struct LLMRequest {
    let documentId: String
    let userPrompt: String
    let context: String?
    let fileID: String?
}

struct LLMResponse {
    let replyText: String
}

enum LLMStreamEvent {
    case textDelta(String)
    case completed(LLMResponse)
}

protocol LLMClient {
    func send(request: LLMRequest) async throws -> LLMResponse
    func stream(request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

protocol LLMFileAttachmentClient {
    func ensureFileID(existingFileID: String?, filePath: String?) async throws -> String?
    func deleteFileIfNeeded(fileID: String?) async throws
}

struct NoopFileAttachmentClient: LLMFileAttachmentClient {
    func ensureFileID(existingFileID: String?, filePath: String?) async throws -> String? {
        nil
    }

    func deleteFileIfNeeded(fileID: String?) async throws {}
}

func makeFileAttachmentClient(for model: LLMModel) -> any LLMFileAttachmentClient {
    switch model.provider {
    case .openAI:
        return OpenAIFileClient(configuration: .load())
    case .claude:
        return ClaudeFileClient(configuration: .load())
    case .gemini:
        return GeminiFileClient(configuration: .load())
    }
}

enum LLMClientError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case keychainError(OSStatus)
    case invalidRequest(String)
    case invalidEndpoint(String)
    case httpStatus(Int, String?)
    case decoding(String)
    case remoteError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing API key. Store it in Keychain or set the provider environment key."
        case .invalidAPIKey:
            return "API key is empty or invalid."
        case .keychainError(let status):
            return "Keychain error: \(status)."
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        case .invalidEndpoint(let endpoint):
            return "Invalid endpoint: \(endpoint)"
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                return "LLM request failed (\(status)): \(message)"
            }
            return "LLM request failed with status \(status)."
        case .decoding(let message):
            return "Failed to decode response: \(message)"
        case .remoteError(let message):
            return "LLM error: \(message)"
        case .emptyResponse:
            return "LLM returned an empty response."
        }
    }
}

protocol APIKeyProvider {
    func loadAPIKey() throws -> String
}

protocol APIKeyStore: APIKeyProvider {
    func saveAPIKey(_ key: String) throws
}

struct KeychainAPIKeyProvider: APIKeyProvider {
    let service: String
    let account: String

    func loadAPIKey() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw LLMClientError.missingAPIKey
        }
        guard status == errSecSuccess else {
            throw LLMClientError.keychainError(status)
        }
        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            throw LLMClientError.invalidAPIKey
        }
        return key
    }
}

struct KeychainAPIKeyStore: APIKeyStore {
    let service: String
    let account: String

    func loadAPIKey() throws -> String {
        try KeychainAPIKeyProvider(service: service, account: account).loadAPIKey()
    }

    func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMClientError.invalidAPIKey
        }

        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw LLMClientError.keychainError(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw LLMClientError.keychainError(status)
        }
    }
}

struct EnvironmentAPIKeyProvider: APIKeyProvider {
    let environmentKey: String

    func loadAPIKey() throws -> String {
        let value = ProcessInfo.processInfo.environment[environmentKey] ?? ""
        guard !value.isEmpty else {
            throw LLMClientError.missingAPIKey
        }
        return value
    }
}

struct CompositeAPIKeyProvider: APIKeyProvider {
    let providers: [any APIKeyProvider]

    func loadAPIKey() throws -> String {
        var lastError: Error?
        for provider in providers {
            do {
                return try provider.loadAPIKey()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LLMClientError.missingAPIKey
    }
}

struct MockLLMClient: LLMClient {
    let chunkDelayNanoseconds: UInt64

    init(chunkDelayNanoseconds: UInt64 = 120_000_000) {
        self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }

    func send(request: LLMRequest) async throws -> LLMResponse {
        var finalResponse: LLMResponse?
        for try await event in stream(request: request) {
            if case let .completed(response) = event {
                finalResponse = response
            }
        }
        guard let finalResponse else {
            throw LLMClientError.emptyResponse
        }
        return finalResponse
    }

    func stream(request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let replyText = """
                Mock response for: \(request.userPrompt)
                Context length: \(request.context?.count ?? 0)
                File id attached: \(request.fileID ?? "none")
                """

                do {
                    for chunk in replyText.chunked(into: 18) {
                        try await Task.sleep(nanoseconds: chunkDelayNanoseconds)
                        continuation.yield(.textDelta(chunk))
                    }
                    continuation.yield(.completed(LLMResponse(replyText: replyText)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        guard size > 0 else { return [self] }
        var chunks: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[index..<end]))
            index = end
        }
        return chunks
    }
}
