import Foundation
import PDFKit

actor LocalPaperSearchService: LocalPaperSearching {
    private let fileManager: FileManager
    private var cache: [String: LocalPaperMatch?] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func findExactTitleMatch(normalizedTitle: String) async -> LocalPaperMatch? {
        guard !normalizedTitle.isEmpty else { return nil }
        if let cached = cache[normalizedTitle] {
            return cached
        }

        for root in searchRoots() {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .nameKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            while let nextObject = enumerator.nextObject() {
                guard let fileURL = nextObject as? URL else { continue }
                guard fileURL.pathExtension.lowercased() == "pdf" else { continue }
                if let match = matchForCandidate(at: fileURL, normalizedTitle: normalizedTitle) {
                    cache[normalizedTitle] = match
                    return match
                }
            }
        }

        cache[normalizedTitle] = nil
        return nil
    }

    private func searchRoots() -> [URL] {
        guard let homeDirectory = fileManager.homeDirectoryForCurrentUser as URL? else {
            return []
        }

        let candidates = [
            homeDirectory.appendingPathComponent("Documents"),
            homeDirectory.appendingPathComponent("Downloads"),
            homeDirectory.appendingPathComponent("Desktop")
        ]
        return candidates.filter { fileManager.fileExists(atPath: $0.path) }
    }

    private func matchForCandidate(at fileURL: URL, normalizedTitle: String) -> LocalPaperMatch? {
        let filenameTitle = CitationTitleNormalizer.normalize(fileURL.deletingPathExtension().lastPathComponent)
        if filenameTitle == normalizedTitle {
            return LocalPaperMatch(title: fileURL.deletingPathExtension().lastPathComponent, fileURL: fileURL)
        }

        guard let document = PDFDocument(url: fileURL),
              let attributes = document.documentAttributes,
              let title = attributes[PDFDocumentAttribute.titleAttribute] as? String
        else {
            return nil
        }

        let normalizedDocumentTitle = CitationTitleNormalizer.normalize(title)
        guard normalizedDocumentTitle == normalizedTitle else { return nil }
        return LocalPaperMatch(title: title, fileURL: fileURL)
    }
}
