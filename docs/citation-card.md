# Citation Card Component Documentation

## Overview
The citation card component presents metadata and actions for a clicked
citation-like link inside the PDF viewer. It loads paper metadata
asynchronously, shows title/authors/abstract, allows abstract expansion,
supports browser handoff for Google Scholar and provider pages, performs
local-PDF-first opening, and exposes a local citation export sheet with several
downloadable formats.

## Public API
```swift
/**
 * CitationCardSheet - Citation details modal for a clicked PDF citation
 * @selection: Citation selection captured from PDFKit
 * @metadataProvider: Metadata lookup service
 * @localPaperSearch: Exact-title local PDF search service
 * @exporter: Citation export generator
 * @onOpenLocalPDF: Callback used when a local PDF match should replace the
 * current open document
 * @onSeeInReferences: Callback used to jump to the original internal PDF
 * reference destination
 *
 * Loads citation metadata, renders the details sheet, and routes actions for
 * Save, Cite, Cited by, Related articles, PDF, and See in references.
 *
 * Return: SwiftUI View
 */
struct CitationCardSheet: View {}

/**
 * CitationStylesSheet - Download/export sheet for generated citation formats
 * @metadata: Resolved paper metadata
 * @styles: Generated citation style bundle
 *
 * Displays rendered styles and save actions for BibTeX, EndNote, RefMan, and
 * RefWorks outputs.
 *
 * Return: SwiftUI View
 */
struct CitationStylesSheet: View {}
```

## State Management
- `CitationCardSheet` owns loading, error, metadata, local-paper-match, export
  bundle, abstract expansion, and cite-sheet presentation state.
- The sheet resets its state when the `CitationLinkSelection.id` changes.
- Metadata and local PDF search are loaded in sequence so the card can render
  the title quickly and then refine the `PDF` action if a local match is found.
- `CitationStylesSheet` is stateless apart from save-panel interactions.

## Integration Points
- `CitationCardSheet` depends on:
  - `CitationMetadataProviding`
  - `LocalPaperSearching`
  - `CitationExporting`
- `onOpenLocalPDF` is supplied by `AppShellView` and reuses the shell's normal
  PDF-open flow so session association behavior stays consistent.
- `onSeeInReferences` is supplied by `AppShellView` and posts the exact
  destination jump back to the PDF viewer.
- Browser handoff uses `NSWorkspace.shared.open`.
- Export actions use `NSSavePanel` and write UTF-8 text files locally.

## Behavior Notes
- `Save` opens Google Scholar search/results in the browser rather than trying
  to automate Scholar's private save UI.
- `Cited by` and `Related articles` use provider/search URLs derived from the
  resolved metadata, not private Google Scholar endpoints.
- `PDF` prefers a matched local PDF first, then falls back to open-access PDF
  URLs, then to a landing/search page.
- `Cite` shows generated static citation styles and file downloads rather than
  provider-hosted citation dialogs.

## Usage Example
```swift
CitationCardSheet(
    selection: selection,
    metadataProvider: citationMetadataProvider,
    localPaperSearch: localPaperSearch,
    exporter: citationExporter,
    onOpenLocalPDF: openCitationLocalPDF,
    onSeeInReferences: showCitationInReferences
)
```
