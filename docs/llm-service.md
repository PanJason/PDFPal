# LLM Service Documentation

## Overview
The LLM Service provides streaming OpenAI, Claude, Gemini, and Qwen clients for
the macOS PoC. It exposes a small `LLMClient` protocol with mock, OpenAI,
Claude, Gemini, and Qwen streaming implementations, builds provider-specific
requests, and emits incremental text deltas for the chat UI to render in real
time.

## Public API
```swift
/**
 * LLMRequest - Single-turn LLM request payload
 * @documentId: Identifier for the active document session
 * @userPrompt: User prompt entered in the chat panel
 * @context: Optional context string from the session
 * @fileID: Optional uploaded file id for the session PDF
 * @attachments: Additional per-message file or image attachments
 * @webSearchEnabled: Whether to enable provider-side web search
 */
struct LLMRequest {}

/**
 * LLMResponse - Final response payload from the LLM
 * @replyText: Full assistant response text
 */
struct LLMResponse {}

/**
 * LLMStreamEvent - Streaming event for incremental rendering
 * @textDelta: New text chunk from the model stream
 * @completed: Final response emitted when the stream finishes
 */
enum LLMStreamEvent {}

/**
 * LLMClient - Protocol for LLM providers
 * @send: Fire-and-forget async request
 * @stream: Stream response deltas for live rendering
 */
protocol LLMClient {}

/**
 * APIKeyStore - Key loader and saver for provider credentials
 * @loadAPIKey: Load API key from storage
 * @saveAPIKey: Save API key into storage
 */
protocol APIKeyStore {}

/**
 * KeychainAPIKeyStore - Keychain-backed API key storage
 * @service: Keychain service name
 * @account: Keychain account name
 */
struct KeychainAPIKeyStore {}

/**
 * OpenAIClientConfiguration - OpenAI Responses API configuration
 * @endpoint: Responses API endpoint URL
 * @model: GPT model identifier
 * @timeout: Request timeout in seconds
 * @keychainService: Keychain service for API key lookup
 * @keychainAccount: Keychain account for API key lookup
 */
struct OpenAIClientConfiguration {}

/**
 * OpenAIStreamingClient - OpenAI GPT client using streaming responses
 * @configuration: OpenAI configuration options
 * @apiKeyProvider: API key loader (Keychain/env)
 * @session: URLSession used for network requests
 */
struct OpenAIStreamingClient {}

/**
 * OpenAIFileClient - OpenAI Files API client for upload/delete
 * @configuration: OpenAI configuration options
 * @apiKeyProvider: API key loader (Keychain/env)
 * @session: URLSession used for network requests
 */
struct OpenAIFileClient {}

/**
 * ClaudeFileClient - Claude Files API client for upload/delete
 * @configuration: Claude configuration options
 * @apiKeyProvider: API key loader (Keychain/env)
 * @session: URLSession used for network requests
 */
struct ClaudeFileClient {}

/**
 * GeminiFileClient - Gemini Files API client for upload/delete
 * @configuration: Gemini configuration options
 * @apiKeyProvider: API key loader (Keychain/env)
 * @session: URLSession used for network requests
 */
struct GeminiFileClient {}

/**
 * ClaudeClientConfiguration - Claude Messages API configuration
 * @endpoint: Messages API endpoint URL
 * @model: Claude model identifier
 * @timeout: Request timeout in seconds
 * @apiVersion: Anthropic API version header value
 * @maxTokens: Max tokens per response
 * @keychainService: Keychain service for API key lookup
 * @keychainAccount: Keychain account for API key lookup
 */
struct ClaudeClientConfiguration {}

/**
 * ClaudeStreamingClient - Claude client using streaming responses
 * @configuration: Claude configuration options
 * @apiKeyProvider: API key loader (Keychain/env)
 * @session: URLSession used for network requests
 */
struct ClaudeStreamingClient {}

/**
 * GeminiClientConfiguration - Gemini API configuration
 * @endpoint: Gemini API base endpoint URL
 * @model: Gemini model identifier
 * @timeout: Request timeout in seconds
 * @maxTokens: Max tokens per response
 * @keychainService: Keychain service for API key lookup
 * @keychainAccount: Keychain account for API key lookup
 */
struct GeminiClientConfiguration {}

/**
 * GeminiStreamingClient - Gemini client using streaming responses
 * @configuration: Gemini configuration options
 * @apiKeyProvider: API key loader (Keychain/env)
 * @session: URLSession used for network requests
 */
struct GeminiStreamingClient {}

/**
 * QwenClientConfiguration - Alibaba Cloud ModelStudio Chat Completions configuration
 * @endpoint: Chat Completions endpoint URL (OpenAI-compatible)
 * @model: Qwen model identifier
 * @timeout: Request timeout in seconds
 * @keychainService: Keychain service for API key lookup
 * @keychainAccount: Keychain account for API key lookup
 */
struct QwenClientConfiguration {}

/**
 * QwenStreamingClient - Qwen client via Alibaba Cloud ModelStudio (OpenAI-compatible)
 * @configuration: Qwen configuration options
 * @apiKeyProvider: API key loader (Keychain/env)
 * @session: URLSession used for network requests
 * Note: file upload is not supported; LLMRequest.fileID is ignored.
 */
struct QwenStreamingClient {}

/**
 * MockLLMClient - In-memory streaming mock for UI and tests
 */
struct MockLLMClient {}
```

