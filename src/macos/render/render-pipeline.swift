import AppKit
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
                html: htmlDocument(body: body),
                warnings: content.isTrusted ? [] : [RenderWarning(message: "HTML input was sanitized before rendering.")]
            )
        case .markdown:
            return await renderMarkdown(content)
        }
    }

    private func renderMarkdown(_ content: RenderContent) async -> RenderResult {
        let extraction = extractMathTokens(from: content.source)
        var warnings = extraction.warnings

        let bodyHTML: String
        do {
            bodyHTML = try markdownBodyHTML(from: extraction.markdown)
        } catch {
            warnings.append(RenderWarning(message: "Markdown conversion failed. Falling back to plain text preview."))
            let escaped = escapeHTML(content.source)
            return RenderResult(
                html: htmlDocument(body: "<pre>\(escaped)</pre>"),
                warnings: warnings
            )
        }

        var renderedHTML = bodyHTML
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
            html: htmlDocument(body: renderedHTML),
            warnings: warnings
        )
    }

    private func markdownBodyHTML(from markdown: String) throws -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let attributed = try AttributedString(markdown: markdown, options: options)
        let nsAttributed = NSAttributedString(attributed)
        let range = NSRange(location: 0, length: nsAttributed.length)
        let data = try nsAttributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        )
        let html = String(data: data, encoding: .utf8) ?? "<p>\(escapeHTML(markdown))</p>"
        return extractBody(fromHTMLDocument: html)
    }

    private func extractBody(fromHTMLDocument html: String) -> String {
        guard let bodyStartRange = html.range(of: "<body[^>]*>", options: .regularExpression),
              let bodyEndRange = html.range(of: "</body>", options: .caseInsensitive)
        else {
            return html
        }

        return String(html[bodyStartRange.upperBound..<bodyEndRange.lowerBound])
    }

    private func sanitizedHTMLBody(from html: String) -> String {
        html.replacingOccurrences(
            of: "<script\\b[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )
    }

    private func htmlDocument(body: String) -> String {
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
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
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
