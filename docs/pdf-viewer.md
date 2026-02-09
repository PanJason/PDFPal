# PDF Viewer Component Documentation

## Overview
The PDF Viewer component hosts a native PDFKit view inside SwiftUI. It handles
loading a local PDF file, shows an empty or error state when appropriate, and
adds context menu actions for Ask LLM and PDF annotations. It supports
highlighting selections with color, underlining, strikethrough, and editing
annotation notes from a right-click menu on existing annotations.

## Public API
```swift
/**
 * PDFAnnotationAction - Commands to apply PDF markup in the active PDF view
 *
 * Supported actions include color highlights, underline, and strikethrough.
 */
enum PDFAnnotationAction {}

/**
 * PDFViewer - SwiftUI wrapper for PDFKit rendering
 * @fileURL: Optional file URL for the PDF to display
 * @onAskLLM: Callback invoked when the user selects Ask LLM from the context menu
 *
 * Displays a PDF with auto-scaling, shows empty/error states, and routes the
 * current selection to the app shell when Ask LLM is chosen.
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
 *
 * Adds:
 * - "Annotate Selection" submenu (highlight colors, underline, strikethrough)
 * - "Add/Edit Note..." when right-clicking an existing annotation
 * - "Ask LLM" on current text selection
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
- `PDFKitView` maintains the Ask LLM callback and caches the latest selection
  when building the context menu.
- `PDFKitView` listens for toolbar annotation commands via
  `Notification.Name.pdfApplyAnnotation`.
- `PDFKitView` listens for `Notification.Name.pdfSaveDocument` and writes the
  current document back to `documentURL`.

## Integration Points
- The `onAskLLM` callback is wired to `AppShellView` to open the chat panel.
- The file URL is provided by the file importer in the app shell.
- Toolbar highlight actions post a `PDFAnnotationAction` notification that the
  active PDF view applies to the current selection.
- File menu save (`Cmd+S`) posts `pdfSaveDocument`; the PDF view persists all
  annotation and note edits to disk.

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
