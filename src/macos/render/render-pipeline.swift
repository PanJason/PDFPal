import Foundation
import MathJaxSwift

protocol RenderPipelineServing {
    func render(_ content: RenderContent) async -> RenderResult
}

final class RenderPipeline: RenderPipelineServing {
    private let mathRenderer = MathExpressionRenderer()

    func render(_ content: RenderContent) async -> RenderResult {
        let trimmedSource = content.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else {
            return .empty
        }

        switch content.format {
        case .html:
            let body = content.isTrusted ? content.source : sanitizedHTMLBody(from: content.source)
            return RenderResult(
                html: htmlDocument(body: body, additionalStyles: ""),
                warnings: content.isTrusted ? [] : [RenderWarning(message: "HTML input was sanitized before rendering.")]
            )
        case .markdown:
            return await renderMarkdown(content)
        }
    }

    private func renderMarkdown(_ content: RenderContent) async -> RenderResult {
        let extraction = extractMathTokens(from: content.source)
        var warnings = extraction.warnings

        var renderedHTML = markdownBodyHTML(from: extraction.markdown)
        for fragment in extraction.fragments {
            let conversion = await mathRenderer.render(fragment.source, display: fragment.display)
            warnings.append(contentsOf: conversion.warnings)

            if fragment.display {
                let paragraphToken = "<p>\(fragment.placeholder)</p>"
                if renderedHTML.contains(paragraphToken) {
                    renderedHTML = renderedHTML.replacingOccurrences(of: paragraphToken, with: conversion.html)
                } else {
                    renderedHTML = renderedHTML.replacingOccurrences(of: fragment.placeholder, with: conversion.html)
                }
            } else {
                renderedHTML = renderedHTML.replacingOccurrences(of: fragment.placeholder, with: conversion.html)
            }
        }

        return RenderResult(
            html: htmlDocument(body: renderedHTML, additionalStyles: ""),
            warnings: warnings
        )
    }

    private func markdownBodyHTML(from markdown: String) -> String {
        SimpleMarkdownRenderer.render(markdown)
    }

    private func sanitizedHTMLBody(from html: String) -> String {
        html.replacingOccurrences(
            of: "<script\\b[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )
    }

    private func htmlDocument(body: String, additionalStyles: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
            color-scheme: light;
            --text: #1b1b18;
            --muted: #6d6a63;
            --border: #ddd5c5;
            --bg: #fcf7ec;
            --panel: #fffdf7;
            --accent: #b3561d;
            --code-bg: #f4edde;
        }
        html, body {
            margin: 0;
            padding: 0;
            background: var(--bg);
            color: var(--text);
            font-family: "Iowan Old Style", "Palatino", serif;
            line-height: 1.55;
            font-size: 15px;
        }
        body {
            padding: 18px 20px 28px;
        }
        a {
            color: var(--accent);
        }
        p, ul, ol, blockquote, pre, table {
            margin: 0 0 14px;
        }
        h1, h2, h3, h4, h5, h6 {
            margin: 0 0 10px;
            line-height: 1.2;
        }
        code {
            font-family: "SF Mono", "Menlo", monospace;
            background: var(--code-bg);
            border-radius: 4px;
            padding: 1px 4px;
        }
        pre {
            background: var(--code-bg);
            border-radius: 8px;
            padding: 12px 14px;
            overflow-x: auto;
        }
        pre code {
            padding: 0;
            background: transparent;
        }
        blockquote {
            border-left: 3px solid var(--border);
            padding-left: 12px;
            color: var(--muted);
        }
        table {
            border-collapse: collapse;
            width: 100%;
        }
        th, td {
            border: 1px solid var(--border);
            padding: 8px 10px;
            text-align: left;
        }
        .math-inline {
            display: inline-flex;
            vertical-align: middle;
            align-items: center;
        }
        .math-inline svg {
            max-width: 100%;
            height: auto;
        }
        .math-block {
            display: block;
            margin: 16px 0;
            overflow-x: auto;
        }
        .math-block svg {
            display: block;
            margin: 0 auto;
            max-width: 100%;
            height: auto;
        }
        .math-fallback {
            font-family: "SF Mono", "Menlo", monospace;
            background: var(--code-bg);
            border-radius: 6px;
            padding: 6px 8px;
        }
        \(additionalStyles)
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}

private enum MarkdownListType {
    case unordered
    case ordered
}

private enum SimpleMarkdownRenderer {
    static func render(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var htmlBlocks: [String] = []
        var paragraphLines: [String] = []
        var blockquoteLines: [String] = []
        var listItems: [String] = []
        var activeListType: MarkdownListType?
        var activeFence: String?
        var fencedCodeLines: [String] = []
        var fencedCodeLanguage = ""

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let rendered = paragraphLines
                .map(renderInline)
                .joined(separator: "<br>")
            htmlBlocks.append("<p>\(rendered)</p>")
            paragraphLines.removeAll()
        }

