import Foundation

struct ClaudeClientConfiguration {
    var endpoint: URL
    var model: String
    var timeout: TimeInterval
    var apiVersion: String
    var maxTokens: Int
    var keychainService: String
    var keychainAccount: String

    static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let defaultModel = "claude-sonnet-4-5-20250929"
    static let defaultVersion = "2023-06-01"
    static let filesBetaHeader = "files-api-2025-04-14"
    static let defaultMaxTokens = 1024

    static func load() -> ClaudeClientConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = URL(string: environment["ANTHROPIC_API_ENDPOINT"] ?? "") ?? defaultEndpoint
        let model = environment["ANTHROPIC_MODEL"] ?? defaultModel
        let timeout = TimeInterval(environment["ANTHROPIC_TIMEOUT"] ?? "") ?? 60
        let apiVersion = environment["ANTHROPIC_VERSION"] ?? defaultVersion
        let maxTokens = Int(environment["ANTHROPIC_MAX_TOKENS"] ?? "") ?? defaultMaxTokens
        let service = environment["ANTHROPIC_KEYCHAIN_SERVICE"] ?? "LLMPaperReadingHelper.Claude"
        let account = environment["ANTHROPIC_KEYCHAIN_ACCOUNT"] ?? "api-key"

        return ClaudeClientConfiguration(
            endpoint: endpoint,
            model: model,
            timeout: timeout,
            apiVersion: apiVersion,
            maxTokens: maxTokens,
            keychainService: service,
            keychainAccount: account
        )
    }
}

struct ClaudeStreamingClient: LLMClient {
    let configuration: ClaudeClientConfiguration
    let apiKeyProvider: any APIKeyProvider
    let session: URLSession

    init(
        configuration: ClaudeClientConfiguration = .load(),
        apiKeyProvider: (any APIKeyProvider)? = nil,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        let defaultProvider = CompositeAPIKeyProvider(providers: [
            KeychainAPIKeyProvider(
                service: configuration.keychainService,
                account: configuration.keychainAccount
            ),
            EnvironmentAPIKeyProvider(environmentKey: "ANTHROPIC_API_KEY")
        ])
        self.apiKeyProvider = apiKeyProvider ?? defaultProvider
        self.session = session
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
                var isFinished = false

                func finish(_ error: Error? = nil) {
                    guard !isFinished else { return }
                    isFinished = true
                    if let error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }

                do {
                    try validate(request)
                    let apiKey = try apiKeyProvider.loadAPIKey()
                    let urlRequest = try buildURLRequest(for: request, apiKey: apiKey, stream: true)

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw LLMClientError.remoteError("Missing HTTP response.")
                    }

                    guard (200..<300).contains(httpResponse.statusCode) else {
                        let body = try await readAllBytes(from: bytes)
                        let message = parseErrorMessage(from: body)
                        throw LLMClientError.httpStatus(httpResponse.statusCode, message)
                    }

                    var accumulated = ""
                    var pendingDataLines: [String] = []

                    func flushEvent() throws {
                        defer {
                            pendingDataLines.removeAll()
                        }

                        guard !pendingDataLines.isEmpty else { return }

                        for payload in pendingDataLines {
                            if payload == "[DONE]" { continue }

                            let envelope = try decodeStreamEvent(from: payload)
                            switch envelope.type {
                            case "ping":
                                // No-op: ping events keep the connection alive
                                break
                            case "content_block_delta":
                                if envelope.delta?.type == "text_delta",
                                   let delta = envelope.delta?.text,
                                   !delta.isEmpty {
                                    accumulated += delta
                                    continuation.yield(.textDelta(delta))
                                }
                            case "message_stop":
                                let replyText = accumulated
                                if !replyText.isEmpty {
                                    continuation.yield(.completed(LLMResponse(replyText: replyText)))
                                    finish()
                                } else {
                                    throw LLMClientError.emptyResponse
                                }
                            case "error":
                                let message = envelope.error?.message ?? "Claude error."
                                throw LLMClientError.remoteError(message)
                            default:
                                // Ignore other event types (message_start, content_block_start, content_block_stop, message_delta)
                                break
                            }
                        }
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            try flushEvent()
                            continue
                        }
                        if trimmed.hasPrefix("event:") {
                            continue
                        } else if trimmed.hasPrefix("data:") {
                            let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                            pendingDataLines.append(String(payload))
                        }
                    }

