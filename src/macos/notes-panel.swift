import SwiftUI

struct AnnotationPreviewPanel: View {
    let selection: AnnotationRenderSelection?
    let pipeline: any RenderPipelineServing
    let onClose: () -> Void

    @State private var renderResult: RenderResult = .empty
    @State private var isRendering = false
    @State private var isStale = false
    @State private var lastRenderedIdentity: String = "none"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: renderKey) {
            await renderWithDebounce()
        }
    }

    // Changes to the annotation identity (page, bounds) trigger an immediate render.
    // Changes to rawText only (live note editing) sleep 800 ms so we don't render on
    // every keystroke; the task is cancelled and restarted whenever the text changes
    // again, resetting the timer automatically.
    private func renderWithDebounce() async {
        let currentIdentity = annotationIdentityKey
        if currentIdentity == lastRenderedIdentity && selection != nil {
            isStale = true
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
        }
        isStale = false
        await renderSelection()
    }

    private var annotationIdentityKey: String {
        guard let selection else { return "none" }
        return "\(selection.documentPath)|\(selection.pageIndex)|\(selection.annotationBounds.debugDescription)"
    }

    private var renderKey: String {
        guard let selection else { return "none" }
        return "\(annotationIdentityKey)|\(selection.rawText)"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Annotation Preview")
                    .font(.title3)
                    .fontWeight(.semibold)
                if let selection {
                    Text("Page \(selection.pageIndex + 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let author = selection.authorName, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Select or open a PDF note to preview it here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button("Close") {
                onClose()
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if let selection {
            VStack(spacing: 0) {
                if isRendering && !isStale {
                    ProgressView("Rendering note...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if renderResult.html.isEmpty && !isStale {
                    previewEmptyState(
                        title: "Nothing to render",
                        message: "The selected annotation note is empty."
                    )
                } else {
                    if !renderResult.warnings.isEmpty {
                        warningBanner
                    }
                    RenderView(
                        result: renderResult,
                        baseURL: URL(fileURLWithPath: selection.documentPath).deletingLastPathComponent()
                    )
                    .opacity(isStale ? 0.45 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: isStale)
                }
            }
        } else {
            previewEmptyState(
                title: "No note selected",
                message: "Pick a highlighted note marker or a note entry from the PDF sidebar."
            )
        }
    }

    private var warningBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(renderResult.warnings) { warning in
                Text(warning.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.yellow.opacity(0.16))
    }

    private func previewEmptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    @MainActor
    private func renderSelection() async {
        lastRenderedIdentity = annotationIdentityKey
        guard let selection else {
            renderResult = .empty
            isRendering = false
            return
        }

        isRendering = true
        let result = await pipeline.render(
            RenderContent(
                source: selection.rawText,
                format: .markdown,
                baseURL: URL(fileURLWithPath: selection.documentPath).deletingLastPathComponent(),
                isTrusted: false
            )
        )
        renderResult = result
        isRendering = false
    }
}
