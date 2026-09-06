// MarkdownRenderer.swift
// ZiroEdge — Privacy-first local AI assistant
//
// Lightweight markdown → AttributedString converter.
// Handles the common subset: bold, italic, inline code, code blocks,
// headers, bullet lists, numbered lists, and links.
// No WKWebView. No third-party dependencies. Pure SwiftUI text rendering.

import SwiftUI

// MARK: - Markdown Renderer

/// Converts markdown text into SwiftUI-ready `AttributedString`.
/// This is a dedicated service — NOT inline view parsing.
struct MarkdownRenderer {

    // BATCH-04: debounced rendering observability — counts actual parse invocations
    private static let lock = NSLock()
    private static var _renderCount = 0
    static var renderHook: (@Sendable () -> Void)?
    static var renderCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _renderCount
    }
    static func resetRenderCount() {
        lock.lock(); _renderCount = 0; lock.unlock()
    }
    static func getRenderCount() -> Int { renderCount }

    // MARK: - Public API

    /// Render markdown string to AttributedString for display in SwiftUI Text.
    static func render(_ markdown: String) -> AttributedString {
        lock.lock()
        _renderCount += 1
        let hook = renderHook
        lock.unlock()
        hook?()
        var result = AttributedString()

        // Split into lines for block-level processing.
        // Drop trailing empty lines so the renderer doesn't add extra blank
        // lines at the end (e.g. when the LLM response ends with \n).
        var lines = markdown.components(separatedBy: "\n")
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        var inCodeBlock = false
        var codeBlockLanguage = ""
        var codeBlockLines: [String] = []

        for line in lines {
            // Code block fences.
            if line.hasPrefix("```") {
                if inCodeBlock {
                    // End of code block — render accumulated code.
                    let code = codeBlockLines.joined(separator: "\n")
                    result.append(renderCodeBlock(code, language: codeBlockLanguage))
                    codeBlockLines = []
                    codeBlockLanguage = ""
                    inCodeBlock = false
                } else {
                    // Start of code block.
                    inCodeBlock = true
                    codeBlockLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCodeBlock {
                codeBlockLines.append(line)
                continue
            }

            // Block-level elements.
            if line.hasPrefix("### ") {
                result.append(renderHeading(String(line.dropFirst(4)), level: 3))
            } else if line.hasPrefix("## ") {
                result.append(renderHeading(String(line.dropFirst(3)), level: 2))
            } else if line.hasPrefix("# ") {
                result.append(renderHeading(String(line.dropFirst(2)), level: 1))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(renderBulletItem(String(line.dropFirst(2))))
            } else if let numbered = extractNumberedListItem(line) {
                result.append(renderNumberedItem(numbered.text, number: numbered.number))
            } else if line.hasPrefix("> ") {
                result.append(renderBlockquote(String(line.dropFirst(2))))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(AttributedString("\n"))
            } else {
                // Regular paragraph — render inline markdown.
                result.append(renderInline(line))
                result.append(AttributedString("\n"))
            }
        }

        // Handle unclosed code block.
        if inCodeBlock && !codeBlockLines.isEmpty {
            let code = codeBlockLines.joined(separator: "\n")
            result.append(renderCodeBlock(code, language: codeBlockLanguage))
        }

        // Strip trailing newlines. Every block-level element appends "\n",
        // so the final output always ends with at least one trailing newline.
        // We bridge through NSAttributedString to safely delete trailing chars.
        let nsResult = NSMutableAttributedString(attributedString: NSAttributedString(result))
        while nsResult.length > 0, nsResult.string.hasSuffix("\n") {
            nsResult.deleteCharacters(in: NSRange(location: nsResult.length - 1, length: 1))
        }
        return AttributedString(nsResult)
    }

    // MARK: - Inline Rendering

    /// Render inline markdown: **bold**, *italic*, `code`, [links](url).
    private static func renderInline(_ text: String) -> AttributedString {
        var result = AttributedString()
        var remaining = text

        while !remaining.isEmpty {
            // Try to find the next inline element.
            if let boldRange = remaining.range(of: "**") {
                // Find closing **
                let afterOpen = remaining[boldRange.upperBound...]
                if let closeRange = afterOpen.range(of: "**") {
                    // Render text before bold.
                    let before = String(remaining[..<boldRange.lowerBound])
                    if !before.isEmpty {
                        result.append(renderPlainText(before))
                    }

                    // Render bold text.
                    let boldText = String(afterOpen[..<closeRange.lowerBound])
                    var boldAttr = AttributedString(boldText)
                    boldAttr.font = Font.body.bold()
                    result.append(boldAttr)

                    remaining = String(afterOpen[closeRange.upperBound...])
                    continue
                }
            }

            if let italicRange = remaining.range(of: "*") {
                let afterOpen = remaining[italicRange.upperBound...]
                if let closeRange = afterOpen.range(of: "*") {
                    let before = String(remaining[..<italicRange.lowerBound])
                    if !before.isEmpty {
                        result.append(renderPlainText(before))
                    }

                    let italicText = String(afterOpen[..<closeRange.lowerBound])
                    var italicAttr = AttributedString(italicText)
                    italicAttr.font = Font.body.italic()
                    result.append(italicAttr)

                    remaining = String(afterOpen[closeRange.upperBound...])
                    continue
                }
            }

            if let codeRange = remaining.range(of: "`") {
                let afterOpen = remaining[codeRange.upperBound...]
                if let closeRange = afterOpen.range(of: "`") {
                    let before = String(remaining[..<codeRange.lowerBound])
                    if !before.isEmpty {
                        result.append(renderPlainText(before))
                    }

                    let codeText = String(afterOpen[..<closeRange.lowerBound])
                    result.append(renderInlineCode(codeText))

                    remaining = String(afterOpen[closeRange.upperBound...])
                    continue
                }
            }

            // No more inline elements — render remaining as plain text.
            result.append(renderPlainText(remaining))
            break
        }

        return result
    }

    // MARK: - Element Renderers

    private static func renderHeading(_ text: String, level: Int) -> AttributedString {
        var attr = renderInline(text)
        switch level {
        case 1:
            attr.font = Font.title.bold()
        case 2:
            attr.font = Font.title2.bold()
        case 3:
            attr.font = Font.title3.bold()
        default:
            attr.font = Font.headline.bold()
        }
        attr.append(AttributedString("\n"))
        return attr
    }

    private static func renderBulletItem(_ text: String) -> AttributedString {
        var result = AttributedString("  • ")
        result.font = .body
        result.append(renderInline(text))
        result.append(AttributedString("\n"))
        return result
    }

    private static func renderNumberedItem(_ text: String, number: Int) -> AttributedString {
        var result = AttributedString("  \(number). ")
        result.font = .body
        result.append(renderInline(text))
        result.append(AttributedString("\n"))
        return result
    }

    private static func renderBlockquote(_ text: String) -> AttributedString {
        var result = AttributedString("  │ ")
        result.foregroundColor = .secondary
        var quoteText = renderInline(text)
        quoteText.foregroundColor = .secondary
        result.append(quoteText)
        result.append(AttributedString("\n"))
        return result
    }

    private static func renderCodeBlock(_ code: String, language: String) -> AttributedString {
        var result = AttributedString("\n")
        // Single recessed-well card (navy `#1A2340` in dark mode) instead of
        // systemGray6, which renders light-gray on the navy canvas. The fence
        // language is parsed but stays out of the text — the transcript
        // renders no block header or copy button, so a language label would
        // be orphan chrome. Syntax tint is tasteful and dark-mode safe:
        // keywords in infoText blue, literals in warningText orange, comments
        // in positiveText green — all contrast-verified ZiroTheme tokens on
        // the well. Base stays primaryText; the monospaced body style scales
        // with Dynamic Type and carries no animation (Reduce Motion safe).
        result.append(renderTintedCode(code))
        result.append(AttributedString("\n\n"))
        return result
    }

    /// Lightweight code tint on the well card: keywords blue, strings/numbers
    /// orange, line/block comments green. ZiroTheme tokens only (no raw hues)
    /// so light/dark contrast stays verified. Strings win over comment
    /// markers and comments win over keywords by scan order, so `http://`
    /// inside a string never leaks green.
    private static func renderTintedCode(_ code: String) -> AttributedString {
        var result = AttributedString()
        let mono = Font.system(.body, design: .monospaced)
        let well = ZiroTheme.wellBackground
        let base = ZiroTheme.primaryText
        let keywordColor = ZiroTheme.infoText
        let literalColor = ZiroTheme.warningText
        let commentColor = ZiroTheme.positiveText
        let keywords: Set<String> = [
            "let", "var", "func", "return", "if", "else", "elif",
            "for", "while", "in", "import", "from", "struct",
            "class", "enum", "extension", "guard", "switch", "case",
            "break", "continue", "try", "catch", "throw", "throws",
            "async", "await", "self", "nil", "true", "false",
            "True", "False", "None", "def", "lambda", "const",
            "new", "do", "public", "private", "static"
        ]
        func makeRun(_ text: String, color: Color) -> AttributedString {
            var run = AttributedString(text)
            run.font = mono
            run.backgroundColor = well
            run.foregroundColor = color
            return run
        }
        var index = code.startIndex
        while index < code.endIndex {
            let remaining = code[index...]
            // Line comment: // to end of line.
            if remaining.hasPrefix("//") {
                let end = code[index...].firstIndex(where: { $0 == "\n" }) ?? code.endIndex
                result.append(makeRun(String(code[index..<end]), color: commentColor))
                index = end
                continue
            }
            // Block comment: /* … */ (unclosed runs to end).
            if remaining.hasPrefix("/*") {
                if let close = code[index...].range(of: "*/") {
                    let end = close.upperBound
                    result.append(makeRun(String(code[index..<end]), color: commentColor))
                    index = end
                } else {
                    result.append(makeRun(String(code[index...]), color: commentColor))
                    break
                }
                continue
            }
            // Hash comment (#python/#shell): only at line start or after
            // whitespace so `#available` attributes don't go green.
            if code[index] == "#" {
                let atStart = index == code.startIndex
                let prevIsSpace = !atStart && code[code.index(before: index)].isWhitespace
                if atStart || prevIsSpace {
                    let end = code[index...].firstIndex(where: { $0 == "\n" }) ?? code.endIndex
                    result.append(makeRun(String(code[index..<end]), color: commentColor))
                    index = end
                    continue
                }
            }
            // String literal: "…" '…' `…` with backslash escapes, same-line
            // only so an unmatched quote can't wash the rest orange.
            if code[index] == "\"" || code[index] == "'" || code[index] == "`" {
                let quote = code[index]
                var end = code.index(after: index)
                var closed = false
                while end < code.endIndex {
                    let ch = code[end]
                    if ch == "\\" {
                        end = code.index(after: end)
                        if end < code.endIndex { end = code.index(after: end) }
                        continue
                    }
                    if ch == quote { closed = true; end = code.index(after: end); break }
                    if ch == "\n" { break }
                    end = code.index(after: end)
                }
                if closed {
                    result.append(makeRun(String(code[index..<end]), color: literalColor))
                    index = end
                } else {
                    result.append(makeRun(String(code[index]), color: base))
                    index = code.index(after: index)
                }
                continue
            }
            // Number literal: digit-led run (hex/dots/underscores included).
            if code[index].isNumber {
                var end = code.index(after: index)
                while end < code.endIndex && (code[end].isLetter || code[end].isNumber || code[end] == "_" || code[end] == ".") {
                    end = code.index(after: end)
                }
                result.append(makeRun(String(code[index..<end]), color: literalColor))
                index = end
                continue
            }
            // Identifier or keyword.
            if code[index].isLetter || code[index] == "_" {
                var end = code.index(after: index)
                while end < code.endIndex && (code[end].isLetter || code[end].isNumber || code[end] == "_") {
                    end = code.index(after: end)
                }
                let word = String(code[index..<end])
                result.append(makeRun(word, color: keywords.contains(word) ? keywordColor : base))
                index = end
                continue
            }
            // Punctuation / whitespace / newline: quiet base on the well.
            result.append(makeRun(String(code[index]), color: base))
            index = code.index(after: index)
        }
        return result
    }

    private static func renderInlineCode(_ code: String) -> AttributedString {
        var attr = AttributedString(code)
        attr.font = .system(.body, design: .monospaced)
        attr.backgroundColor = ZiroTheme.wellBackground
        attr.foregroundColor = ZiroTheme.primaryText
        return attr
    }

    private static func renderPlainText(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        attr.font = .body
        return attr
    }

    // MARK: - Helpers

    /// Extract numbered list item. Returns (number, text) or nil.
    private static func extractNumberedListItem(_ line: String) -> (number: Int, text: String)? {
        let pattern = /^(\d+)\.\s+(.+)$/
        if let match = line.wholeMatch(of: pattern) {
            if let number = Int(match.1) {
                return (number, String(match.2))
            }
        }
        return nil
    }
}

// MARK: - SwiftUI Extension

extension Text {
    /// Create a Text view from a markdown string.
    init(markdown: String) {
        self.init(MarkdownRenderer.render(markdown))
    }
}
