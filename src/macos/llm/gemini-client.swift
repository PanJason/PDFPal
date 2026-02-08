import Foundation

struct GeminiClientConfiguration {
    var endpoint: URL
    var model: String
    var timeout: TimeInterval
    var maxTokens: Int
    var keychainService: String
    var keychainAccount: String

    static let defaultEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1/models")!
    static let defaultModel = "gemini-2.5-pro"
    static let defaultMaxTokens = 1024

    static func load() -> GeminiClientConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = URL(string: environment["GEMINI_API_ENDPOINT"] ?? "") ?? defaultEndpoint
        let model = environment["GEMINI_MODEL"] ?? defaultModel
        let timeout = TimeInterval(environment["GEMINI_TIMEOUT"] ?? "") ?? 60
        let maxTokens = Int(environment["GEMINI_MAX_TOKENS"] ?? "") ?? defaultMaxTokens
        let service = environment["GEMINI_KEYCHAIN_SERVICE"] ?? "LLMPaperReadingHelper.Gemini"
        let account = environment["GEMINI_KEYCHAIN_ACCOUNT"] ?? "api-key"

        return GeminiClientConfiguration(
            endpoint: endpoint,
            model: model,
            timeout: timeout,
            maxTokens: maxTokens,
            keychainService: service,
            keychainAccount: account
        )
    }
}

struct GeminiStreamingClient: LLMClient {
    let configuration: GeminiClientConfiguration
    let apiKeyProvider: any APIKeyProvider
    let session: URLSession

    init(
        configuration: GeminiClientConfiguration = .load(),
        apiKeyProvider: (any APIKeyProvider)? = nil,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        let defaultProvider = CompositeAPIKeyProvider(providers: [
            KeychainAPIKeyProvider(
                service: configuration.keychainService,
                account: configuration.keychainAccount
            ),
            EnvironmentAPIKeyProvider(environmentKey: "GEMINI_API_KEY")
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

                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty else { continue }
                        if payload == "[DONE]" { break }

                        let chunk = try decodeStreamEvent(from: String(payload))

                        let text = chunk.candidates?
                            .first?
                            .content?
                            .parts?
                            .compactMap { $0.text }
                            .joined() ?? ""

                        if !text.isEmpty {
                            let delta: String
                            if text.hasPrefix(accumulated) {
                                delta = String(text.dropFirst(accumulated.count))
                                accumulated = text
                            } else {
                                delta = text
                                accumulated += text
                            }

                            if !delta.isEmpty {
                                continuation.yield(.textDelta(delta))
                            }
                        }

                        if let finishReason = chunk.candidates?.first?.finishReason,
                           !finishReason.isEmpty {
                            if !accumulated.isEmpty {
                                continuation.yield(.completed(LLMResponse(replyText: accumulated)))
                            }
                            finish()
                            return
                        }
                    }

                    if Task.isCancelled {
                        throw CancellationError()
                    }

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

        let action = stream ? "streamGenerateContent" : "generateContent"
        let url = endpoint.appendingPathComponent("\(configuration.model):\(action)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "key", value: apiKey)]
        if stream {
            queryItems.append(URLQueryItem(name: "alt", value: "sse"))
        }
        components?.queryItems = queryItems

        guard let finalURL = components?.url else {
            throw LLMClientError.invalidEndpoint(url.absoluteString)
        }

        let prompt = buildPrompt(for: request)
        let generationConfig = configuration.maxTokens > 0
            ? GeminiGenerationConfig(maxOutputTokens: configuration.maxTokens)
            : nil
        let payload = GeminiRequestBody(
            contents: [
                GeminiContent(role: "user", parts: [GeminiPart(text: prompt)])
            ],
            generationConfig: generationConfig
        )

        let data = try JSONEncoder().encode(payload)

        var urlRequest = URLRequest(url: finalURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.httpBody = data
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        return urlRequest
    }

    private func buildPrompt(for request: LLMRequest) -> String {
        var sections: [String] = []

        if let context = request.context?.trimmingCharacters(in: .whitespacesAndNewlines),
           !context.isEmpty {
            sections.append("Context:\n\"\"\"\n\(context)\n\"\"\"")
        }

        if sections.isEmpty {
            return request.userPrompt
        }

        return """
        You are a research assistant helping the user read a paper.
        Use the provided context from the paper when answering.

        \(sections.joined(separator: "\n\n"))

        User question:
        \(request.userPrompt)
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
        if let parsed = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
            return parsed.error?.message
        }
        return String(data: data, encoding: .utf8)
    }

    private func decodeStreamEvent(from payload: String) throws -> GeminiStreamResponse {
        guard let data = payload.data(using: .utf8) else {
            throw LLMClientError.decoding("Non-UTF8 stream payload.")
        }
        do {
            return try JSONDecoder().decode(GeminiStreamResponse.self, from: data)
        } catch {
            throw LLMClientError.decoding(error.localizedDescription)
        }
    }
}

private struct GeminiRequestBody: Encodable {
    let contents: [GeminiContent]
    let generationConfig: GeminiGenerationConfig?
}

private struct GeminiContent: Encodable {
    let role: String?
    let parts: [GeminiPart]
}

private struct GeminiPart: Encodable {
    let text: String
}

private struct GeminiGenerationConfig: Encodable {
    let maxOutputTokens: Int
}

private struct GeminiStreamResponse: Decodable {
    let candidates: [GeminiCandidate]?
}

private struct GeminiCandidate: Decodable {
    let content: GeminiContentResponse?
    let finishReason: String?
}

private struct GeminiContentResponse: Decodable {
    let parts: [GeminiPartResponse]?
}

private struct GeminiPartResponse: Decodable {
    let text: String?
}

private struct GeminiErrorResponse: Decodable {
    let error: GeminiErrorDetail?
}

private struct GeminiErrorDetail: Decodable {
    let message: String?
}
