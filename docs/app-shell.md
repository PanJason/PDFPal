# App Shell Component Documentation

## Overview
The macOS App Shell provides the SwiftUI application entry point, window
lifecycle, and split view layout that hosts the PDF panel and chat panel. It
also handles file selection via the system file importer and manages the
routing state that reveals the chat panel when an Ask LLM action occurs. It
also exposes a model family picker in the toolbar and owns session stores for
each model family. The app delegate also applies the app icon at launch using
the bundled `app_icon.png` asset with a SwiftPM fallback for development.

## Public API
```swift
/**
 * LLMPaperReadingHelperApp - SwiftUI app entry point
 *
 * Creates the main window group and hosts AppShellView as the root view.
 * Activates the app on launch to ensure keyboard focus.
 */
@main
struct LLMPaperReadingHelperApp: App {}

/**
 * AppShellView - Main split view shell for macOS
 *
 * Owns UI state for selected PDF URL, selection text, and whether the chat
 * panel is visible. Hosts PDFViewer and the chat panel. Allows switching
 * between model families.
 */
struct AppShellView: View {}

/**
 * OpenAILLMChatServing - OpenAI chat panel wrapper
 * @documentId: Identifier for the open document session
 * @selectionText: Text selection captured from the PDF viewer
 * @openPDFPath: File path of the currently opened PDF
 * @sessionStore: Session store for OpenAI sessions
 * @onClose: Callback when the user closes the chat panel
 *
 * Wraps the generic ChatPanel with OpenAI defaults.
 */
struct OpenAILLMChatServing: View {}

/**
 * ClaudeLLMChatServing - Claude chat panel wrapper
 * @documentId: Identifier for the open document session
 * @selectionText: Text selection captured from the PDF viewer
 * @openPDFPath: File path of the currently opened PDF
 * @sessionStore: Session store for Claude sessions
 * @onClose: Callback when the user closes the chat panel
 *
 * Wraps the generic ChatPanel with Claude defaults.
 */
struct ClaudeLLMChatServing: View {}
```

## State Management
- `AppShellView` owns `@State` properties for file selection, chat visibility,
  selection text, provider selection, and error presentation, plus
  `@StateObject` session stores for each provider.
- `selectionText` is updated when `PDFViewer` invokes the Ask LLM callback.
- `documentId` is derived from the selected file name and passed into the
  chat panel.
- When a session is selected, the app shell reopens the session's associated
  PDF path so the left panel follows the active session.

## Integration Points
- PDF rendering and selection are provided by `PDFViewer` from
  `src/macos/pdf-viewer.swift`.
- Chat rendering is provided by `OpenAILLMChatServing` in
  `src/macos/app-shell.swift` (or `ClaudeLLMChatServing`), which delegates to
  `ChatPanel` in `src/macos/chat-panel.swift` with the provider-specific
  `SessionStore`.
- File import uses SwiftUI `fileImporter` with `UTType.pdf`.

## Usage Examples
```swift
// Root view for the macOS app shell.
AppShellView()
```

```swift
// Example of wiring the PDF panel with the chat panel.
HSplitView {
    PDFViewer(fileURL: fileURL, onAskLLM: handleAskLLM)
    OpenAILLMChatServing(
        documentId: documentId,
        selectionText: selectionText,
        openPDFPath: fileURL?.path,
        sessionStore: openAISessionStore,
        onClose: closeChat
    )
}
```
