import Foundation

struct GeminiClientConfiguration {
    var endpoint: URL
    var model: String
    var timeout: TimeInterval
    var maxTokens: Int
    var keychainService: String
    var keychainAccount: String

    static let defaultEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
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
                GeminiContent(role: "user", parts: buildParts(prompt: prompt, fileURI: request.fileID))
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

    private func buildParts(prompt: String, fileURI: String?) -> [GeminiPart] {
        var parts: [GeminiPart] = [
            .text(prompt)
        ]

        if let fileURI = fileURI?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fileURI.isEmpty {
            parts.append(.fileData(mimeType: "application/pdf", fileURI: fileURI))
        }

        return parts
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
    let text: String?
    let fileData: GeminiFileDataPart?

    private enum CodingKeys: String, CodingKey {
        case text
        case fileData = "file_data"
    }

    static func text(_ text: String) -> GeminiPart {
        GeminiPart(text: text, fileData: nil)
    }

    static func fileData(mimeType: String, fileURI: String) -> GeminiPart {
        GeminiPart(
            text: nil,
            fileData: GeminiFileDataPart(mimeType: mimeType, fileURI: fileURI)
        )
    }
}

private struct GeminiFileDataPart: Encodable {
    let mimeType: String
    let fileURI: String

    private enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case fileURI = "file_uri"
    }
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

struct GeminiFileClient {
    let configuration: GeminiClientConfiguration
    let apiKeyProvider: any APIKeyProvider
    let session: URLSession
    let pollIntervalNanoseconds: UInt64
    let maxPollAttempts: Int

    init(
        configuration: GeminiClientConfiguration = .load(),
        apiKeyProvider: (any APIKeyProvider)? = nil,
        session: URLSession = .shared,
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        maxPollAttempts: Int = 60
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
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maxPollAttempts = maxPollAttempts
    }

    func uploadFile(atPath path: String) async throws -> String {
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LLMClientError.invalidRequest("PDF file not found at \(path).")
        }

        let apiKey = try apiKeyProvider.loadAPIKey()
        let fileData = try Data(contentsOf: fileURL)
        let uploadURL = try await startResumableUpload(
            apiKey: apiKey,
            fileName: fileURL.lastPathComponent,
            fileSizeBytes: fileData.count
        )

        let uploadedFile = try await finalizeUpload(
            uploadURL: uploadURL,
            fileData: fileData
        )

        let name = uploadedFile.name ?? resourceName(fromURI: uploadedFile.uri)
        guard let resourceName = name else {
            throw LLMClientError.decoding("Gemini upload missing resource name.")
        }
        let uri = try await waitUntilActive(apiKey: apiKey, resourceName: resourceName)
        return uri
    }

