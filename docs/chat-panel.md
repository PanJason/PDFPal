# Chat Panel Component Documentation

## Overview
The Chat Panel renders the right-side conversation UI for the macOS app. It
shows the selected PDF context, a scrollable message list, an input composer,
and UI states for loading and errors with retry. The current implementation
uses a mock response generator while the LLM service is still in progress.

## Public API
```swift
/**
 * ChatPanel - Right-side conversation UI for Ask LLM flow
 * @selectionText: Text selection captured from the PDF viewer
 * @onClose: Callback when the user closes the chat panel
 *
 * Renders a header, context card, message list, error banner, and input
 * composer. Uses a mock response to demonstrate loading and retry states.
 *
 * Example:
 *     ChatPanel(selectionText: selectionText, onClose: closeChat)
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
```

## State Management
- `ChatPanel` owns local state for `messages`, `inputText`, `isSending`, and
  error information needed for the retry banner.
- The panel resets its conversation when the selection text changes to reflect
  a new Ask LLM invocation.

## Integration Points
- `selectionText` is provided by `AppShellView` when the PDF viewer triggers
  Ask LLM.
- The mock response generator will be replaced by `LLMClient` integration when
  the backend wiring is ready.

## Usage Examples
```swift
ChatPanel(selectionText: selectionText, onClose: closeChat)
```
