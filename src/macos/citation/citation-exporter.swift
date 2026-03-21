import Foundation

struct CitationExportService: CitationExporting {
    func makeStyleBundle(from metadata: CitationMetadata) -> CitationStyleBundle {
        CitationStyleBundle(
            mla: mlaCitation(for: metadata),
            apa: apaCitation(for: metadata),
            chicago: chicagoCitation(for: metadata),
            harvard: harvardCitation(for: metadata),
            vancouver: vancouverCitation(for: metadata),
            bibTeX: bibTeX(for: metadata),
            endNote: endNote(for: metadata),
            refManRIS: ris(for: metadata),
            refWorksRIS: ris(for: metadata)
        )
    }

    private func mlaCitation(for metadata: CitationMetadata) -> String {
        let authors = mlaAuthorList(metadata.authors)
        let year = metadata.year.map(String.init) ?? "n.d."
        let venue = metadata.venue.map { " \($0)." } ?? ""
        return "\(authors) \"\(metadata.title).\"\(venue) \(year).".replacingOccurrences(of: "  ", with: " ")
    }

    private func apaCitation(for metadata: CitationMetadata) -> String {
        let authors = apaAuthorList(metadata.authors)
        let year = metadata.year.map { "(\($0))." } ?? "(n.d.)."
        let venue = metadata.venue.map { " \($0)." } ?? ""
        return "\(authors) \(year) \(metadata.title).\(venue)".replacingOccurrences(of: "  ", with: " ")
    }

    private func chicagoCitation(for metadata: CitationMetadata) -> String {
        let authors = chicagoAuthorList(metadata.authors)
        let year = metadata.year.map(String.init) ?? "n.d."
        let venue = metadata.venue ?? "Unknown venue"
        return "\(authors). \"\(metadata.title).\" \(venue), \(year)."
    }

    private func harvardCitation(for metadata: CitationMetadata) -> String {
        let authors = harvardAuthorList(metadata.authors)
        let year = metadata.year.map(String.init) ?? "n.d."
        let venue = metadata.venue ?? "Unknown venue"
        return "\(authors) \(year), \(metadata.title), \(venue)."
    }

    private func vancouverCitation(for metadata: CitationMetadata) -> String {
        let authors = metadata.authors.prefix(6).map { vancouverName($0.displayName) }.joined(separator: ", ")
        let suffix = metadata.authors.count > 6 ? ", et al." : "."
        let year = metadata.year.map(String.init) ?? "n.d."
        let venue = metadata.venue ?? "Unknown venue"
        return "\(authors)\(suffix) \(metadata.title). \(venue). \(year)."
    }

    private func bibTeX(for metadata: CitationMetadata) -> String {
        let key = bibTeXKey(for: metadata)
        let authorField = metadata.authors.map { bibTeXName($0.displayName) }.joined(separator: " and ")
        let year = metadata.year.map(String.init) ?? "n.d."
        let venueField = metadata.venue ?? "Unknown venue"
        let doiField = metadata.doi ?? ""
        let urlField = metadata.providerLandingURL?.absoluteString ?? metadata.googleScholarURL?.absoluteString ?? ""
        return """
        @article{\(key),
          title = {\(metadata.title)},
          author = {\(authorField)},
          journal = {\(venueField)},
          year = {\(year)},
          doi = {\(doiField)},
          url = {\(urlField)}
        }
        """
    }

    private func endNote(for metadata: CitationMetadata) -> String {
        let year = metadata.year.map(String.init) ?? "n.d."
        let venue = metadata.venue ?? "Unknown venue"
        let authors = metadata.authors.map { "%A \($0.displayName)" }.joined(separator: "\n")
        let url = metadata.providerLandingURL?.absoluteString ?? metadata.googleScholarURL?.absoluteString ?? ""
        return """
        %0 Journal Article
        %T \(metadata.title)
        \(authors)
        %D \(year)
        %J \(venue)
        %R \(metadata.doi ?? "")
        %U \(url)
        """
    }