        func flushBlockquote() {
            guard !blockquoteLines.isEmpty else { return }
            let rendered = blockquoteLines
                .map(renderInline)
                .joined(separator: "<br>")
            htmlBlocks.append("<blockquote><p>\(rendered)</p></blockquote>")
            blockquoteLines.removeAll()
        }

        func flushList() {
            guard !listItems.isEmpty, let activeListType else { return }
            let tag = activeListType == .ordered ? "ol" : "ul"
            let items = listItems.map { "<li>\($0)</li>" }.joined()
            htmlBlocks.append("<\(tag)>\(items)</\(tag)>")
            listItems.removeAll()
            selfResetList()
        }

        func selfResetList() {
            activeListType = nil
        }

        func flushCodeBlock() {
            guard activeFence != nil else { return }
            let escaped = escapeHTML(fencedCodeLines.joined(separator: "\n"))
            let classAttribute = fencedCodeLanguage.isEmpty ? "" : " class=\"language-\(escapeHTML(fencedCodeLanguage))\""
            htmlBlocks.append("<pre><code\(classAttribute)>\(escaped)</code></pre>")
            activeFence = nil
            fencedCodeLines.removeAll()
            fencedCodeLanguage = ""
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let activeFence {
                if trimmed == activeFence {
                    flushCodeBlock()
                } else {
                    fencedCodeLines.append(line)
                }
                continue
            }

            if let fence = openingFence(in: trimmed) {
                flushParagraph()
                flushBlockquote()
                flushList()
                activeFence = fence
                fencedCodeLanguage = String(
                    trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespacesAndNewlines)
                )
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushBlockquote()
                flushList()
                continue
            }

            if let heading = headingInfo(in: line) {
                flushParagraph()
                flushBlockquote()
                flushList()
                htmlBlocks.append("<h\(heading.level)>\(renderInline(heading.content))</h\(heading.level)>")
                continue
            }

            if let blockquote = blockquoteLine(in: line) {
                flushParagraph()
                flushList()
                blockquoteLines.append(blockquote)
                continue
            }

            if let listItem = listItemInfo(in: line) {
                flushParagraph()
                flushBlockquote()
                if activeListType != nil, activeListType != listItem.type {
                    flushList()
                }
                activeListType = listItem.type
                listItems.append(renderInline(listItem.content))
                continue
            }

            flushBlockquote()
            flushList()
            paragraphLines.append(line)
        }

        if activeFence != nil {
            flushCodeBlock()
        }
        flushParagraph()
        flushBlockquote()
        flushList()

        return htmlBlocks.joined(separator: "\n")
    }

    private static func renderInline(_ source: String) -> String {
        let codeExtraction = replaceMatches(
            in: source,
            pattern: "`([^`]+)`"
        ) { groups in
            let code = groups.count > 1 ? groups[1] : groups[0]
            return "<code>\(escapeHTML(code))</code>"
        }

        var html = escapeHTML(codeExtraction.text)
        html = replaceLinks(in: html)
        html = replaceRegex(in: html, pattern: "\\*\\*(.+?)\\*\\*", template: "<strong>$1</strong>")
        html = replaceRegex(in: html, pattern: "\\*(.+?)\\*", template: "<em>$1</em>")
        html = restorePlaceholders(codeExtraction.placeholders, in: html)
        return html
    }

    private static func replaceLinks(in source: String) -> String {
        replaceRegex(
            in: source,
            pattern: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)",
            template: "<a href=\"$2\">$1</a>"
        )
    }

    private static func replaceRegex(in source: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return source
        }
        let range = NSRange(location: 0, length: (source as NSString).length)
        return regex.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: template)
    }

    private static func replaceMatches(
        in source: String,
        pattern: String,
        replacement: ([String]) -> String
    ) -> (text: String, placeholders: [String: String]) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (source, [:])
        }

        let nsSource = source as NSString
        let matches = regex.matches(in: source, options: [], range: NSRange(location: 0, length: nsSource.length))
        guard !matches.isEmpty else {
            return (source, [:])
        }

        var placeholders: [String: String] = [:]
        var result = source

        for (index, match) in matches.enumerated().reversed() {
            let fullRange = match.range(at: 0)
            guard fullRange.location != NSNotFound else { continue }

            var groups: [String] = []
            for groupIndex in 0..<match.numberOfRanges {
                let groupRange = match.range(at: groupIndex)
                guard groupRange.location != NSNotFound else {
                    groups.append("")
                    continue
                }
                groups.append(nsSource.substring(with: groupRange))
            }

            let placeholder = "PDFPAL_INLINE_PLACEHOLDER_\(index)_TOKEN"
            placeholders[placeholder] = replacement(groups)
            if let range = Range(fullRange, in: result) {
                result.replaceSubrange(range, with: placeholder)
            }
        }

        return (result, placeholders)
    }

    private static func restorePlaceholders(_ placeholders: [String: String], in source: String) -> String {
        placeholders.reduce(source) { partialResult, entry in
            partialResult.replacingOccurrences(of: entry.key, with: entry.value)
        }
    }

    private static func headingInfo(in line: String) -> (level: Int, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        let level = hashes.count
        guard level > 0, level <= 6 else { return nil }

        let afterHashes = trimmed.dropFirst(level)
        guard afterHashes.first == " " else { return nil }
        return (level, String(afterHashes.dropFirst()))
    }

    private static func blockquoteLine(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        return String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    private static func listItemInfo(in line: String) -> (type: MarkdownListType, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (.unordered, String(trimmed.dropFirst(2)))
        }

        let pattern = #"^(\d+)[\.\)]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let nsLine = trimmed as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges > 2
        else {
            return nil
        }
        return (.ordered, nsLine.substring(with: match.range(at: 2)))
    }
}

