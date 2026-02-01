# Session Store Component Documentation

## Overview
The Session Store keeps in-memory chat sessions scoped by model family. Each
provider (OpenAI, Claude) has its own `SessionStore`, and the Chat Panel uses
it to persist messages, selected models, and context per session. The store
backs the session sidebar on the right side of the chat panel.

## Public API
```swift
/**
 * ChatSession - In-memory chat session for a model family
 * @title: Human-friendly label shown in the session sidebar
 * @provider: Owning LLM provider
 * @createdAt: Timestamp for when the session was created
 * @contextText: Selection context associated with the session
 * @messages: Stored chat messages for the session
 * @selectedModel: Selected model within the provider
 * @customModelId: Custom model identifier when using a custom model
 * @openPDFPath: File path of the PDF associated with the session
 */
struct ChatSession: Identifiable {}

/**
 * SessionStore - In-memory session store for a single model family
 * @provider: LLM provider that owns this store
 * @sessions: Ordered list of sessions for the provider
 * @activeSessionId: Currently selected session identifier
 *
 * Creates and selects new sessions, updates active session state, and
 * appends streamed messages during chat. Supports deleting sessions and
 * reassigning the active session.
 */
final class SessionStore: ObservableObject {}
```

## State Management
- Each `SessionStore` is an `ObservableObject` with published session lists and
  active session selection.
- The chat panel reads the active session to render messages and model settings.
- Session creation starts with empty messages and the current context selection.
- Each session can store the path of its associated PDF so the app shell can
  reopen documents when switching sessions.
- Deleting a session removes it from the list and reassigns the active session
  to the most recently created remaining session when needed.

## Integration Points
- `AppShellView` owns one `SessionStore` per provider and passes it into
  `ChatPanel`.
- `ChatPanel` mutates the active session when streaming messages or changing
  models.

## Usage Examples
```swift
let openAISessionStore = SessionStore(provider: .openAI)
ChatPanel(
    documentId: documentId,
    selectionText: selectionText,
    sessionStore: openAISessionStore,
    onClose: closeChat
)
```
