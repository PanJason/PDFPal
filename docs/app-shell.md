# App Shell Component Documentation

## Overview
The macOS App Shell provides the SwiftUI application entry point, window
lifecycle, and split view layout that hosts the PDF panel and chat panel. It
also handles file selection via the system file importer and manages the
routing state that reveals the chat panel when an Ask LLM action occurs.

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
 * panel is visible. Hosts PDFViewer and the chat panel.
 */
struct AppShellView: View {}

/**
 * OpenAILLMChatServing - OpenAI chat panel implementation
 * @documentId: Identifier for the open document session
 * @selectionText: Text selection captured from the PDF viewer
 * @onClose: Callback when the user closes the chat panel
 *
 * Renders the OpenAI chat UI with model selection, API key prompt,
 * and streaming responses.
 */
struct OpenAILLMChatServing: View {}
```

## State Management
- `AppShellView` owns `@State` properties for file selection, chat visibility,
  selection text, and error presentation.
- `selectionText` is updated when `PDFViewer` invokes the Ask LLM callback.
- `documentId` is derived from the selected file name and passed into the
  chat panel.

## Integration Points
- PDF rendering and selection are provided by `PDFViewer` from
  `src/macos/pdf-viewer.swift`.
- Chat rendering is provided by `OpenAILLMChatServing` in
  `src/macos/app-shell.swift`.
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
        onClose: closeChat
    )
}
```
