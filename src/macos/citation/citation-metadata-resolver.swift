import Foundation

enum CitationMetadataResolverError: LocalizedError {
    case unableToBuildQuery
    case notFound

    var errorDescription: String? {
        switch self {
        case .unableToBuildQuery:
            return "Could not derive a lookup query from the clicked citation."
        case .notFound:
            return "No matching paper metadata was found."
        }
    }
}

actor CitationMetadataResolver: CitationMetadataProviding {
    private let session: URLSession
    private var cache: [CitationLookupKey: CitationMetadata] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchMetadata(for selection: CitationLinkSelection) async throws -> CitationMetadata {
        let candidate = CitationQueryCandidate(selection: selection)
        guard !candidate.searchQueries.isEmpty || candidate.doi != nil || candidate.arxivID != nil else {
            throw CitationMetadataResolverError.unableToBuildQuery
        }

        let cacheKey = CitationLookupKey(
            normalizedTitle: candidate.normalizedTitle,
            doi: candidate.doi,
            arxivID: candidate.arxivID
        )
        if let cached = cache[cacheKey] {
            return cached
        }

        if let doi = candidate.doi,
           let metadata = try await fetchSemanticScholar(identifier: "DOI:\(doi)") {
            cache[cacheKey] = metadata
            return metadata
        }

        if let arxivID = candidate.arxivID,
           let metadata = try await fetchSemanticScholar(identifier: "ARXIV:\(arxivID)") {
            cache[cacheKey] = metadata
            return metadata
        }

        for query in candidate.searchQueries {
            if let metadata = try await searchSemanticScholar(query: query) {
                cache[cacheKey] = metadata
                return metadata
            }
        }

        for query in candidate.searchQueries {
            if let metadata = try await searchOpenAlex(query: query) {
                cache[cacheKey] = metadata
                return metadata
            }
        }

        throw CitationMetadataResolverError.notFound
    }

    private func fetchSemanticScholar(identifier: String) async throws -> CitationMetadata? {
        var components = URLComponents(string: "https://api.semanticscholar.org/graph/v1/paper/\(identifier)")
        components?.queryItems = [
            URLQueryItem(name: "fields", value: SemanticScholarPaperResponse.requestedFields)
        ]
        guard let url = components?.url else {
            return nil
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }

        let paper = try JSONDecoder().decode(SemanticScholarPaperResponse.self, from: data)
        return paper.toMetadata()
    }

    private func searchSemanticScholar(query: String) async throws -> CitationMetadata? {
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.semanticscholar.org/graph/v1/paper/search")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "fields", value: SemanticScholarPaperResponse.requestedFields)
        ]
        guard let url = components?.url else {
            return nil
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }

        let searchResponse = try JSONDecoder().decode(SemanticScholarSearchResponse.self, from: data)
        return searchResponse.data
            .compactMap { $0.toMetadata() }
            .first
    }

    private func searchOpenAlex(query: String) async throws -> CitationMetadata? {
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.openalex.org/works")
        components?.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "per-page", value: "3")
        ]
        guard let url = components?.url else {
            return nil
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }

        let searchResponse = try JSONDecoder().decode(OpenAlexSearchResponse.self, from: data)
        return searchResponse.results
            .compactMap { $0.toMetadata() }
            .first
    }
}

private struct CitationQueryCandidate {
    let rawReference: String
    let normalizedTitle: String
    let doi: String?
    let arxivID: String?
    let searchQueries: [String]

    init(selection: CitationLinkSelection) {
        let reference = CitationQueryCandidate.cleanReference(selection.referenceText ?? selection.labelText)
        rawReference = reference

        let doiMatch = CitationQueryCandidate.firstMatch(
            pattern: #"10\.\d{4,9}/[-._;()/:A-Z0-9]+"#,
            in: reference,
            options: [.caseInsensitive]
        )
        let arxivMatch = CitationQueryCandidate.firstMatch(
            pattern: #"arxiv[:\s]*([0-9]{4}\.[0-9]{4,5}|[a-z\-]+/[0-9]{7})"#,
            in: reference,
            options: [.caseInsensitive],
            captureGroup: 1
        )

        doi = doiMatch?.trimmingCharacters(in: CharacterSet(charactersIn: " .;,"))
        arxivID = arxivMatch?.trimmingCharacters(in: CharacterSet(charactersIn: " .;,"))

        let titleCandidate =
            CitationQueryCandidate.extractQuotedTitle(from: reference)
            ?? CitationQueryCandidate.extractTitleFollowingYear(from: reference)
            ?? CitationQueryCandidate.extractSentenceLikeTitle(from: reference)
            ?? selection.labelText

        normalizedTitle = CitationTitleNormalizer.normalize(titleCandidate)

        var queries: [String] = []
        for item in [titleCandidate, reference, selection.labelText] {
            let normalized = CitationQueryCandidate.cleanReference(item)
            guard !normalized.isEmpty else { continue }
            if !queries.contains(normalized) {
                queries.append(normalized)
            }
        }
        searchQueries = queries
    }

