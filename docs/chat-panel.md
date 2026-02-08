# Chat Panel Component Documentation

## Overview
The Chat Panel renders the right-side conversation UI for the macOS app. It
shows the selected PDF context, a scrollable message list, an input composer,
and UI states for loading and errors with retry. It includes a model picker,
API key prompt, per-provider session selection sidebar (OpenAI, Claude,
Gemini), and streaming updates from the LLM service. A hover-only fold control
lets the user hide or show the session sidebar.

## Public API
```swift
/**
 * ChatPanel - Right-side conversation UI for Ask LLM flow
 * @documentId: Identifier for the open document session
 * @selectionText: Text selection captured from the PDF viewer
 * @openPDFPath: File path of the currently opened PDF
 * @sessionStore: Session store for the selected model family
 * @onClose: Callback when the user closes the chat panel
 *
 * Renders a header, model picker, context card, message list, error banner,
 * and input composer. Streams responses from the LLM service and prompts
 * for an API key when needed. Displays a session sidebar for switching
 * between sessions within the current model family. The sidebar can be
 * collapsed with a hover-only fold control.
 *
 * Example:
 *     ChatPanel(
 *         documentId: documentId,
 *         selectionText: selectionText,
 *         openPDFPath: fileURL?.path,
 *         sessionStore: openAISessionStore,
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
- Session rows show the associated PDF filename and a file icon that opens the
  containing folder in Finder.

## Integration Points
- `selectionText` is provided by `AppShellView` when the PDF viewer triggers
  Ask LLM.
- Ask LLM updates the active session context only when the session matches the
  open PDF; otherwise a new session is created if a provider key exists.
- `openPDFPath` is used when creating new sessions to associate them with the
  active document.
- `sessionStore` is provided by `AppShellView` and scoped per model family.
- Streaming responses use `OpenAIStreamingClient` or `ClaudeStreamingClient`
  from `src/macos/llm/`.
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
