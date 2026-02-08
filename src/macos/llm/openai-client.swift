import Foundation

struct OpenAIClientConfiguration {
    var endpoint: URL
    var model: String
    var timeout: TimeInterval
    var keychainService: String
    var keychainAccount: String

    static let defaultEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let defaultModel = "gpt-4o"

    static func load() -> OpenAIClientConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = URL(string: environment["OPENAI_API_ENDPOINT"] ?? "") ?? defaultEndpoint
        let model = environment["OPENAI_MODEL"] ?? defaultModel
        let timeout = TimeInterval(environment["OPENAI_TIMEOUT"] ?? "") ?? 60
        let service = environment["OPENAI_KEYCHAIN_SERVICE"] ?? "LLMPaperReadingHelper.OpenAI"
        let account = environment["OPENAI_KEYCHAIN_ACCOUNT"] ?? "api-key"

        return OpenAIClientConfiguration(
            endpoint: endpoint,
            model: model,
            timeout: timeout,
            keychainService: service,
            keychainAccount: account
        )
    }
}

struct OpenAIStreamingClient: LLMClient {
    let configuration: OpenAIClientConfiguration
    let apiKeyProvider: any APIKeyProvider
    let session: URLSession

    init(
        configuration: OpenAIClientConfiguration = .load(),
        apiKeyProvider: (any APIKeyProvider)? = nil,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        let defaultProvider = CompositeAPIKeyProvider(providers: [
            KeychainAPIKeyProvider(
                service: configuration.keychainService,
                account: configuration.keychainAccount
            ),
            EnvironmentAPIKeyProvider(environmentKey: "OPENAI_API_KEY")
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
                    var finalizedText: String?

                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("data:") else { continue }

                        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty else { continue }
                        if payload == "[DONE]" { break }

                        let event = try decodeStreamEvent(from: String(payload))
                        switch event.type {
                        case "response.output_text.delta":
                            if let delta = event.delta, !delta.isEmpty {
                                accumulated += delta
                                continuation.yield(.textDelta(delta))
                            }
                        case "response.output_text.done":
                            if let text = event.text, !text.isEmpty {
                                finalizedText = text
                            }
                        case "response.completed":
                            let replyText = finalizedText ?? accumulated
                            if !replyText.isEmpty {
                                continuation.yield(.completed(LLMResponse(replyText: replyText)))
                            } else {
                                throw LLMClientError.emptyResponse
                            }
                            finish()
                            return
                        case "response.failed", "error":
                            let message = event.errorMessage ?? "Response failed."
                            throw LLMClientError.remoteError(message)
                        default:
                            continue
                        }
                    }

                    if Task.isCancelled {
                        throw CancellationError()
                    }

                    let replyText = finalizedText ?? accumulated
                    if !replyText.isEmpty {
                        continuation.yield(.completed(LLMResponse(replyText: replyText)))
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

        let instructions = buildInstructions(for: request)
        let payload = OpenAIRequestBody(
            model: configuration.model,
            input: request.userPrompt,
            instructions: instructions,
            stream: stream,
            metadata: request.documentId.isEmpty ? nil : ["document_id": request.documentId]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.httpBody = data
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if stream {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        return urlRequest
    }

    private func buildInstructions(for request: LLMRequest) -> String? {
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

    private func readAllBytes(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let parsed = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            return parsed.error?.message
        }
        return String(data: data, encoding: .utf8)
    }

    private func decodeStreamEvent(from payload: String) throws -> OpenAIStreamEventEnvelope {
        guard let data = payload.data(using: .utf8) else {
            throw LLMClientError.decoding("Non-UTF8 stream payload.")
        }
        do {
            return try JSONDecoder().decode(OpenAIStreamEventEnvelope.self, from: data)
        } catch {
            throw LLMClientError.decoding(error.localizedDescription)
        }
    }
}

private struct OpenAIRequestBody: Encodable {
    let model: String
    let input: String
    let instructions: String?
    let stream: Bool
    let metadata: [String: String]?
}

private struct OpenAIErrorResponse: Decodable {
    struct Detail: Decodable {
        let message: String
    }

    let error: Detail?
}

private struct OpenAIStreamEventEnvelope: Decodable {
    let type: String
    let delta: String?
    let text: String?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case delta
        case text
        case error
        case response
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        delta = try container.decodeIfPresent(String.self, forKey: .delta)
        text = try container.decodeIfPresent(String.self, forKey: .text)

        if let error = try container.decodeIfPresent(OpenAIErrorResponse.Detail.self, forKey: .error) {
            errorMessage = error.message
        } else if let response = try container.decodeIfPresent(OpenAIStreamResponseContainer.self, forKey: .response) {
            errorMessage = response.error?.message
        } else {
            errorMessage = nil
        }
    }
}

private struct OpenAIStreamResponseContainer: Decodable {
    let error: OpenAIErrorResponse.Detail?
}