    fileprivate static func cleanReference(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func extractQuotedTitle(from reference: String) -> String? {
        firstMatch(pattern: #"[\"“](.+?)[\"”]"#, in: reference, captureGroup: 1)
    }

    fileprivate static func extractTitleFollowingYear(from reference: String) -> String? {
        guard let yearRange = reference.range(
            of: #"(19|20)\d{2}[a-z]?"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let suffix = reference[yearRange.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,:;()[]"))

        guard let sentence = suffix.split(separator: ".").first else {
            return nil
        }
        let title = cleanReference(String(sentence))
        return title.isEmpty ? nil : title
    }

    fileprivate static func extractSentenceLikeTitle(from reference: String) -> String? {
        let sentences = reference
            .split(separator: ".")
            .map { cleanReference(String($0)) }
            .filter { !$0.isEmpty }

        for sentence in sentences {
            guard sentence.count > 16 else { continue }
            let lowercased = sentence.lowercased()
            if lowercased.contains("et al") || lowercased.contains("doi") {
                continue
            }
            return sentence
        }
        return nil
    }

    fileprivate static func firstMatch(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [],
        captureGroup: Int = 0
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              captureGroup < match.numberOfRanges,
              let matchRange = Range(match.range(at: captureGroup), in: text) else {
            return nil
        }
        return String(text[matchRange])
    }
}

private struct SemanticScholarSearchResponse: Decodable {
    let data: [SemanticScholarPaperResponse]
}

private struct SemanticScholarPaperResponse: Decodable {
    struct Author: Decodable {
        let name: String
    }

    struct OpenAccessPDF: Decodable {
        let url: String?
    }

    struct ExternalIds: Decodable {
        let doi: String?
        let arxiv: String?

        enum CodingKeys: String, CodingKey {
            case doi = "DOI"
            case arxiv = "ArXiv"
        }
    }

    static let requestedFields = "title,abstract,authors,citationCount,venue,year,url,openAccessPdf,externalIds"

    let title: String
    let abstract: String?
    let authors: [Author]?
    let citationCount: Int?
    let venue: String?
    let year: Int?
    let url: String?
    let openAccessPdf: OpenAccessPDF?
    let externalIds: ExternalIds?

    func toMetadata() -> CitationMetadata? {
        let normalizedTitle = CitationQueryCandidate.cleanReference(title)
        guard !normalizedTitle.isEmpty else { return nil }

        let providerLandingURL = url.flatMap(URL.init(string:))
        let titleQuery = CitationQueryCandidate.cleanReference(title)
        let googleScholarURL = URL(string: "https://scholar.google.com/scholar?q=\(titleQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        let semanticScholarSearchURL = URL(string: "https://www.semanticscholar.org/search?q=\(titleQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")

        return CitationMetadata(
            title: title,
            authors: (authors ?? []).map { CitationAuthor(displayName: $0.name) },
            abstractText: abstract,
            year: year,
            venue: venue,
            citationCount: citationCount,
            citedByURL: providerLandingURL,
            relatedArticlesURL: semanticScholarSearchURL,
            googleScholarURL: googleScholarURL,
            providerLandingURL: providerLandingURL,
            openAccessPDFURL: openAccessPdf?.url.flatMap(URL.init(string:)),
            doi: externalIds?.doi,
            arxivID: externalIds?.arxiv
        )
    }
}

private struct OpenAlexSearchResponse: Decodable {
    let results: [OpenAlexWork]
}

private struct OpenAlexWork: Decodable {
    struct Authorship: Decodable {
        struct Author: Decodable {
            let displayName: String

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }

        let author: Author
    }

    struct PrimaryLocation: Decodable {
        let landingPageURL: String?
        let pdfURL: String?

        enum CodingKeys: String, CodingKey {
            case landingPageURL = "landing_page_url"
            case pdfURL = "pdf_url"
        }
    }

    struct IDs: Decodable {
        let doi: String?
        let openAlex: String?
    }

    let title: String
    let authorships: [Authorship]?
    let abstractInvertedIndex: [String: [Int]]?
    let publicationYear: Int?
    let citedByCount: Int?
    let primaryLocation: PrimaryLocation?
    let ids: IDs?
    let doi: String?

    enum CodingKeys: String, CodingKey {
        case title
        case authorships
        case abstractInvertedIndex = "abstract_inverted_index"
        case publicationYear = "publication_year"
        case citedByCount = "cited_by_count"
        case primaryLocation = "primary_location"
        case ids
        case doi
    }

    func toMetadata() -> CitationMetadata? {
        let normalizedTitle = CitationQueryCandidate.cleanReference(title)
        guard !normalizedTitle.isEmpty else { return nil }

        let titleQuery = CitationQueryCandidate.cleanReference(title)
        let encodedTitle = titleQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let landingURL = primaryLocation?.landingPageURL.flatMap(URL.init(string:))
            ?? ids?.openAlex.flatMap(URL.init(string:))

        return CitationMetadata(
            title: title,
            authors: (authorships ?? []).map { CitationAuthor(displayName: $0.author.displayName) },
            abstractText: reconstructAbstract(from: abstractInvertedIndex),
            year: publicationYear,
            venue: nil,
            citationCount: citedByCount,
            citedByURL: landingURL,
            relatedArticlesURL: URL(string: "https://www.semanticscholar.org/search?q=\(encodedTitle)"),
            googleScholarURL: URL(string: "https://scholar.google.com/scholar?q=\(encodedTitle)"),
            providerLandingURL: landingURL,
            openAccessPDFURL: primaryLocation?.pdfURL.flatMap(URL.init(string:)),
            doi: doi ?? ids?.doi,
            arxivID: nil
        )
    }

    private func reconstructAbstract(from invertedIndex: [String: [Int]]?) -> String? {
        guard let invertedIndex, !invertedIndex.isEmpty else { return nil }
        let size = (invertedIndex.values.flatMap { $0 }.max() ?? -1) + 1
        guard size > 0 else { return nil }

        var tokens = Array(repeating: "", count: size)
        for (word, indices) in invertedIndex {
            for index in indices where index < tokens.count {
                tokens[index] = word
            }
        }
        let abstract = tokens.joined(separator: " ")
        let normalized = abstract.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
