# App Shell Component Documentation

## Overview
The macOS App Shell provides the SwiftUI application entry point, window
lifecycle, and split view layout that hosts the PDF panel, chat panel, and
annotation preview panel. It handles file selection via the system file
importer, reveals the chat panel when an Ask LLM action occurs, and reveals the
annotation preview panel when the user selects or opens a PDF annotation note.
It also exposes a model family picker (OpenAI, Claude, Gemini) in the toolbar,
a PDF annotation menu (highlight/underline/strikethrough), and a view menu that
toggles the chat panel, session sidebar, annotation preview, and PDF sidebar
mode. The app delegate also applies the app icon at launch using the bundled
`app_icon.png` asset with a SwiftPM fallback for development. A `File > Save`
menu action (`Cmd+S`) is wired to save the current PDF with annotation changes.
The toolbar also includes a PDF search field with mode switching (`Any Match`
or `Exact Phrase`) and supports `Cmd+F` to focus the search field.

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
 * Owns UI state for selected PDF URL, selection text, the active annotation
 * preview selection, and whether the chat/preview panels are visible. Hosts
 * PDFViewer, the chat panel, and AnnotationPreviewPanel. Allows switching
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

/**
 * GeminiLLMChatServing - Gemini chat panel wrapper
 * @documentId: Identifier for the open document session
 * @selectionText: Text selection captured from the PDF viewer
 * @openPDFPath: File path of the currently opened PDF
 * @sessionStore: Session store for Gemini sessions
 * @onClose: Callback when the user closes the chat panel
 *
 * Wraps the generic ChatPanel with Gemini defaults.
 */
struct GeminiLLMChatServing: View {}

/**
 * AnnotationPreviewPanel - Right-side rendered annotation note preview
 * @selection: Current PDF annotation note selection to render
 * @pipeline: Shared render pipeline used to convert Markdown and math to HTML
 * @onClose: Callback when the preview panel is dismissed
 *
 * Renders the currently selected/opened PDF annotation note as formatted
 * Markdown with math support in a dedicated panel.
 */
struct AnnotationPreviewPanel: View {}
```

## State Management
- `AppShellView` owns `@State` properties for file selection, chat visibility,
  annotation preview visibility, selection text, current annotation note
  selection, provider selection, and error presentation, plus `@StateObject`
  session stores for each provider.
- `AppShellView` also owns `searchQuery` and `searchMode` state, and a search
  focus request token used by `Cmd+F` to focus the toolbar search field.
- `selectionText` is updated when `PDFViewer` invokes the Ask LLM callback.
- `annotationSelection` is updated when `PDFViewer` reports the currently
  selected/opened PDF annotation note.
- Ask LLM only updates context on the active session when it matches the
  current PDF; otherwise it creates a session only if a provider key exists.
- `documentId` is derived from the selected file name and passed into the
  chat panel.
- When a session is selected, the app shell reopens the session's associated
  PDF path so the left panel follows the active session.
- Restored sessions are wired to reopen their PDFs as soon as they are selected.
- When the user opens a different PDF or switches to a session for another PDF,
  the current annotation preview selection is cleared.

## Integration Points
- PDF rendering, search, and Ask LLM selection are provided by `PDFViewer` from
  `src/macos/pdf-viewer.swift`.
- Annotation note selection is also provided by `PDFViewer`, which bridges
  PDFKit annotation state into `AnnotationRenderSelection` values for the app
  shell.
- Chat rendering is provided by `OpenAILLMChatServing` in
  `src/macos/app-shell.swift` (or `ClaudeLLMChatServing`), which delegates to
  `ChatPanel` in `src/macos/chat-panel.swift` with the provider-specific
  `SessionStore`.
- Annotation note preview rendering is provided by `AnnotationPreviewPanel` in
  `src/macos/notes-panel.swift`, which uses `RenderPipeline` and `RenderView`
  from `src/macos/render/`.
- File import uses SwiftUI `fileImporter` with `UTType.pdf`.
- Toolbar annotation actions are broadcast as `PDFAnnotationAction` via
  `Notification.Name.pdfApplyAnnotation` and applied by `PDFKitView`.
- File menu save action posts `Notification.Name.pdfSaveDocument`, handled by
  `PDFKitView` to persist the current `PDFDocument` to its source URL.
- `Cmd+F` posts `Notification.Name.pdfFocusSearch`; `AppShellView` handles it
  by focusing the toolbar search field.
- The search field maps `Enter` to `pdfSearchNext` and `Shift+Enter` to
  `pdfSearchPrevious`.
- Search query and mode are passed into `PDFViewer`, where `PDFKitView`
  executes the document search.
- The view menu includes an `Annotation Preview` toggle. The preview panel also
  opens automatically when a note-bearing annotation is selected.

## Usage Examples
```swift
// Root view for the macOS app shell.
AppShellView()
```

```swift
HSplitView {
    PDFViewer(
        fileURL: fileURL,
        onAskLLM: handleAskLLM,
        onAnnotationSelectionChanged: handleAnnotationSelectionChanged,
        searchQuery: searchQuery,
        searchMode: searchMode,
        sidebarMode: selectedPDFSidebarMode
    )
    OpenAILLMChatServing(
        documentId: documentId,
        selectionText: selectionText,
        openPDFPath: fileURL?.path,
        sessionStore: openAISessionStore,
        onClose: closeChat
    )
    AnnotationPreviewPanel(
        selection: annotationSelection,
        pipeline: renderPipeline,
        onClose: closePreview
    )
}
```
