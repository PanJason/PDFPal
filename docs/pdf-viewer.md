# PDF Viewer Component Documentation

## Overview
The PDF Viewer component hosts a native PDFKit view inside SwiftUI. It handles
loading a local PDF file, shows an empty or error state when appropriate, and
adds a context menu action that sends the current text selection to the LLM
flow in the app shell.

## Public API
```swift
/**
 * PDFViewer - SwiftUI wrapper for PDFKit rendering
 * @fileURL: Optional file URL for the PDF to display
 * @onAskLLM: Callback invoked when the user selects Ask LLM from the context menu
 *
 * Displays a PDF with auto-scaling, shows empty/error states, and routes the
 * current selection to the app shell when the Ask LLM menu item is chosen.
 *
 * Example:
 *     PDFViewer(fileURL: fileURL) { selection in
 *         handleAskLLM(selection)
 *     }
 *
 * Return: SwiftUI View
 */
struct PDFViewer: View {}

/**
 * PDFKitContainer - NSViewRepresentable wrapper around PDFKitView
 * @document: PDFDocument instance to render
 * @onAskLLM: Callback invoked for Ask LLM menu action
 */
struct PDFKitContainer: NSViewRepresentable {}

/**
 * PDFKitView - PDFView subclass that augments the context menu
 * @onAskLLM: Closure called with the current selection text
 */
final class PDFKitView: PDFView {}

/**
 * PDFEmptyState - Empty or error messaging for the PDF panel
 * @title: Primary title for the state
 * @message: Secondary message for the state
 */
struct PDFEmptyState: View {}
```

## State Management
- `PDFViewer` owns `@State` properties for the loaded `PDFDocument` and a
  user-facing load error message.
- `PDFKitView` maintains the Ask LLM callback and queries its current selection
  at menu invocation time.

## Integration Points
- The `onAskLLM` callback is wired to `AppShellView` to open the chat panel.
- The file URL is provided by the file importer in the app shell.

## Usage Examples
```swift
PDFViewer(fileURL: fileURL) { selection in
    handleAskLLM(selection)
}
```

```swift
HSplitView {
    PDFViewer(fileURL: fileURL, onAskLLM: handleAskLLM)
    ChatPanel(selectionText: selectionText, onClose: closeChat)
}
```
