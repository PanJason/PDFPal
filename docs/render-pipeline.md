# Render Pipeline Documentation

## Overview
The render pipeline converts annotation note text into displayable HTML for the
right-side preview panel. It accepts Markdown or HTML input, extracts
GitHub-style math fragments, converts math with `MathJaxSwift`, and wraps the
result in a styled HTML document suitable for `WKWebView`.

## Public API
```swift
/**
 * RenderFormat - Source format accepted by the shared renderer
 *
 * Supported formats:
 * - markdown
 * - html
 */
enum RenderFormat {}

/**
 * RenderContent - Input payload for rich text rendering
 * @source: Raw Markdown or HTML source to render
 * @format: Declared source format
 * @baseURL: Optional base URL for relative links
 * @isTrusted: Whether raw HTML may bypass sanitization
 */
struct RenderContent {}

/**
 * RenderWarning - Non-fatal issue emitted during rendering
 * @message: User-visible warning string
 */
struct RenderWarning: Identifiable {}

/**
 * RenderResult - Final render payload for the web view
 * @html: Fully wrapped HTML document string
 * @warnings: Non-fatal render warnings
 */
struct RenderResult {}

/**
 * AnnotationRenderSelection - Current PDF annotation note selected for preview
 * @documentPath: Path of the active PDF document
 * @pageIndex: Zero-based page index
 * @annotationBounds: Bounds of the source annotation
 * @rawText: Raw note text from PDFKit
 * @authorName: Optional annotation author
 */
struct AnnotationRenderSelection {}

/**
 * RenderPipelineServing - Shared rendering contract
 *
 * Converts render content into a final HTML document and warnings list.
 */
protocol RenderPipelineServing {}

/**
 * RenderPipeline - Markdown and math rendering implementation
 *
 * Converts Markdown to HTML, extracts inline/block math, renders math through
 * MathJaxSwift, and produces the final HTML document consumed by RenderView.
 */
final class RenderPipeline: RenderPipelineServing {}
```

## State Management
- `RenderPipeline` is effectively stateless from the caller's perspective.
- A private `MathExpressionRenderer` caches `MathJaxSwift` initialization result
  so repeated renders do not reinitialize the math engine.
- Rendering is asynchronous because math conversion is performed with async
  `MathJaxSwift` APIs.

## Integration Points
- `AnnotationPreviewPanel` in `src/macos/notes-panel.swift` calls
  `RenderPipeline.render(_:)` whenever the active annotation selection changes.
- `RenderView` in `src/macos/render/render-view.swift` consumes the resulting
  `RenderResult.html`.
- `PDFKitView` in `src/macos/pdf-viewer.swift` produces
  `AnnotationRenderSelection` values that become `RenderContent` input.

## Behavior Notes
- Markdown rendering uses `AttributedString(markdown:)` and exports the result
  as HTML.
- Inline math `$...$`, block math `$$...$$`, and fenced ```math blocks are
  extracted before Markdown conversion so the math source survives intact.
- Unterminated math/code fences degrade to normal Markdown with a warning
  instead of failing the entire preview.
- Raw HTML input is sanitized by stripping `<script>` tags unless the caller
  explicitly marks it as trusted.

## Usage Examples
```swift
let pipeline = RenderPipeline()
let result = await pipeline.render(
    RenderContent(
        source: "Euler: $e^{i\\pi} + 1 = 0$",
        format: .markdown
    )
)
```
