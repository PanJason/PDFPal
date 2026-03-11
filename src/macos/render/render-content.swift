import CoreGraphics
import Foundation

enum RenderFormat: String, Codable, Equatable {
    case markdown
    case html
}

struct RenderContent: Codable, Equatable {
    let source: String
    let format: RenderFormat
    let baseURL: URL?
    let isTrusted: Bool

    init(
        source: String,
        format: RenderFormat = .markdown,
        baseURL: URL? = nil,
        isTrusted: Bool = false
    ) {
        self.source = source
        self.format = format
        self.baseURL = baseURL
        self.isTrusted = isTrusted
    }
}

struct RenderWarning: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

struct RenderResult: Equatable {
    let html: String
    let warnings: [RenderWarning]

    static let empty = RenderResult(html: "", warnings: [])
}

struct AnnotationRenderSelection: Equatable {
    let documentPath: String
    let pageIndex: Int
    let annotationBounds: CGRect
    let rawText: String
    let authorName: String?
}

typealias AnnotationSelectionHandler = (AnnotationRenderSelection?) -> Void
