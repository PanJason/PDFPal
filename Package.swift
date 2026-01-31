// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LLMPaperReadingHelper",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "LLMPaperReadingHelper",
            targets: ["LLMPaperReadingHelper"]
        )
    ],
    targets: [
        .executableTarget(
            name: "LLMPaperReadingHelper",
            path: "src/macos",
            linkerSettings: [
                .linkedFramework("PDFKit")
            ]
        )
    ]
)