private struct ExtractedMarkdown {
    let markdown: String
    let fragments: [MathFragment]
    let warnings: [RenderWarning]
}

private struct MathFragment {
    let placeholder: String
    let source: String
    let display: Bool
}

private enum MarkdownParseMode {
    case normal
    case codeFence(fence: String, lines: [String])
    case mathFence(fence: String, lines: [String])
    case displayMath(lines: [String])
}

private final class MathExpressionRenderer {
    private let mathJaxResult: Result<MathJax, Error>

    init() {
        do {
            mathJaxResult = .success(try MathJax(preferredOutputFormat: .svg))
        } catch {
            mathJaxResult = .failure(error)
        }
    }

    func render(_ source: String, display: Bool) async -> RenderResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        guard case .success(let mathJax) = mathJaxResult else {
            return RenderResult(
                html: "<span class=\"math-fallback\">\(escapeHTML(trimmed))</span>",
                warnings: [RenderWarning(message: "MathJaxSwift could not be initialized for math rendering.")]
            )
        }

        do {
            let svg = try await mathJax.tex2svg(
                trimmed,
                conversionOptions: ConversionOptions(display: display)
            )
            let containerClass = display ? "math-block" : "math-inline"
            let tag = display ? "div" : "span"
            return RenderResult(
                html: "<\(tag) class=\"\(containerClass)\">\(svg)</\(tag)>",
                warnings: []
            )
        } catch {
            let fallbackTag = display ? "div" : "span"
            return RenderResult(
                html: "<\(fallbackTag) class=\"math-fallback\">\(escapeHTML(trimmed))</\(fallbackTag)>",
                warnings: [RenderWarning(message: "Math rendering failed for `\(trimmed)`.")]
            )
        }
    }
}

