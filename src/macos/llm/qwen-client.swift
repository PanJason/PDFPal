import Foundation
import UniformTypeIdentifiers

struct QwenClientConfiguration {
    var endpoint: URL
    var model: String
    var timeout: TimeInterval
    var keychainService: String
    var keychainAccount: String

    // International (Singapore) endpoint — compatible with OpenAI Chat Completions API.
    static let defaultEndpoint = URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")!
    static let defaultModel = "qwen-max"

    static func load() -> QwenClientConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = URL(string: environment["QWEN_API_ENDPOINT"] ?? "") ?? defaultEndpoint
        let model = environment["QWEN_MODEL"] ?? defaultModel
        let timeout = TimeInterval(environment["QWEN_TIMEOUT"] ?? "") ?? 60
        let service = environment["QWEN_KEYCHAIN_SERVICE"] ?? "LLMPaperReadingHelper.Qwen"
        let account = environment["QWEN_KEYCHAIN_ACCOUNT"] ?? "api-key"

        return QwenClientConfiguration(
            endpoint: endpoint,
            model: model,
            timeout: timeout,
            keychainService: service,
            keychainAccount: account
        )
    }
}

// Qwen uses the DashScope OpenAI-compatible Chat Completions API.
// Rich composer support is currently limited to image-style inputs encoded as
// image_url content parts. Generic file attachments remain unsupported here.
struct QwenStreamingClient: LLMClient {
    let configuration: QwenClientConfiguration
    let apiKeyProvider: any APIKeyProvider
    let session: URLSession

    init(
        configuration: QwenClientConfiguration = .load(),
        apiKeyProvider: (any APIKeyProvider)? = nil,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        let defaultProvider = CompositeAPIKeyProvider(providers: [
            KeychainAPIKeyProvider(
                service: configuration.keychainService,
                account: configuration.keychainAccount
            ),
            EnvironmentAPIKeyProvider(environmentKey: "QWEN_API_KEY")
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
                    let urlRequest = try buildURLRequest(for: request, apiKey: apiKey)

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

                        let chunk = try decodeChunk(from: String(payload))
                        guard let choice = chunk.choices.first else { continue }

                        if let delta = choice.delta.content, !delta.isEmpty {
                            accumulated += delta
                            continuation.yield(.textDelta(delta))
                        }

                        if choice.finishReason == "stop" || choice.finishReason == "length" {
                            if !accumulated.isEmpty {
                                continuation.yield(.completed(LLMResponse(replyText: accumulated)))
                            } else {
                                throw LLMClientError.emptyResponse
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

    private func buildURLRequest(for request: LLMRequest, apiKey: String) throws -> URLRequest {
        let endpoint = configuration.endpoint
        guard endpoint.scheme?.hasPrefix("http") == true else {
            throw LLMClientError.invalidEndpoint(endpoint.absoluteString)
        }

        var messages: [QwenMessage] = []

        if let systemContent = buildSystemContent(for: request) {
            messages.append(QwenMessage(role: "system", content: .text(systemContent)))
        }
        messages.append(QwenMessage(role: "user", content: buildUserContent(for: request)))

        let payload = QwenRequestBody(
            model: configuration.model,
            messages: messages,
            stream: true,
            enableSearch: request.webSearchEnabled
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.httpBody = data
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return urlRequest
    }

    private func buildSystemContent(for request: LLMRequest) -> String? {
        guard let context = request.context?.trimmingCharacters(in: .whitespacesAndNewlines),
              !context.isEmpty else { return nil }
        return """
        You are a research assistant helping the user read a paper.
        Use the provided context from the paper when answering.

        Context:
        \"\"\"
        \(context)
        \"\"\"
        """
    }

    private func buildUserContent(for request: LLMRequest) -> QwenMessageContent {
        var parts: [QwenContentPart] = []

        for attachment in request.attachments where attachment.kind == .image {
            if let imageURL = makeQwenImageURL(from: attachment.fileID) {
                parts.append(.imageURL(imageURL))
            }
        }

        parts.append(.text(request.userPrompt))
        return .parts(parts)
    }

    private func makeQwenImageURL(from fileID: String) -> String? {
        let trimmed = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fileURL = URL(fileURLWithPath: trimmed)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let mimeType = mimeType(for: fileURL)
        return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func mimeType(for fileURL: URL) -> String {
        if let type = UTType(filenameExtension: fileURL.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
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
        if let parsed = try? JSONDecoder().decode(QwenErrorResponse.self, from: data) {
            return parsed.error?.message
        }
        return String(data: data, encoding: .utf8)
    }

    private func decodeChunk(from payload: String) throws -> QwenStreamChunk {
        guard let data = payload.data(using: .utf8) else {
            throw LLMClientError.decoding("Non-UTF8 stream payload.")
        }
        do {
            return try JSONDecoder().decode(QwenStreamChunk.self, from: data)
        } catch {
            throw LLMClientError.decoding(error.localizedDescription)
        }
    }
}

private struct QwenRequestBody: Encodable {
    let model: String
    let messages: [QwenMessage]
    let stream: Bool
    let enableSearch: Bool?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case enableSearch = "enable_search"
    }
}

private struct QwenMessage: Encodable {
    let role: String
    let content: QwenMessageContent
}

private enum QwenMessageContent: Encodable {
    case text(String)
    case parts([QwenContentPart])

    func encode(to encoder: Encoder) throws {
        var singleValue = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try singleValue.encode(text)
        case .parts(let parts):
            try singleValue.encode(parts)
        }
    }
}

private struct QwenContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: QwenImageURL?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    static func text(_ text: String) -> QwenContentPart {
        QwenContentPart(type: "text", text: text, imageURL: nil)
    }

    static func imageURL(_ url: String) -> QwenContentPart {
        QwenContentPart(type: "image_url", text: nil, imageURL: QwenImageURL(url: url))
    }
}

private struct QwenImageURL: Encodable {
    let url: String
}

private struct QwenStreamChunk: Decodable {
    let choices: [QwenStreamChoice]
}

private struct QwenStreamChoice: Decodable {
    let delta: QwenDelta
    let finishReason: String?

    private enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

private struct QwenDelta: Decodable {
    let content: String?
}

private struct QwenErrorResponse: Decodable {
    struct Detail: Decodable {
        let message: String
    }

    let error: Detail?
}