                    if Task.isCancelled {
                        throw CancellationError()
                    }

                    try flushEvent()

                    if !accumulated.isEmpty {
                        continuation.yield(.completed(LLMResponse(replyText: accumulated)))
                        finish()
                    } else {
                        finish(LLMClientError.emptyResponse)
                    }
                } catch {
                    finish(error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func validate(_ request: LLMRequest) throws {
        let trimmedPrompt = request.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw LLMClientError.invalidRequest("Prompt is empty.")
        }
    }

    private func buildURLRequest(
        for request: LLMRequest,
        apiKey: String,
        stream: Bool
    ) throws -> URLRequest {
        let endpoint = configuration.endpoint
        guard endpoint.scheme?.hasPrefix("http") == true else {
            throw LLMClientError.invalidEndpoint(endpoint.absoluteString)
        }

        let system = buildSystemPrompt(for: request)
        let messageContent = buildMessageContent(for: request)
        let payload = ClaudeRequestBody(
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            system: system,
            messages: [
                ClaudeMessage(role: "user", content: messageContent)
            ],
            stream: stream
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.httpBody = data
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        if request.fileID?.isEmpty == false {
            urlRequest.setValue(ClaudeClientConfiguration.filesBetaHeader, forHTTPHeaderField: "anthropic-beta")
        }
        if stream {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        return urlRequest
    }

    private func buildSystemPrompt(for request: LLMRequest) -> String? {
        var sections: [String] = []

        if let context = request.context?.trimmingCharacters(in: .whitespacesAndNewlines),
           !context.isEmpty {
            sections.append("Context:\n\"\"\"\n\(context)\n\"\"\"")
        }

        guard !sections.isEmpty else { return nil }
        return """
        You are a research assistant helping the user read a paper.
        Use the provided context from the paper when answering.

        \(sections.joined(separator: "\n\n"))
        """
    }

    private func buildMessageContent(for request: LLMRequest) -> [ClaudeContent] {
        var content: [ClaudeContent] = [
            .text(request.userPrompt)
        ]

        if let fileID = request.fileID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fileID.isEmpty {
            content.append(.document(fileID: fileID))
        }

        return content
    }

    private func readAllBytes(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let parsed = try? JSONDecoder().decode(ClaudeErrorEnvelope.self, from: data) {
            return parsed.error.message
        }
        return String(data: data, encoding: .utf8)
    }

    private func decodeStreamEvent(from payload: String) throws -> ClaudeStreamEventEnvelope {
        guard let data = payload.data(using: .utf8) else {
            throw LLMClientError.decoding("Non-UTF8 stream payload.")
        }
        do {
            return try JSONDecoder().decode(ClaudeStreamEventEnvelope.self, from: data)
        } catch {
            throw LLMClientError.decoding(error.localizedDescription)
        }
    }
}

private struct ClaudeRequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [ClaudeMessage]
    let stream: Bool

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
    }
}

private struct ClaudeMessage: Encodable {
    let role: String
    let content: [ClaudeContent]
}

private struct ClaudeContent: Encodable {
    let type: String
    let text: String?
    let source: ClaudeDocumentSource?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case source
    }

    static func text(_ value: String) -> ClaudeContent {
        ClaudeContent(type: "text", text: value, source: nil)
    }

    static func document(fileID: String) -> ClaudeContent {
        ClaudeContent(type: "document", text: nil, source: ClaudeDocumentSource(fileID: fileID))
    }
}

private struct ClaudeDocumentSource: Encodable {
    let type: String
    let fileID: String

