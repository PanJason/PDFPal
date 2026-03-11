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
    dependencies: [
        .package(url: "https://github.com/colinc86/MathJaxSwift.git", from: "3.4.0")
    ],
    targets: [
        .executableTarget(
            name: "LLMPaperReadingHelper",
            dependencies: [
                .product(name: "MathJaxSwift", package: "MathJaxSwift")
            ],
            path: "src/macos",
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedFramework("WebKit")
            ]
        )
    ]
)
