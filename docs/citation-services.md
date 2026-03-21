# Citation Services Documentation

## Overview
The citation services layer contains the shared data structures and non-UI
helpers used by citation-card v1. It defines the PDF-to-app citation selection
contract, metadata resolution against remote scholarly providers, local PDF
discovery by exact normalized title, and citation export generation.

## Public API
```swift
/**
 * CitationLinkSelection - App-level representation of a clicked PDF citation
 * @documentPath: Source PDF path
 * @sourcePageIndex: Page index where the citation link was clicked
 * @sourceBounds: Bounds of the source link annotation
 * @labelText: Visible citation label in the paper body
 * @linkKind: Internal-reference vs external-URL classification
 * @destinationPageIndex: Resolved target bibliography page index, if internal
 * @destinationPoint: Exact PDF destination point, if internal
 * @externalURL: External URL target, if any
 * @referenceText: Extracted context around the bibliography destination
 */
struct CitationLinkSelection: Equatable, Identifiable {}

/**
 * CitationMetadata - Resolved scholarly metadata for a citation target
 * @title: Paper title
 * @authors: Author list
 * @abstractText: Paper abstract when available
 * @year: Publication year
 * @venue: Venue/journal/preprint source when available
 * @citationCount: Provider-reported citation count
 * @citedByURL: Browser URL for cited-by flow
 * @relatedArticlesURL: Browser URL for related-articles flow
 * @googleScholarURL: Browser URL for Google Scholar search/save flow
 * @providerLandingURL: Provider landing page for the paper
 * @openAccessPDFURL: Open-access PDF URL when available
 * @doi: DOI if resolved
 * @arxivID: arXiv identifier if resolved
 */
struct CitationMetadata: Codable, Equatable {}

/**
 * CitationMetadataProviding - Remote metadata resolver contract
 *
 * Resolves a clicked citation selection into paper metadata.
 */
protocol CitationMetadataProviding {
    func fetchMetadata(for selection: CitationLinkSelection) async throws -> CitationMetadata
}

/**
 * LocalPaperSearching - Exact-title local PDF lookup contract
 */
protocol LocalPaperSearching {
    func findExactTitleMatch(normalizedTitle: String) async -> LocalPaperMatch?
}

/**
 * CitationExporting - Citation style/export generation contract
 */
protocol CitationExporting {
    func makeStyleBundle(from metadata: CitationMetadata) -> CitationStyleBundle
}

/**
 * CitationMetadataResolver - Semantic Scholar/OpenAlex metadata resolver
 *
 * Uses DOI/arXiv/title/reference heuristics to fetch paper metadata and caches
 * successful results by normalized lookup key.
 */
actor CitationMetadataResolver: CitationMetadataProviding {}

/**
 * LocalPaperSearchService - Local PDF discovery helper
 *
 * Searches standard user document locations for an exact normalized title
 * match using filename and PDF document metadata title.
 */
actor LocalPaperSearchService: LocalPaperSearching {}

/**
 * CitationExportService - Local citation formatter/export generator
 *
 * Produces human-readable styles plus BibTeX, EndNote, and RIS-compatible
 * outputs from resolved metadata.
 */
struct CitationExportService: CitationExporting {}
```

## Service Responsibilities
- `citation-types.swift`
  - shared domain entities
  - protocol contracts
  - title normalization helper
- `citation-metadata-resolver.swift`
  - DOI/arXiv/reference heuristics
  - Semantic Scholar primary lookup
  - OpenAlex fallback search
  - result ranking by extracted title, author token, year, DOI, and arXiv ID
  - in-memory result cache
- `local-paper-search.swift`
  - standard-folder enumeration
  - normalized exact-title matching
  - PDF metadata title fallback
- `citation-exporter.swift`
  - local style rendering
  - BibTeX generation
  - EndNote `.enw` generation
  - RIS generation for RefMan and RefWorks

## Integration Points
- `PDFKitView` creates `CitationLinkSelection` instances and hands them to
  `AppShellView`.
- `AppShellView` owns long-lived instances of:
  - `CitationMetadataResolver`
  - `LocalPaperSearchService`
  - `CitationExportService`
- `CitationCardSheet` consumes these services to load and present the card.

## Design Constraints
- Google Scholar is treated as a browser destination only, not as an API
  backend.
- Local search is intentionally scoped to `~/Documents`, `~/Downloads`, and
  `~/Desktop` for v1.
- Title matching is exact after normalization; there is no fuzzy matching yet.
- Provider search does not accept the first hit blindly; candidate results are
  scored against the citation text and extracted reference entry before a paper
  is selected.
- Provider/search results are cached only inside the resolver actor and are not
  exposed as a user-facing persistent store.

## Usage Example
```swift
let metadataProvider = CitationMetadataResolver()
let localPaperSearch = LocalPaperSearchService()
let exporter = CitationExportService()
```
