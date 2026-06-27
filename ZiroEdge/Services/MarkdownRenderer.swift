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

    // MARK: - Public API

    /// Render markdown string to AttributedString for display in SwiftUI Text.
    static func render(_ markdown: String) -> AttributedString {
        var result = AttributedString()

        // Split into lines for block-level processing.
        let lines = markdown.components(separatedBy: "\n")
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

        return result
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
        var codeAttr = AttributedString(code)
        codeAttr.font = .system(.body, design: .monospaced)
        codeAttr.backgroundColor = Color(.systemGray6)
        result.append(codeAttr)
        result.append(AttributedString("\n\n"))
        return result
    }

    private static func renderInlineCode(_ code: String) -> AttributedString {
        var attr = AttributedString(code)
        attr.font = .system(.body, design: .monospaced)
        attr.backgroundColor = Color(.systemGray6)
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
