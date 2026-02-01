# Chat Panel Component Documentation

## Overview
The Chat Panel renders the right-side conversation UI for the macOS app. It
shows the selected PDF context, a scrollable message list, an input composer,
and UI states for loading and errors with retry. It includes a model picker,
API key prompt, and streaming updates from the LLM service.

## Public API
```swift
/**
 * ChatPanel - Right-side conversation UI for Ask LLM flow
 * @documentId: Identifier for the open document session
 * @selectionText: Text selection captured from the PDF viewer
 * @onClose: Callback when the user closes the chat panel
 *
 * Renders a header, model picker, context card, message list, error banner,
 * and input composer. Streams responses from the LLM service and prompts
 * for an API key when needed.
 *
 * Example:
 *     ChatPanel(
 *         documentId: documentId,
 *         selectionText: selectionText,
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
- `ChatPanel` owns local state for `messages`, `inputText`, `isSending`, and
  error information needed for the retry banner and streaming updates.
- The panel resets its conversation when the selection text changes to reflect
  a new Ask LLM invocation.
- Model selection state drives the OpenAI streaming client configuration.

## Integration Points
- `selectionText` is provided by `AppShellView` when the PDF viewer triggers
  Ask LLM.
- Streaming responses use `OpenAIStreamingClient` from `llm-client.swift`.
- API keys are stored in Keychain via the prompt sheet.

## Usage Examples
```swift
ChatPanel(
    documentId: documentId,
    selectionText: selectionText,
    onClose: closeChat
)
```