## State Management
The LLM service is stateless. Each call builds a request from the provided
`LLMRequest` and returns stream events. Any accumulated streaming state is kept
inside the call scope.

## Integration Points
- `OpenAIStreamingClient` (in `src/macos/llm/openai-client.swift`) reads the API key from Keychain first, then falls back to
  `OPENAI_API_KEY` for development.
- `ClaudeStreamingClient` (in `src/macos/llm/claude-client.swift`) reads the API key from Keychain first, then falls back to
  `ANTHROPIC_API_KEY` for development.
- `GeminiStreamingClient` (in `src/macos/llm/gemini-client.swift`) reads the API key from Keychain first, then falls back to
  `GEMINI_API_KEY` for development.
- `QwenStreamingClient` (in `src/macos/llm/qwen-client.swift`) reads the API key from Keychain first, then falls back to
  `QWEN_API_KEY` for development. Uses the Alibaba Cloud ModelStudio OpenAI-compatible Chat Completions API;
  context is sent as a `system` message. File upload is not supported — `LLMRequest.fileID` is ignored.
- API keys saved from the chat panel are stored in Keychain via `KeychainAPIKeyStore`.
- Configuration is loaded from environment overrides:
  - OpenAI: `OPENAI_API_ENDPOINT`, `OPENAI_MODEL`, `OPENAI_TIMEOUT`, `OPENAI_KEYCHAIN_SERVICE`, `OPENAI_KEYCHAIN_ACCOUNT`
  - Claude: `ANTHROPIC_API_ENDPOINT`, `ANTHROPIC_MODEL`, `ANTHROPIC_TIMEOUT`, `ANTHROPIC_VERSION`,
    `ANTHROPIC_MAX_TOKENS`, `ANTHROPIC_KEYCHAIN_SERVICE`, `ANTHROPIC_KEYCHAIN_ACCOUNT`
  - Gemini: `GEMINI_API_ENDPOINT`, `GEMINI_MODEL`, `GEMINI_TIMEOUT`, `GEMINI_MAX_TOKENS`,
    `GEMINI_KEYCHAIN_SERVICE`, `GEMINI_KEYCHAIN_ACCOUNT`
  - Qwen: `QWEN_API_ENDPOINT`, `QWEN_MODEL`, `QWEN_TIMEOUT`, `QWEN_KEYCHAIN_SERVICE`, `QWEN_KEYCHAIN_ACCOUNT`
- The OpenAI Responses API and Claude Messages API are used with streaming
  events for incremental text rendering, along with the Gemini and Qwen streaming APIs.
- OpenAI requests include session PDFs via `input_file` content blocks and
  per-message attachments via `input_file` or `input_image` blocks. Web search
  uses the `web_search_preview` tool.
- Claude requests include session PDFs and per-message file attachments as
  `document` content blocks, and per-message images as `image` content blocks.
  Web search uses the `web_search_20250305` tool; the `files-api-2025-04-14`
  and `web-search-2025-03-05` beta headers are set as required.
- Gemini requests include session PDFs and per-message attachments as
  `file_data` parts. Web search uses the `google_search` tool.
- Qwen per-message images are encoded as `image_url` content parts. Web search
  uses the `enable_search` request parameter.
- `OpenAIFileClient` uploads PDFs with `purpose=user_data` and deletes them
  when sessions are removed.
- `ClaudeFileClient` uploads PDFs and images to the Claude Files API with the
  `files-api-2025-04-14` beta header; deletes files when sessions are removed.
  MIME type is inferred from the file extension (PDF, JPEG, PNG, GIF, WebP).
- `GeminiFileClient` performs resumable file upload, waits until file state is
  `ACTIVE`, and uses/deletes the returned file URI.
- Qwen sessions use `NoopFileAttachmentClient`; the session PDF is not uploaded.

## Usage Examples
```swift
let client = OpenAIStreamingClient()
let request = LLMRequest(
    documentId: "paper-123",
    userPrompt: "Summarize the main contribution.",
    context: contextText,
    fileID: "file-abc123"
)

Task {
    var responseText = ""
    for try await event in client.stream(request: request) {
        switch event {
        case .textDelta(let delta):
            responseText += delta
        case .completed(let response):
            responseText = response.replyText
        }
    }
}
```
