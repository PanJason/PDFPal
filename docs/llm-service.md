# LLM Service Documentation

## Overview
The LLM Service provides a streaming OpenAI GPT client for the macOS PoC. It
exposes a small `LLMClient` protocol with mock and OpenAI streaming
implementations, builds OpenAI Responses API requests, and emits incremental
text deltas for the chat UI to render in real time.

## Public API
```swift
/**
 * LLMRequest - Single-turn LLM request payload
 * @documentId: Identifier for the active document session
 * @selectionText: Text selection captured from the PDF viewer
 * @userPrompt: User prompt entered in the chat panel
 * @context: Optional extra context string
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
 * MockLLMClient - In-memory streaming mock for UI and tests
 */
struct MockLLMClient {}
```

## State Management
The LLM service is stateless. Each call builds a request from the provided
`LLMRequest` and returns stream events. Any accumulated streaming state is kept
inside the call scope.

## Integration Points
- `OpenAIStreamingClient` reads the API key from Keychain first, then falls back to
  `OPENAI_API_KEY` for development.
- Configuration is loaded from environment overrides: `OPENAI_API_ENDPOINT`,
  `OPENAI_MODEL`, `OPENAI_TIMEOUT`, `OPENAI_KEYCHAIN_SERVICE`, and
  `OPENAI_KEYCHAIN_ACCOUNT`.
- The OpenAI Responses API is used with streaming events for incremental text
  rendering.

## Usage Examples
```swift
let client = OpenAIStreamingClient()
let request = LLMRequest(
    documentId: "paper-123",
    selectionText: selection,
    userPrompt: "Summarize the main contribution.",
    context: nil
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
