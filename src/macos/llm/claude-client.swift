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
        if request.selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           request.context?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            throw LLMClientError.invalidRequest("Selection is empty and no context was provided.")
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
        let payload = ClaudeRequestBody(
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            system: system,
            messages: [
                ClaudeMessage(role: "user", content: request.userPrompt)
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
        if stream {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        return urlRequest
    }

    private func buildSystemPrompt(for request: LLMRequest) -> String? {
        var sections: [String] = []

        let selection = request.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty {
            sections.append("Selected passage:\n\"\"\"\n\(selection)\n\"\"\"")
        }

        if let context = request.context?.trimmingCharacters(in: .whitespacesAndNewlines),
           !context.isEmpty {
            sections.append("Additional context:\n\"\"\"\n\(context)\n\"\"\"")
        }

        guard !sections.isEmpty else { return nil }
        return """
        You are a research assistant helping the user read a paper.
        Use the provided context from the paper when answering.

        \(sections.joined(separator: "\n\n"))
        """
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
    let content: String
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