    func deleteFile(fileURI: String) async throws {
        let apiKey = try apiKeyProvider.loadAPIKey()
        guard let resourceName = resourceName(fromURI: fileURI) else {
            throw LLMClientError.invalidRequest("Invalid Gemini file URI.")
        }

        let endpoint = try filesEndpoint(for: resourceName, apiKey: apiKey)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = configuration.timeout

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

    private func startResumableUpload(
        apiKey: String,
        fileName: String,
        fileSizeBytes: Int
    ) async throws -> URL {
        let endpoint = try uploadStartEndpoint(apiKey: apiKey)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.httpBody = try JSONEncoder().encode(
            GeminiUploadStartRequest(file: GeminiUploadFileMeta(displayName: fileName))
        )
        request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(String(fileSizeBytes), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        request.setValue("application/pdf", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.remoteError("Missing HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LLMClientError.httpStatus(httpResponse.statusCode, nil)
        }

        guard let uploadURL = headerValue("x-goog-upload-url", from: httpResponse),
              let parsed = URL(string: uploadURL) else {
            throw LLMClientError.decoding("Gemini upload URL missing in response headers.")
        }
        return parsed
    }

    private func finalizeUpload(uploadURL: URL, fileData: Data) async throws -> GeminiFileMeta {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.httpBody = fileData
        request.setValue(String(fileData.count), forHTTPHeaderField: "Content-Length")
        request.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        request.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMClientError.remoteError("Missing HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = parseErrorMessage(from: data)
            throw LLMClientError.httpStatus(httpResponse.statusCode, message)
        }

        let payload = try JSONDecoder().decode(GeminiUploadResponse.self, from: data)
        if let file = payload.file {
            return file
        }
        return GeminiFileMeta(name: payload.name, uri: payload.uri, state: payload.state)
    }

    private func waitUntilActive(apiKey: String, resourceName: String) async throws -> String {
        let endpoint = try filesEndpoint(for: resourceName, apiKey: apiKey)

        for _ in 0..<maxPollAttempts {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = configuration.timeout

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMClientError.remoteError("Missing HTTP response.")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = parseErrorMessage(from: data)
                throw LLMClientError.httpStatus(httpResponse.statusCode, message)
            }

            let payload = try JSONDecoder().decode(GeminiFileStatusResponse.self, from: data)
            let file = payload.file ?? GeminiFileMeta(name: payload.name, uri: payload.uri, state: payload.state)
            let state = normalizeState(file.state)

            if state == "ACTIVE" {
                guard let uri = file.uri, !uri.isEmpty else {
                    throw LLMClientError.decoding("Gemini file is ACTIVE but missing URI.")
                }
                return uri
            }

            if state == "FAILED" || state == "ERROR" || state == "CANCELLED" {
                throw LLMClientError.remoteError("Gemini file processing failed (\(state)).")
            }

            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        throw LLMClientError.remoteError("Timed out waiting for Gemini file processing.")
    }

    private func normalizeState(_ state: String?) -> String {
        guard let state else { return "" }
        if let last = state.split(separator: ".").last {
            return String(last).uppercased()
        }
        return state.uppercased()
    }

    private func uploadStartEndpoint(apiKey: String) throws -> URL {
        guard var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              scheme.hasPrefix("http"),
              components.host != nil else {
            throw LLMClientError.invalidEndpoint(configuration.endpoint.absoluteString)
        }
        components.path = "/upload/v1beta/files"
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw LLMClientError.invalidEndpoint(configuration.endpoint.absoluteString)
        }
        return url
    }

    private func filesEndpoint(for resourceName: String, apiKey: String) throws -> URL {
        guard var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              scheme.hasPrefix("http"),
              components.host != nil else {
            throw LLMClientError.invalidEndpoint(configuration.endpoint.absoluteString)
        }
        let normalized = resourceName.hasPrefix("files/") ? resourceName : "files/\(resourceName)"
        components.path = "/v1beta/\(normalized)"
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw LLMClientError.invalidEndpoint(configuration.endpoint.absoluteString)
        }
        return url
    }

    private func headerValue(_ header: String, from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard let keyString = key as? String else { continue }
            if keyString.caseInsensitiveCompare(header) == .orderedSame {
                return value as? String
            }
        }
        return nil
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let parsed = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
            return parsed.error?.message
        }
        return String(data: data, encoding: .utf8)
    }

    private func resourceName(fromURI uri: String?) -> String? {
        guard let uri, let parsed = URL(string: uri) else { return nil }
        let path = parsed.path
        guard let range = path.range(of: "/files/") else { return nil }
        let suffix = path[range.upperBound...]
        guard !suffix.isEmpty else { return nil }
        return "files/\(suffix)"
    }
}

extension GeminiFileClient: LLMFileAttachmentClient {
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
        try await deleteFile(fileURI: fileID)
    }
}

private struct GeminiUploadStartRequest: Encodable {
    let file: GeminiUploadFileMeta
}

private struct GeminiUploadFileMeta: Encodable {
    let displayName: String

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

private struct GeminiUploadResponse: Decodable {
    let file: GeminiFileMeta?
    let name: String?
    let uri: String?
    let state: String?
}

private struct GeminiFileStatusResponse: Decodable {
    let file: GeminiFileMeta?
    let name: String?
    let uri: String?
    let state: String?
}

private struct GeminiFileMeta: Decodable {
    let name: String?
    let uri: String?
    let state: String?
}
