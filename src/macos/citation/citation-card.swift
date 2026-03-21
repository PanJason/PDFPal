import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CitationCardSheet: View {
    let selection: CitationLinkSelection
    let metadataProvider: any CitationMetadataProviding
    let localPaperSearch: any LocalPaperSearching
    let exporter: any CitationExporting
    let onOpenLocalPDF: (URL) -> Void
    let onSeeInReferences: (CitationLinkSelection) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var metadata: CitationMetadata?
    @State private var localMatch: LocalPaperMatch?
    @State private var styles: CitationStyleBundle?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingFullAbstract = false
    @State private var isShowingCiteSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleBlock
                    abstractBlock
                    actionRows
                    if let referenceText = selection.referenceText, !referenceText.isEmpty {
                        referenceBlock(referenceText)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: selection.id) {
            await loadCitation()
        }
        .sheet(isPresented: $isShowingCiteSheet) {
            if let metadata, let styles {
                CitationStylesSheet(
                    metadata: metadata,
                    styles: styles
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selection.labelText)
                    .font(.headline)
                Text("Citation details")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Close") {
                dismiss()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let metadata {
            VStack(alignment: .leading, spacing: 10) {
                Text(metadata.title)
                    .font(.title)
                    .fontWeight(.semibold)
                if !metadata.authors.isEmpty {
                    Text(metadata.authors.map(\.displayName).joined(separator: ", "))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if let venue = metadata.venue, !venue.isEmpty {
                        Text(venue)
                    }
                    if let year = metadata.year {
                        Text(String(year))
                    }
                    if let citationCount = metadata.citationCount {
                        Text("Cited by \(citationCount)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(selection.labelText)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Loading paper metadata...")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var abstractBlock: some View {
        if let abstract = metadata?.abstractText, !abstract.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Abstract")
                    .font(.headline)
                Text(abstract)
                    .font(.body)
                    .lineLimit(isShowingFullAbstract ? nil : 4)
                Button(isShowingFullAbstract ? "Show less" : "Show more") {
                    isShowingFullAbstract.toggle()
                }
                .buttonStyle(.link)
            }
        }
    }

    private var actionRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                actionButton("Save") {
                    openInBrowser(metadata?.googleScholarURL)
                }
                actionButton("Cite") {
                    guard styles != nil else { return }
                    isShowingCiteSheet = true
                }
                .disabled(styles == nil)
                actionButton("Cited by") {
                    openInBrowser(metadata?.citedByURL ?? metadata?.googleScholarURL)
                }
                actionButton("Related articles") {
                    openInBrowser(metadata?.relatedArticlesURL ?? metadata?.providerLandingURL)
                }
            }

            HStack(spacing: 12) {
                Button {
                    openBestPDF()
                } label: {
                    Text(pdfButtonTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onSeeInReferences(selection)
                } label: {
                    Text("See in references")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(selection.destinationPageIndex == nil)
            }
        }
    }

    private var pdfButtonTitle: String {
        if localMatch != nil {
            return "Open local PDF"
        }
        if let url = metadata?.openAccessPDFURL {
            return "PDF (\(url.host ?? "remote"))"
        }
        return "PDF"
    }

    private func referenceBlock(_ referenceText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference context")
                .font(.headline)
            Text(referenceText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.link)
    }

    @MainActor
    private func loadCitation() async {
        isLoading = true
        metadata = nil
        localMatch = nil
        styles = nil
        errorMessage = nil

        do {
            let resolvedMetadata = try await metadataProvider.fetchMetadata(for: selection)
            metadata = resolvedMetadata
            styles = exporter.makeStyleBundle(from: resolvedMetadata)
            let normalizedTitle = CitationTitleNormalizer.normalize(resolvedMetadata.title)
            localMatch = await localPaperSearch.findExactTitleMatch(normalizedTitle: normalizedTitle)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func openBestPDF() {
        if let localMatch {
            onOpenLocalPDF(localMatch.fileURL)
            dismiss()
            return
        }

        if let openAccessPDFURL = metadata?.openAccessPDFURL {
            openInBrowser(openAccessPDFURL)
            return
        }

        openInBrowser(metadata?.providerLandingURL ?? metadata?.googleScholarURL)
    }

    private func openInBrowser(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct CitationStylesSheet: View {
    let metadata: CitationMetadata
    let styles: CitationStyleBundle

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cite")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    styleBlock("MLA", text: styles.mla)
                    styleBlock("APA", text: styles.apa)
                    styleBlock("Chicago", text: styles.chicago)
                    styleBlock("Harvard", text: styles.harvard)
                    styleBlock("Vancouver", text: styles.vancouver)

                    Divider()

                    Text("Download")
                        .font(.headline)
                    HStack(spacing: 12) {
                        exportButton("BibTeX", text: styles.bibTeX, fileExtension: "bib")
                        exportButton("EndNote", text: styles.endNote, fileExtension: "enw")
                        exportButton("RefMan", text: styles.refManRIS, fileExtension: "ris")
                        exportButton("RefWorks", text: styles.refWorksRIS, fileExtension: "ris")
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private func styleBlock(_ name: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.headline)
            Text(text)
                .textSelection(.enabled)
        }
    }

    private func exportButton(_ title: String, text: String, fileExtension: String) -> some View {
        Button(title) {
            saveExport(text: text, title: title, fileExtension: fileExtension)
        }
        .buttonStyle(.bordered)
    }

    private func saveExport(text: String, title: String, fileExtension: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename(for: title, fileExtension: fileExtension)
        if let contentType = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [contentType]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
        }
    }

    private func defaultFilename(for title: String, fileExtension: String) -> String {
        let base = CitationTitleNormalizer.normalize(metadata.title)
            .replacingOccurrences(of: " ", with: "-")
        let prefix = base.isEmpty ? "citation" : base
        return "\(prefix)-\(title.lowercased()).\(fileExtension)"
    }
}
