// MarkdownRendererTests.swift
// ZiroEdgeTests
//
// Tests for MarkdownRenderer: bold, italic, code, headers, lists.

import XCTest
@testable import ZiroEdge

final class MarkdownRendererTests: XCTestCase {

    func testPlainText() throws {
        let result = MarkdownRenderer.render("Hello, world!")
        let nsStr = NSAttributedString(result)
        XCTAssertGreaterThan(nsStr.length, 0)
    }

    func testBoldText() throws {
        let result = MarkdownRenderer.render("This is **bold** text.")
        let nsStr = NSAttributedString(result)
        XCTAssertGreaterThan(nsStr.length, 0)
        XCTAssertTrue(nsStr.string.contains("bold"))
    }

    func testItalicText() throws {
        let result = MarkdownRenderer.render("This is *italic* text.")
        let nsStr = NSAttributedString(result)
        XCTAssertGreaterThan(nsStr.length, 0)
        XCTAssertTrue(nsStr.string.contains("italic"))
    }

    func testInlineCode() throws {
        let result = MarkdownRenderer.render("Use `print()` in Swift.")
        let nsStr = NSAttributedString(result)
        XCTAssertTrue(nsStr.string.contains("print()"))
    }

    func testHeading() throws {
        let result = MarkdownRenderer.render("## Section Title")
        let nsStr = NSAttributedString(result)
        XCTAssertTrue(nsStr.string.contains("Section Title"))
    }

    func testBulletList() throws {
        let result = MarkdownRenderer.render("- Item one\n- Item two\n- Item three")
        let nsStr = NSAttributedString(result)
        XCTAssertTrue(nsStr.string.contains("Item one"))
        XCTAssertTrue(nsStr.string.contains("Item two"))
        XCTAssertTrue(nsStr.string.contains("Item three"))
    }

    func testNumberedList() throws {
        let result = MarkdownRenderer.render("1. First\n2. Second\n3. Third")
        let nsStr = NSAttributedString(result)
        XCTAssertTrue(nsStr.string.contains("First"))
        XCTAssertTrue(nsStr.string.contains("Second"))
        XCTAssertTrue(nsStr.string.contains("Third"))
    }

    func testCodeBlock() throws {
        let markdown = """
        ```swift
        let x = 42
        print(x)
        ```
        """
        let result = MarkdownRenderer.render(markdown)
        let nsStr = NSAttributedString(result)
        XCTAssertTrue(nsStr.string.contains("let x = 42"))
        XCTAssertTrue(nsStr.string.contains("print(x)"))
    }

    func testBlockquote() throws {
        let result = MarkdownRenderer.render("> This is a quote.")
        let nsStr = NSAttributedString(result)
        XCTAssertTrue(nsStr.string.contains("This is a quote"))
    }

    func testEmptyInput() throws {
        let result = MarkdownRenderer.render("")
        let nsStr = NSAttributedString(result)
        // Should not crash, may have empty or newline content.
        XCTAssertGreaterThanOrEqual(nsStr.length, 0)
    }

    // MARK: - Trailing Newline Regression

    func testNoTrailingNewline_plainText() throws {
        let result = MarkdownRenderer.render("Hello, world!")
        let string = NSAttributedString(result).string
        XCTAssertFalse(string.hasSuffix("\n"), "Plain text should not end with a trailing newline.")
    }

    func testNoTrailingNewline_multiline() throws {
        let result = MarkdownRenderer.render("Hello\nWorld")
        let string = NSAttributedString(result).string
        XCTAssertFalse(string.hasSuffix("\n"), "Multi-line text should not end with a trailing newline.")
    }

    func testNoTrailingNewline_withTrailingNewlineInput() throws {
        // Simulates a common LLM response that ends with \n.
        let result = MarkdownRenderer.render("Hello\nWorld\n")
        let string = NSAttributedString(result).string
        XCTAssertFalse(string.hasSuffix("\n"), "Input with trailing newline should not produce extra blank lines.")
    }

    func testNoTrailingNewline_multipleTrailing() throws {
        let result = MarkdownRenderer.render("Hello\n\n")
        let string = NSAttributedString(result).string
        XCTAssertFalse(string.hasSuffix("\n"), "Input with multiple trailing newlines should not produce blank lines.")
    }

    func testNoTrailingNewline_heading() throws {
        let result = MarkdownRenderer.render("# Title\n\nBody text")
        let string = NSAttributedString(result).string
        XCTAssertFalse(string.hasSuffix("\n"), "Heading + body should not end with trailing newline.")
    }

    func testMixedContent() throws {
        let markdown = """
        # Title

        This is a **bold** and *italic* paragraph with `code`.

        - Bullet one
        - Bullet two

        1. Number one
        2. Number two

        > A blockquote

        ```
        code block
        ```
        """
        let result = MarkdownRenderer.render(markdown)
        let nsStr = NSAttributedString(result)
        XCTAssertTrue(nsStr.string.contains("Title"))
        XCTAssertTrue(nsStr.string.contains("bold"))
        XCTAssertTrue(nsStr.string.contains("italic"))
        XCTAssertTrue(nsStr.string.contains("code"))
        XCTAssertTrue(nsStr.string.contains("Bullet one"))
        XCTAssertTrue(nsStr.string.contains("Number one"))
        XCTAssertTrue(nsStr.string.contains("A blockquote"))
        XCTAssertTrue(nsStr.string.contains("code block"))
    }
}