    private func ris(for metadata: CitationMetadata) -> String {
        let year = metadata.year.map(String.init) ?? "n.d."
        let venue = metadata.venue ?? "Unknown venue"
        let authors = metadata.authors.map { "AU  - \($0.displayName)" }.joined(separator: "\n")
        let url = metadata.providerLandingURL?.absoluteString ?? metadata.googleScholarURL?.absoluteString ?? ""
        return """
        TY  - JOUR
        TI  - \(metadata.title)
        \(authors)
        PY  - \(year)
        JO  - \(venue)
        DO  - \(metadata.doi ?? "")
        UR  - \(url)
        ER  -
        """
    }

    private func mlaAuthorList(_ authors: [CitationAuthor]) -> String {
        guard let first = authors.first else { return "Unknown author." }
        if authors.count == 1 { return "\(invertedName(first.displayName))." }
        if authors.count == 2 {
            return "\(invertedName(first.displayName)) and \(authors[1].displayName)."
        }
        return "\(invertedName(first.displayName)), et al."
    }

    private func apaAuthorList(_ authors: [CitationAuthor]) -> String {
        guard !authors.isEmpty else { return "Unknown author." }
        return authors.map { apaName($0.displayName) }.joined(separator: ", ")
    }

    private func chicagoAuthorList(_ authors: [CitationAuthor]) -> String {
        guard let first = authors.first else { return "Unknown author" }
        if authors.count == 1 { return invertedName(first.displayName) }
        if authors.count == 2 {
            return "\(invertedName(first.displayName)) and \(authors[1].displayName)"
        }
        return "\(invertedName(first.displayName)) et al"
    }

    private func harvardAuthorList(_ authors: [CitationAuthor]) -> String {
        guard let first = authors.first else { return "Unknown author" }
        if authors.count == 1 { return harvardName(first.displayName) }
        if authors.count == 2 { return "\(harvardName(first.displayName)) and \(harvardName(authors[1].displayName))" }
        return "\(harvardName(first.displayName)) et al."
    }

    private func invertedName(_ name: String) -> String {
        let components = name.split(separator: " ")
        guard let family = components.last else { return name }
        let given = components.dropLast().joined(separator: " ")
        if given.isEmpty { return String(family) }
        return "\(family), \(given)"
    }

    private func apaName(_ name: String) -> String {
        let components = name.split(separator: " ")
        guard let family = components.last else { return name }
        let initials = components.dropLast().compactMap { $0.first.map { "\($0)." } }.joined(separator: " ")
        return "\(family), \(initials)"
    }

    private func harvardName(_ name: String) -> String {
        let components = name.split(separator: " ")
        guard let family = components.last else { return name }
        let initials = components.dropLast().compactMap { $0.first.map { "\($0)." } }.joined(separator: "")
        return "\(family), \(initials)"
    }

    private func vancouverName(_ name: String) -> String {
        let components = name.split(separator: " ")
        guard let family = components.last else { return name }
        let initials = components.dropLast().compactMap { $0.first.map(String.init) }.joined()
        return "\(family) \(initials)"
    }

    private func bibTeXName(_ name: String) -> String {
        let components = name.split(separator: " ")
        guard let family = components.last else { return name }
        let given = components.dropLast().joined(separator: " ")
        return given.isEmpty ? String(family) : "\(family), \(given)"
    }

    private func bibTeXKey(for metadata: CitationMetadata) -> String {
        let lead = metadata.authors.first?.displayName
            .split(separator: " ")
            .last
            .map(String.init)?
            .lowercased() ?? "paper"
        let year = metadata.year.map(String.init) ?? "nd"
        let titleToken = CitationTitleNormalizer.normalize(metadata.title)
            .split(separator: " ")
            .first
            .map(String.init) ?? "untitled"
        return "\(lead)\(year)\(titleToken)"
    }
}