    private enum CodingKeys: String, CodingKey {
        case type
        case fileID = "file_id"
    }

    init(fileID: String) {
        self.type = "file"
        self.fileID = fileID
    }
}

private struct ClaudeErrorEnvelope: Decodable {
    let error: ClaudeErrorDetail
}

private struct ClaudeErrorDetail: Decodable {
    let message: String
}

private struct ClaudeStreamEventEnvelope: Decodable {
    let type: String
    let delta: ClaudeDelta?
    let error: ClaudeErrorDetail?
}

private struct ClaudeDelta: Decodable {
    let type: String?
    let text: String?
}

struct ClaudeFileClient {
    let configuration: ClaudeClientConfiguration
    let apiKeyProvider: any APIKeyProvider
    let session: URLSession

    init(
        configuration: ClaudeClientConfiguration = .load(),
        apiKeyProvider: (any APIKeyProvider)? = nil,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        let defaultProvider = CompositeAPIKeyProvider(providers: [
            KeychainAPIKeyProvider(
                service: configuration.keychainService,
                account: configuration.keychainAccount
            ),
            EnvironmentAPIKeyProvider(environmentKey: "ANTHROPIC_API_KEY")
        ])
        self.apiKeyProvider = apiKeyProvider ?? defaultProvider
        self.session = session
    }

    func uploadFile(atPath path: String) async throws -> String {
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LLMClientError.invalidRequest("PDF file not found at \(path).")
        }

        let fileData = try Data(contentsOf: fileURL)
        let apiKey = try apiKeyProvider.loadAPIKey()
        let endpoint = try filesEndpoint()
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = makeMultipartBody(fileData: fileData, fileName: fileURL.lastPathComponent, boundary: boundary)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.httpBody = body
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(ClaudeClientConfiguration.filesBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.remoteError("Missing HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = parseErrorMessage(from: data)
            throw LLMClientError.httpStatus(httpResponse.statusCode, message)
        }

        let parsed = try JSONDecoder().decode(ClaudeFileUploadResponse.self, from: data)
        return parsed.id
    }

    func deleteFile(fileID: String) async throws {
        let trimmed = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let apiKey = try apiKeyProvider.loadAPIKey()
        let endpoint = try filesEndpoint().appendingPathComponent(trimmed)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = configuration.timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(ClaudeClientConfiguration.filesBetaHeader, forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.remoteError("Missing HTTP response.")
        }

        if httpResponse.statusCode == 404 {
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = parseErrorMessage(from: data)
            throw LLMClientError.httpStatus(httpResponse.statusCode, message)
        }
    }

    private func filesEndpoint() throws -> URL {
        guard var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              scheme.hasPrefix("http"),
              components.host != nil else {
            throw LLMClientError.invalidEndpoint(configuration.endpoint.absoluteString)
        }
        components.query = nil
        components.fragment = nil
        components.path = "/v1/files"
        guard let url = components.url else {
            throw LLMClientError.invalidEndpoint(configuration.endpoint.absoluteString)
        }
        return url
    }

    private func makeMultipartBody(fileData: Data, fileName: String, boundary: String) -> Data {
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let parsed = try? JSONDecoder().decode(ClaudeErrorEnvelope.self, from: data) {
            return parsed.error.message
        }
        return String(data: data, encoding: .utf8)
    }
}

extension ClaudeFileClient: LLMFileAttachmentClient {
    func ensureFileID(existingFileID: String?, filePath: String?) async throws -> String? {
        if let existingFileID = existingFileID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existingFileID.isEmpty {
            return existingFileID
        }

        guard let filePath = filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filePath.isEmpty else {
            return nil
        }

        return try await uploadFile(atPath: filePath)
    }

    func deleteFileIfNeeded(fileID: String?) async throws {
        guard let fileID = fileID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fileID.isEmpty else {
            return
        }
        try await deleteFile(fileID: fileID)
    }
}

private struct ClaudeFileUploadResponse: Decodable {
    let id: String
}
