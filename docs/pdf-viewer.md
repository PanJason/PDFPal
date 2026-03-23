# PDF Viewer Component Documentation

## Overview
The PDF Viewer component hosts a native PDFKit view inside SwiftUI. It handles
loading a local PDF file, shows an empty or error state when appropriate, and
adds context menu actions for Ask LLM and PDF annotations. It supports
highlighting selections with color, underlining, strikethrough, editing
annotation notes from a right-click menu on existing annotations, and
publishing the currently selected/opened note-bearing annotation into the
annotation preview pipeline. It also intercepts individually clickable citation
links, preserves their original PDF destinations, extracts reference context
from the bibliography target, and reports citation selections back to the app
shell for citation-card presentation.

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
 * @onAnnotationSelectionChanged: Callback invoked when the user selects or opens
 * a note-bearing PDF annotation
 * @onCitationSelectionChanged: Callback invoked when the user clicks a
 * citation-like PDF link annotation
 * @searchQuery: Current toolbar query text
 * @searchMode: Current toolbar search mode
 * @sidebarMode: Current selected left sidebar mode
 *
 * Displays a PDF with auto-scaling, shows empty/error states, routes the
 * current selection to the app shell when Ask LLM is chosen, and reports the
 * currently selected/opened annotation note for rendering. Citation link clicks
 * are intercepted before PDFKit navigates them so the app can show a citation
 * card while still preserving exact "See in references" behavior.
 *
 * Return: SwiftUI View
 */
struct PDFViewer: View {}

/**
 * PDFKitContainer - NSViewRepresentable wrapper around PDFKitView
 * @document: PDFDocument instance to render
 * @onAskLLM: Callback invoked for Ask LLM menu action
 * @onAnnotationSelectionChanged: Callback invoked for annotation note preview
 * @onCitationSelectionChanged: Callback invoked for citation card selection
 * @searchQuery: Query string to search in the loaded document
 * @searchMode: Match mode for the query
 */
struct PDFKitContainer: NSViewRepresentable {}

/**
 * PDFKitView - PDFView subclass that augments the context menu
 * @onAskLLM: Closure called with the current selection text
 * @onAnnotationSelectionChanged: Closure called with the resolved note-bearing
 * annotation selection to preview
 * @onCitationSelectionChanged: Closure called with the resolved citation-link
 * selection for card presentation
 *
 * Adds:
 * - "Annotate Selection" submenu (highlight colors, underline, strikethrough)
 * - "Remove Highlight/Underline/Strikethrough" on annotation right-click
 * - "Add/Edit Note..." and "Remove Note" on annotation right-click
 * - "Ask LLM" on current text selection
 * - annotation note preview publishing for note markers, grouped markup notes,
 *   and note entries selected from the highlights sidebar
 * - citation-link interception for individually clickable PDF link annotations
 * - exact reference jumping through Notification.Name.pdfGoToCitationDestination
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
- `PDFKitView` also resolves the currently selected/opened annotation note into
  an `AnnotationRenderSelection` so the app shell can render it in the preview
  panel.
- `PDFKitView` also resolves clicked citation link annotations into
  `CitationLinkSelection` values, including the source page/bounds, the exact
  original PDF destination, and reference text extracted near the destination.

## Integration Points
- The `onAskLLM` callback is wired to `AppShellView` to open the chat panel.
- The `onAnnotationSelectionChanged` callback is wired to `AppShellView` to
  update the right-side annotation preview panel.
- The `onCitationSelectionChanged` callback is wired to `AppShellView` to open
  the citation details sheet.
- The file URL is provided by the file importer in the app shell.
- Toolbar highlight actions post a `PDFAnnotationAction` notification that the
  active PDF view applies to the current selection.
- File menu save (`Cmd+S`) posts `pdfSaveDocument`; the PDF view persists all
  annotation and note edits to disk.
- App shell search state (`searchQuery`, `searchMode`) is passed to
  `PDFKitView`, which executes synchronous document search via PDFKit.
- App shell sidebar state (`sidebarMode`) is passed to `PDFReaderContainerView`
  to switch between hidden/thumbnails/table-of-contents/highlights/bookmarks.
- Clicking an entry in the `Highlights and Notes` sidebar also publishes its
  resolved note text to the preview pipeline when a note exists.
- `Notification.Name.pdfGoToCitationDestination` is consumed by `PDFKitView` to
  jump back to the exact reference destination captured from the original
  citation link click.

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
  whole highlight cluster, including note-marker, popup-backed, and persisted
  highlight-comment note content that PDFKit may attach to only one line of the
  group.
- The sidebar refreshes when highlights, underlines, strikethroughs, colors, or
  note content change while the mode is visible.

## Note Persistence Behavior
- The app uses a split note model:
  saved PDF note text is persisted on the anchor markup annotation's
  `contents`, while the visible note icon shown inside this app is rebuilt as a
  local text-note marker during normalization.
- This avoids writing a standalone text-note annotation for app-authored notes,
  which Preview would otherwise treat as a second unattached note.
- On save, synthetic note markers and transient popup remnants are removed from
  the written PDF. The single persisted source of truth is the anchor
  highlight/underline/strike annotation's `contents`.
- On load, if a markup annotation already carries note text in `contents`, the
  viewer recreates one local note marker so in-app note affordances remain
  visible.
- Preview-authored notes are also adopted into this model. If a native Preview
  popup is attached to a markup annotation, the viewer copies that note text
  onto the markup annotation, clears the native popup linkage, and keeps only
  one local note marker in-app so duplicate icons are suppressed.

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
  popup, persisted markup comment, and sidebar note state for the whole grouped
  highlight.
- Clicking directly on a note marker or markup annotation in the PDF view
  publishes the corresponding note text to the preview panel when note content
  exists.

## Citation Link Behavior
- Citation handling only activates for PDF link annotations whose visible label
  looks like a citation (`et al.`, year-based labels, numeric bracket labels,
  or parenthetical author-year labels).
- Adjacent link fragments that share the same destination are clustered before
  label extraction so split author/year links like `Luo et al., 2025` behave as
  a single clickable citation.
- Suffix-only fragments can inherit author/year context from surrounding text so
  labels like `Du et al., 2025b,a` can resolve `2025b` and `2025a` separately.
- Internal `PDFActionGoTo` and destination-backed link annotations are captured
  as citation selections rather than being navigated immediately.
- The original destination page and point are preserved so the app can later
  execute an exact `See in references` jump.
- Reference context is extracted by scanning nearby bibliography lines around
  the destination point, then selecting the best-matching entry for the clicked
  citation label instead of taking a raw rectangular text slice.
- Non-citation links continue to fall through to normal PDFKit behavior.

## Known Issues / TODO
- `Thumbnails` mode intentionally favors visual stability over live-resize
  responsiveness. While dragging the divider, thumbnails may hold their previous
  geometry until the resize settles, then snap to the final size.
- `Bookmarks` mode is marked **TODO** and currently only shows a placeholder.

## Usage Examples
```swift
HSplitView {
    PDFViewer(
        fileURL: fileURL,
        onAskLLM: handleAskLLM,
        onAnnotationSelectionChanged: handleAnnotationSelectionChanged,
        onCitationSelectionChanged: handleCitationSelectionChanged,
        searchQuery: searchQuery,
        searchMode: searchMode,
        sidebarMode: selectedPDFSidebarMode
    )
    ChatPanel(selectionText: selectionText, onClose: closeChat)
}
```
