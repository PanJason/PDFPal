# PDF Viewer Component Documentation

## Overview
The PDF Viewer component hosts a native PDFKit view inside SwiftUI. It handles
loading a local PDF file, shows an empty or error state when appropriate, and
adds context menu actions for Ask LLM and PDF annotations. It supports
highlighting selections with color, underlining, strikethrough, and editing
annotation notes from a right-click menu on existing annotations. Existing
annotations can also be removed, and existing notes can be removed directly.

## Public API
```swift
/**
 * PDFAnnotationAction - Commands to apply PDF markup in the active PDF view
 *
 * Supported actions include color highlights, underline, and strikethrough.
 */
enum PDFAnnotationAction {}

/**
 * PDFSearchMode - Search matching mode for PDF text search
 *
 * anyMatch splits query into terms and finds results for any term.
 * exactPhrase finds literal phrase matches for the full query.
 */
enum PDFSearchMode {}

/**
 * PDFSidebarMode - Left sidebar mode for the PDF viewer
 *
 * Supported modes:
 * - hidden
 * - thumbnails
 * - tableOfContents
 * - highlightsAndNotes
 * - bookmarks (marked TODO placeholder)
 */
enum PDFSidebarMode {}

/**
 * PDFViewer - SwiftUI wrapper for PDFKit rendering
 * @fileURL: Optional file URL for the PDF to display
 * @onAskLLM: Callback invoked when the user selects Ask LLM from the context menu
 * @searchQuery: Current toolbar query text
 * @searchMode: Current toolbar search mode
 * @sidebarMode: Current selected left sidebar mode
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
 * @searchQuery: Query string to search in the loaded document
 * @searchMode: Match mode for the query
 */
struct PDFKitContainer: NSViewRepresentable {}

/**
 * PDFKitView - PDFView subclass that augments the context menu
 * @onAskLLM: Closure called with the current selection text
 *
 * Adds:
 * - "Annotate Selection" submenu (highlight colors, underline, strikethrough)
 * - "Remove Highlight/Underline/Strikethrough" on annotation right-click
 * - "Add/Edit Note..." and "Remove Note" on annotation right-click
 * - "Ask LLM" on current text selection
 * - toolbar-driven PDF search for Any Match and Exact Phrase
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
- `PDFKitView` caches the last search signature and re-runs search only when
  document/query/mode change.

## Integration Points
- The `onAskLLM` callback is wired to `AppShellView` to open the chat panel.
- The file URL is provided by the file importer in the app shell.
- Toolbar highlight actions post a `PDFAnnotationAction` notification that the
  active PDF view applies to the current selection.
- File menu save (`Cmd+S`) posts `pdfSaveDocument`; the PDF view persists all
  annotation and note edits to disk.
- App shell search state (`searchQuery`, `searchMode`) is passed to
  `PDFKitView`, which executes synchronous document search via PDFKit.
- App shell sidebar state (`sidebarMode`) is passed to `PDFReaderContainerView`
  to switch between hidden/thumbnails/table-of-contents/highlights/bookmarks.
- Search mode behavior:
  - `Any Match`: query is tokenized by whitespace and matches any token.
  - `Exact Phrase`: query is matched as one phrase.
- All matched search results are highlighted in yellow.
- Initial search focus jumps to the nearest match to the currently visible page
  (and current viewport anchor on that page).
- Search navigation behavior:
  - `Enter`: move focus to next match.
  - `Shift+Enter`: move focus to previous match.

## Thumbnail Sidebar Behavior
- `Thumbnails` mode is implemented with `PDFThumbnailView`, which is sensitive to
  startup layout timing and continuous live-resize updates.
- The thumbnail view is only bound after the sidebar has a valid window-attached
  size. This avoids blank startup renders caused by transient zero-width or
  oversized layout values during initial AppKit attachment.
- During sidebar resizing, the app does not continuously rebuild thumbnail cells
  on every intermediate width change.
- Instead, resize-driven thumbnail refresh is deferred until the sidebar width
  settles. This is an intentional design choice to avoid transient PDFKit cell
  reuse artifacts such as wrong-page images flashing in the wrong slot while the
  divider is moving.
- After resizing stops, the thumbnail grid is refreshed once using the final
  settled sidebar width.

## Highlights Sidebar Behavior
- `Highlights and Notes` mode renders annotation cards styled after Preview's
  notes list rather than a plain text list.
- Each card shows the page label, optional author name, a left accent bar using
  the annotation color, up to three lines of extracted highlighted text, and up
  to three lines of note text when a note exists.
- Note badges reuse the annotation accent color and switch text color for
  contrast based on the underlying annotation color.
- Grouped multi-line markup is collapsed into a single sidebar entry so one
  logical highlight does not appear as several rows.
- For grouped multi-line highlights, sidebar note text is resolved across the
  whole highlight cluster, including note-marker and popup-backed note content
  that PDFKit may attach to only one line of the group.
- The sidebar refreshes when highlights, underlines, strikethroughs, colors, or
  note content change while the mode is visible.

## Context Menu Markup Picker
- The annotation context menu keeps a compact first-row markup picker for
  highlight colors, underline, and strikethrough.
- The picker is implemented as a custom menu view so the app can keep the
  compact control layout while routing each click through app-owned handlers.
- Clicking a color on existing highlight markup updates that markup color.
- Clicking underline or strikethrough on existing markup toggles the matching
  overlay annotation.
- When no existing markup is under the context click, the same controls apply
  the requested annotation style to the current text selection.
- Note editing still uses PDFKit's native add-note UI.
- For grouped multi-line highlights, note presence is resolved at the highlight
  cluster level. If any line in the group has a note, right-clicking any line in
  that group exposes `Remove Note` rather than `Add Note`.
- Removing a note from a grouped highlight clears the related note marker,
  popup, and sidebar note state for the whole grouped highlight.

## Known Issues / TODO
- `Thumbnails` mode intentionally favors visual stability over live-resize
  responsiveness. While dragging the divider, thumbnails may hold their previous
  geometry until the resize settles, then snap to the final size.
- `Bookmarks` mode is marked **TODO** and currently only shows a placeholder.

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
