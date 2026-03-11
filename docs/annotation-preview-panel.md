# Annotation Preview Panel Documentation

## Overview
The Annotation Preview Panel renders the currently selected or opened PDFKit
annotation note on the far right side of the app. It is a read-through view
over note text already stored in the active PDF document and does not introduce
its own persistence model or editing flow.

## Public API
```swift
/**
 * AnnotationPreviewPanel - Right-side rendered annotation note preview
 * @selection: Current annotation note selection to render
 * @pipeline: Shared renderer used to convert note text into HTML
 * @onClose: Callback invoked when the user hides the preview panel
 *
 * Displays a header, optional warning banner, empty states, and a WKWebView
 * preview of the currently selected annotation note.
 *
 * Return: SwiftUI View
 */
struct AnnotationPreviewPanel: View {}

/**
 * RenderView - SwiftUI wrapper around WKWebView for rendered note HTML
 * @result: Final HTML document and warning state
 * @baseURL: Optional base URL for relative links
 *
 * Loads rendered HTML into WKWebView and opens clicked links in the system
 * browser instead of navigating inside the preview.
 *
 * Return: NSViewRepresentable
 */
struct RenderView: NSViewRepresentable {}
```

## State Management
- `AnnotationPreviewPanel` owns transient `renderResult` and `isRendering`
  state.
- Rendering is triggered with `.task(id:)` so the preview refreshes whenever the
  selected annotation changes.
- If no note is selected, the panel shows an empty state rather than a stale
  preview.

## Integration Points
- `AppShellView` in `src/macos/app-shell.swift` hosts the panel as a foldable
  third pane.
- `PDFViewer` supplies `AnnotationRenderSelection` values to the app shell,
  which passes them into `AnnotationPreviewPanel`.
- `RenderPipeline` generates the HTML shown by `RenderView`.

## Usage Examples
```swift
AnnotationPreviewPanel(
    selection: annotationSelection,
    pipeline: renderPipeline,
    onClose: { isAnnotationPreviewVisible = false }
)
```
