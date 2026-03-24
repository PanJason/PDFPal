# Chat Panel Component Documentation

## Overview
The Chat Panel renders the right-side conversation UI for the macOS app. It
shows the selected PDF context, a scrollable message list, an input composer,
and UI states for loading and errors with retry. It includes a model picker,
API key prompt, per-provider session selection sidebar (OpenAI, Claude,
Gemini, Qwen), and streaming updates from the LLM service. A hover-only fold control
lets the user hide or show the session sidebar. The composer supports
ChatGPT-style rich input actions from a `+` menu, removable attachment chips
with Quick Look, and a web-search toggle rendered as a pill when enabled.
All four providers (OpenAI, Claude, Gemini, Qwen) support file/image
attachments, screenshots, camera capture, and web search. Completed user and
assistant messages can also render through the shared Markdown/math pipeline
when the content looks like Markdown, while streamed assistant output remains
plain text until completion.

## Public API
```swift
/**
 * ChatPanel - Right-side conversation UI for Ask LLM flow
 * @documentId: Identifier for the open document session
 * @selectionText: Text selection captured from the PDF viewer
 * @openPDFPath: File path of the currently opened PDF
 * @sessionStore: Session store for the selected model family
 * @isSessionSidebarVisible: Binding that controls session sidebar visibility
 * @onClose: Callback when the user closes the chat panel
 *
 * Renders a header, model picker, context card, message list, error banner,
 * and input composer. Streams responses from the LLM service and prompts
 * for an API key when needed. Displays a session sidebar for switching
 * between sessions within the current model family. The sidebar can be
 * collapsed with a hover-only fold control. For supported providers, the
 * composer supports file or image uploads, screenshots, camera capture, and
 * web-search-enabled requests.
 *
 * Example:
 *     ChatPanel(
 *         documentId: documentId,
 *         selectionText: selectionText,
 *         openPDFPath: fileURL?.path,
 *         sessionStore: openAISessionStore,
 *         isSessionSidebarVisible: $isSessionSidebarVisible,
 *         onClose: closeChat
 *     )
 *
 * Return: SwiftUI View
 */
struct ChatPanel: View {}

/**
 * ChatMessage - Single chat entry in the message list
 * @role: Sender role for the message
 * @text: Message content
 */
struct ChatMessage: Identifiable {}

/**
 * ChatRole - Role classification for chat messages
 */
enum ChatRole {}

/**
 * APIKeyPrompt - Sheet UI to capture and store API keys
 * @providerName: Display name for the selected provider
 * @apiKeyName: Environment variable name for the key
 * @onSave: Callback to store the key in Keychain
 * @onCancel: Callback when the sheet is dismissed
 */
struct APIKeyPrompt: View {}

/**
 * SessionSidebar - Session picker UI for the active provider
 * @sessions: Ordered list of sessions for the provider
 * @activeSessionId: Current session identifier
 * @onSelect: Callback when a session is selected
 * @onNewSession: Callback when a new session is created
 */
struct SessionSidebar: View {}

/**
 * LLMProvider - LLM provider enumeration for model selection
 */
enum LLMProvider {}

/**
 * LLMModel - Model selection metadata for the chat panel
 * @id: Model identifier
 * @displayName: Label shown in the model picker
 * @provider: Owning LLM provider
 * @isCustom: True when the model id is user supplied
 */
struct LLMModel: Identifiable {}
```

## State Management
- `ChatPanel` owns transient state for `inputText`, `isSending`, and
  error information needed for the retry banner and streaming updates.
- Message history, model selection, and context live in a `SessionStore`
  so each provider maintains its own session list.
- The panel updates the active session context when selection text changes.
- Empty selections are ignored so restored sessions keep their last context.
- Model selection state drives the OpenAI or Claude streaming client configuration.
- The session sidebar visibility is toggled from a hover-only fold control.
- The session sidebar allows deleting sessions from the current model family.
- Sessions can be renamed from the sidebar using a hover-only edit control.
- The new-session control is disabled until the provider API key is available.
- The context card includes a toggle to include or omit context text from
  LLM requests. When enabled, either selection or context must be present.
  When disabled, only the typed prompt is sent.
- The composer tracks pending attachments separately from the saved session.
  Attachments are shown as removable chips above the input box and are cleared
  after a successful send or when the active session changes.
- The web search control is transient UI state. When enabled for providers that
  support it, the globe expands into a rounded search pill and the outgoing
  request opts into provider-side web search.
- Assistant messages align to the left, while user messages align to the right.
- Chat bubbles classify completed messages heuristically. If Markdown or math is
  detected, the message is rendered with the shared web-based render pipeline;
  otherwise the bubble stays on the lightweight `Text` path.
- Assistant responses remain plain text while streaming, then switch to rendered
  output after completion when the content qualifies.
- Rendered chat bubbles expose a small `Show original` / `Show rendered` toggle
  so the user can compare the rendered output against the raw Markdown source.
- User messages that include context show a context icon on the bubble. Tapping
  the icon reveals the stored context beneath the message.
- Session rows show the associated PDF filename, a file icon that opens the
  containing folder in Finder, and a disclosure control that reveals the full
  path with a copy-to-clipboard shortcut.
- The session sidebar width is resizable by dragging the divider between the
  chat panel and the session list.

## Integration Points
- `selectionText` is provided by `AppShellView` when the PDF viewer triggers
  Ask LLM.
- Ask LLM updates the active session context only when the session matches the
  open PDF; otherwise a new session is created if a provider key exists.
- `openPDFPath` is used when creating new sessions to associate them with the
  active document.
- `sessionStore` is provided by `AppShellView` and scoped per model family.
- Streaming responses use `OpenAIStreamingClient`, `ClaudeStreamingClient`,
  `GeminiStreamingClient`, or `QwenStreamingClient` from `src/macos/llm/`.
- For OpenAI, Claude, and Gemini sessions, the panel uploads the session PDF
  to the provider Files API before the first prompt, stores the returned
  `fileID` in the session, and reuses it for later prompts.
- For OpenAI models, the composer uploads additional files and images through
  `OpenAIFileClient` and sends them as `LLMAttachment` entries on the request.
  Web search uses the `web_search_preview` tool.
- For Claude models, the composer uploads additional files and images through
  `ClaudeFileClient` and sends them as `document` or `image` content blocks.
  Web search uses the `web_search_20250305` tool with the
  `web-search-2025-03-05` beta header. The `files-api-2025-04-14` beta header
  is included when file or image attachments are present.
- For Gemini models, the composer uploads additional files and images through
  `GeminiFileClient` and sends them as `fileData` parts alongside the session
  PDF. Web search uses the `google_search` tool.
- For Qwen models, the composer accepts image attachments, screenshots, and
  camera photos encoded as `image_url` content parts. Web search is enabled
  through the provider's `enable_search` request parameter.
- The shared `RenderView` is also reused inside chat bubbles with chat-specific
  CSS overrides and dynamic height measurement so rendered messages match the
  plain bubble styling more closely.
- Deleting an OpenAI, Claude, or Gemini session also attempts to delete its
  uploaded file from the provider Files API.
- API keys are stored in Keychain via the prompt sheet.

## Usage Examples
```swift
ChatPanel(
    documentId: documentId,
    selectionText: selectionText,
    sessionStore: openAISessionStore,
    onClose: closeChat
)
```
