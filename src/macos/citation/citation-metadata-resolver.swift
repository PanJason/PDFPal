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
            if let metadata = try await searchSemanticScholar(query: query, candidate: candidate) {
                cache[cacheKey] = metadata
                return metadata
            }
        }

        for query in candidate.searchQueries {
            if let metadata = try await searchOpenAlex(query: query, candidate: candidate) {
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

    private func searchSemanticScholar(
        query: String,
        candidate: CitationQueryCandidate
    ) async throws -> CitationMetadata? {
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.semanticscholar.org/graph/v1/paper/search")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "10"),
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
        return bestMetadataMatch(
            from: searchResponse.data.compactMap { $0.toMetadata() },
            candidate: candidate
        )
    }

    private func searchOpenAlex(
        query: String,
        candidate: CitationQueryCandidate
    ) async throws -> CitationMetadata? {
        guard !query.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.openalex.org/works")
        components?.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "per-page", value: "10")
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
        return bestMetadataMatch(
            from: searchResponse.results.compactMap { $0.toMetadata() },
            candidate: candidate
        )
    }

    private func bestMetadataMatch(
        from results: [CitationMetadata],
        candidate: CitationQueryCandidate
    ) -> CitationMetadata? {
        var bestResult: CitationMetadata?
        var bestScore = Int.min

        for result in results {
            let score = metadataMatchScore(result, candidate: candidate)
            if score > bestScore {
                bestScore = score
                bestResult = result
            }
        }

        return bestScore > 0 ? bestResult : nil
    }

    private func metadataMatchScore(
        _ metadata: CitationMetadata,
        candidate: CitationQueryCandidate
    ) -> Int {
        let normalizedResultTitle = CitationTitleNormalizer.normalize(metadata.title)
        let normalizedCandidateTitle = candidate.normalizedTitle
        let compactCandidateTitle = candidate.titleCandidate

        var score = 0

        if !normalizedCandidateTitle.isEmpty {
            if normalizedResultTitle == normalizedCandidateTitle {
                score += 30
            } else if normalizedResultTitle.contains(normalizedCandidateTitle)
                        || normalizedCandidateTitle.contains(normalizedResultTitle) {
                score += 18
            } else if !compactCandidateTitle.isEmpty {
                let candidateTerms = Set(normalizedCandidateTitle.split(separator: " ").map(String.init))
                let resultTerms = Set(normalizedResultTitle.split(separator: " ").map(String.init))
                let overlap = candidateTerms.intersection(resultTerms).count
                if overlap >= min(5, candidateTerms.count) {
                    score += overlap * 2
                } else {
                    score -= 8
                }
            }
        }

        if let authorToken = candidate.authorToken {
            if metadata.authors.contains(where: {
                CitationTitleNormalizer.normalize($0.displayName).contains(authorToken)
            }) {
                score += 8
            } else {
                score -= 5
            }
        }

        if let yearToken = candidate.yearToken {
            let baseYear = String(yearToken.prefix(4))
            if let year = metadata.year {
                if String(year).lowercased() == yearToken {
                    score += 8
                } else if String(year) == baseYear {
                    score += 5
                } else {
                    score -= 4
                }
            } else {
                score -= 2
            }
        }

        if let doi = candidate.doi, metadata.doi?.caseInsensitiveCompare(doi) == .orderedSame {
            score += 20
        }

        if let arxivID = candidate.arxivID,
           metadata.arxivID?.localizedCaseInsensitiveContains(arxivID) == true {
            score += 20
        }

        return score
    }
}

private struct CitationQueryCandidate {
    let rawReference: String
    let titleCandidate: String
    let normalizedTitle: String
    let authorToken: String?
    let yearToken: String?
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

        self.titleCandidate = CitationQueryCandidate.cleanReference(titleCandidate)
        normalizedTitle = CitationTitleNormalizer.normalize(titleCandidate)
        authorToken = CitationQueryCandidate.extractAuthorToken(from: selection.labelText)
            ?? CitationQueryCandidate.extractAuthorToken(from: reference)
        yearToken = CitationQueryCandidate.extractYearToken(from: selection.labelText)
            ?? CitationQueryCandidate.extractYearToken(from: reference)

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

    fileprivate static func extractAuthorToken(from text: String) -> String? {
        let cleaned = cleanReference(text)
        let patterns = [
            #"([A-Z][A-Za-z'’\-]+)\s+et al\."#,
            #"([A-Z][A-Za-z'’\-]+)\s+and\s+[A-Z][A-Za-z'’\-]+"#,
            #"^([A-Z][A-Za-z'’\-]+)[,\s]"#
        ]

        for pattern in patterns {
            if let match = firstMatch(
                pattern: pattern,
                in: cleaned,
                options: [.caseInsensitive],
                captureGroup: 1
            ) {
                return match.lowercased()
            }
        }
        return nil
    }

    fileprivate static func extractYearToken(from text: String) -> String? {
        firstMatch(
            pattern: #"((?:19|20)\d{2}[a-z]?)"#,
            in: text,
            options: [.caseInsensitive],
            captureGroup: 1
        )?.lowercased()
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