private func extractMathTokens(from source: String) -> ExtractedMarkdown {
    let lines = source.components(separatedBy: "\n")
    var mode: MarkdownParseMode = .normal
    var outputLines: [String] = []
    var fragments: [MathFragment] = []
    var warnings: [RenderWarning] = []
    var fragmentCounter = 0

    func nextPlaceholder(display: Bool) -> String {
        defer { fragmentCounter += 1 }
        return display ? "PDFPAL_MATH_BLOCK_\(fragmentCounter)_TOKEN" : "PDFPAL_MATH_INLINE_\(fragmentCounter)_TOKEN"
    }

    func appendDisplayFragment(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = nextPlaceholder(display: true)
        fragments.append(MathFragment(placeholder: placeholder, source: trimmed, display: true))
        outputLines.append(placeholder)
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .normal:
            if let fence = openingFence(in: trimmed) {
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if language == "math" {
                    mode = .mathFence(fence: fence, lines: [])
                } else {
                    mode = .codeFence(fence: fence, lines: [line])
                }
                continue
            }

            if trimmed == "$$" {
                mode = .displayMath(lines: [])
                continue
            }

            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
                let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
                let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
                appendDisplayFragment(String(trimmed[start..<end]))
                continue
            }

            let inlineExtraction = replaceInlineMath(in: line, nextPlaceholder: nextPlaceholder)
            outputLines.append(inlineExtraction.text)
            fragments.append(contentsOf: inlineExtraction.fragments)

        case .codeFence(let fence, var codeLines):
            codeLines.append(line)
            if trimmed == fence {
                outputLines.append(contentsOf: codeLines)
                mode = .normal
            } else {
                mode = .codeFence(fence: fence, lines: codeLines)
            }

        case .mathFence(let fence, var mathLines):
            if trimmed == fence {
                appendDisplayFragment(mathLines.joined(separator: "\n"))
                mode = .normal
            } else {
                mathLines.append(line)
                mode = .mathFence(fence: fence, lines: mathLines)
            }

        case .displayMath(var mathLines):
            if trimmed == "$$" {
                appendDisplayFragment(mathLines.joined(separator: "\n"))
                mode = .normal
            } else {
                mathLines.append(line)
                mode = .displayMath(lines: mathLines)
            }
        }
    }

    switch mode {
    case .normal:
        break
    case .codeFence(_, let lines):
        outputLines.append(contentsOf: lines)
        warnings.append(RenderWarning(message: "An unterminated code fence was rendered as plain Markdown."))
    case .mathFence(_, let lines):
        outputLines.append("```math")
        outputLines.append(contentsOf: lines)
        warnings.append(RenderWarning(message: "An unterminated math fence was rendered as plain Markdown."))
    case .displayMath(let lines):
        outputLines.append("$$")
        outputLines.append(contentsOf: lines)
        warnings.append(RenderWarning(message: "An unterminated $$ math block was rendered as plain Markdown."))
    }

    return ExtractedMarkdown(
        markdown: outputLines.joined(separator: "\n"),
        fragments: fragments,
        warnings: warnings
    )
}

private func replaceInlineMath(
    in line: String,
    nextPlaceholder: (Bool) -> String
) -> (text: String, fragments: [MathFragment]) {
    var result = ""
    var fragments: [MathFragment] = []
    var index = line.startIndex
    var activeCodeDelimiterCount: Int?

    while index < line.endIndex {
        let character = line[index]

        if character == "`" {
            let runEnd = line[index...].prefix { $0 == "`" }.endIndex
            let runCount = line.distance(from: index, to: runEnd)
            result.append(contentsOf: line[index..<runEnd])
            if activeCodeDelimiterCount == runCount {
                activeCodeDelimiterCount = nil
            } else if activeCodeDelimiterCount == nil {
                activeCodeDelimiterCount = runCount
            }
            index = runEnd
            continue
        }

        if activeCodeDelimiterCount != nil {
            result.append(character)
            index = line.index(after: index)
            continue
        }

        if character == "\\",
           let nextIndex = line.index(index, offsetBy: 1, limitedBy: line.endIndex),
           nextIndex < line.endIndex,
           line[nextIndex] == "$" {
            result.append("\\$")
            index = line.index(after: nextIndex)
            continue
        }

        if character == "$" {
            let nextIndex = line.index(after: index)
            if nextIndex < line.endIndex, line[nextIndex] == "$" {
                if let closingRange = line.range(of: "$$", range: line.index(after: nextIndex)..<line.endIndex) {
                    let contentStart = line.index(index, offsetBy: 2)
                    let content = String(line[contentStart..<closingRange.lowerBound])
                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let placeholder = nextPlaceholder(true)
                        fragments.append(MathFragment(placeholder: placeholder, source: content, display: true))
                        result.append(placeholder)
                        index = closingRange.upperBound
                        continue
                    }
                }
            } else if let closingIndex = findClosingDollar(in: line, from: nextIndex) {
                let content = String(line[nextIndex..<closingIndex])
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let placeholder = nextPlaceholder(false)
                    fragments.append(MathFragment(placeholder: placeholder, source: content, display: false))
                    result.append(placeholder)
                    index = line.index(after: closingIndex)
                    continue
                }
            }
        }

        result.append(character)
        index = line.index(after: index)
    }

    return (result, fragments)
}

private func openingFence(in trimmed: String) -> String? {
    guard trimmed.hasPrefix("```") else { return nil }
    return String(trimmed.prefix { $0 == "`" })
}

private func findClosingDollar(in line: String, from start: String.Index) -> String.Index? {
    var index = start
    while index < line.endIndex {
        if line[index] == "\\",
           let nextIndex = line.index(index, offsetBy: 1, limitedBy: line.endIndex),
           nextIndex < line.endIndex {
            index = line.index(after: nextIndex)
            continue
        }

        if line[index] == "$" {
            return index
        }

        index = line.index(after: index)
    }
    return nil
}

private func escapeHTML(_ source: String) -> String {
    source
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
