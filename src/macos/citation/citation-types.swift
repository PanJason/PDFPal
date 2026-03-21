import CoreGraphics
import Foundation

enum CitationLinkKind: String {
    case internalReference
    case externalURL
}

struct CitationLinkSelection: Equatable, Identifiable {
    let documentPath: String
    let sourcePageIndex: Int
    let sourceBounds: CGRect
    let labelText: String
    let linkKind: CitationLinkKind
    let destinationPageIndex: Int?
    let destinationPoint: CGPoint?
    let externalURL: URL?
    let referenceText: String?

    var id: String {
        [
            documentPath,
            String(sourcePageIndex),
            labelText,
            String(destinationPageIndex ?? -1)
        ].joined(separator: "|")
    }
}

struct CitationAuthor: Codable, Equatable, Identifiable {
    let displayName: String

    var id: String { displayName }
}

struct CitationMetadata: Codable, Equatable {
    let title: String
    let authors: [CitationAuthor]
    let abstractText: String?
    let year: Int?
    let venue: String?
    let citationCount: Int?
    let citedByURL: URL?
    let relatedArticlesURL: URL?
    let googleScholarURL: URL?
    let providerLandingURL: URL?
    let openAccessPDFURL: URL?
    let doi: String?
    let arxivID: String?
}

struct CitationLookupKey: Codable, Equatable, Hashable {
    let normalizedTitle: String
    let doi: String?
    let arxivID: String?
}

struct LocalPaperMatch: Equatable {
    let title: String
    let fileURL: URL
}

struct CitationStyleBundle: Equatable {
    let mla: String
    let apa: String
    let chicago: String
    let harvard: String
    let vancouver: String
    let bibTeX: String
    let endNote: String
    let refManRIS: String
    let refWorksRIS: String
}

struct CitationPreviewState: Equatable {
    let selection: CitationLinkSelection
    let metadata: CitationMetadata?
    let localMatch: LocalPaperMatch?
    let styles: CitationStyleBundle?
    let isLoading: Bool
    let errorMessage: String?
}

typealias CitationSelectionHandler = (CitationLinkSelection?) -> Void

protocol CitationMetadataProviding {
    func fetchMetadata(for selection: CitationLinkSelection) async throws -> CitationMetadata
}

protocol LocalPaperSearching {
    func findExactTitleMatch(normalizedTitle: String) async -> LocalPaperMatch?
}

protocol CitationExporting {
    func makeStyleBundle(from metadata: CitationMetadata) -> CitationStyleBundle
}

enum CitationTitleNormalizer {
    static func normalize(_ title: String) -> String {
        let lowercased = title.lowercased()
        let replaced = lowercased.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: " ",
            options: .regularExpression
        )
        return replaced
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
