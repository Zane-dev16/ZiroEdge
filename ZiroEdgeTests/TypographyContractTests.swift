// TypographyContractTests.swift
// ZiroEdgeTests
//
// Type-stack contract: `ZiroType` names bundled faces by PostScript name, and
// `Info.plist` registers them by file name. Neither half fails loudly on its
// own — a missing font, a wrong PostScript name, or a dropped `UIAppFonts`
// key all render the SYSTEM face at the right size, so the whole app would
// quietly stop being ZiroEdge. These tests are the only thing that notices.
//
// They verify what ships in the bundle (hosted unit tests run inside
// ZiroEdge.app, so `UIFont(name:)` sees the app's registered fonts and
// `Bundle.main` is the app bundle). ZiroEdgeUITests covers how the faces
// actually look on screen.

import XCTest
import SwiftUI
import UIKit
import CoreText
@testable import ZiroEdge

final class TypographyContractTests: XCTestCase {

    /// The registered file names must match the built bundle exactly: this is
    /// the UIAppFonts half of the contract, asserted against the file names
    /// the app target was built with.
    private var registeredFontFiles: [String] {
        (Bundle.main.infoDictionary?["UIAppFonts"] as? [String]) ?? []
    }

    // MARK: - Faces

    /// Every `ZiroType.Face` PostScript name must resolve to a real font.
    /// This is the half that catches a file that never made it into the
    /// Resources build phase, a typo in the face table, or a `UIAppFonts`
    /// entry that names the file but not the face iOS registers from it.
    func testEveryFaceResolvesInTheBundle() {
        XCTAssertFalse(ZiroType.Face.allCases.isEmpty, "The type stack must ship at least one face")

        for face in ZiroType.Face.allCases {
            let font = UIFont(name: face.rawValue, size: 16)
            XCTAssertNotNil(font, "\(face.rawValue) must resolve — check Resources/Fonts and UIAppFonts")
            XCTAssertEqual(
                font?.fontName, face.rawValue,
                "\(face.rawValue) must resolve to ITSELF, not a substituted face"
            )
        }
    }

    /// Both halves of the pairing must agree: every face the type scale can
    /// render must be registered, and every registered file must be a face
    /// something can render. A file registered but unreferenced is dead
    /// weight; a face referenced but unregistered is a silent system-font
    /// fallback.
    func testUIFontsAndFaceTableAgree() {
        XCTAssertEqual(
            Set(registeredFontFiles), Set(ZiroType.Face.allCases.map(\.fileName)),
            "Info.plist UIAppFonts and ZiroType.Face must list exactly the same files"
        )
    }

    /// A `UIAppFonts` entry that names a file not actually in the bundle is
    /// ignored silently by iOS — and the face it was supposed to supply
    /// renders as the system font. Assert the files are there.
    func testEveryRegisteredFontFileIsBundled() {
        for file in registeredFontFiles {
            XCTAssertNotNil(
                Bundle.main.url(forResource: file, withExtension: nil),
                "\(file) is registered in UIAppFonts but missing from the app bundle"
            )
        }
    }

    // MARK: - Scale

    /// Dynamic Type parity: each role is anchored to the size its system text
    /// style resolves to at the default content size, then scaled by
    /// `relativeTo:` from there. If an anchor drifts, that role sits at the
    /// wrong optical size at EVERY content size, so assert the whole table
    /// against UIKit rather than trusting the numbers in Typography.swift.
    func testBaseSizesMatchTheSystemRamp() {
        let defaultTraits = UITraitCollection(preferredContentSizeCategory: .large)

        for (style, uiStyle) in Self.stylePairs {
            let systemSize = UIFont
                .preferredFont(forTextStyle: uiStyle, compatibleWith: defaultTraits)
                .pointSize
            XCTAssertEqual(
                ZiroType.baseSize(for: style), systemSize,
                "ZiroType.baseSize(for: .\(uiStyle)) must match the system ramp (default content size)"
            )
        }
    }

    /// `Font.TextStyle` ↔ `UIFont.TextStyle`, standing in for the system's
    /// own mapping so the anchor table can be checked against UIKit.
    private static let stylePairs: [(Font.TextStyle, UIFont.TextStyle)] = [
        (.largeTitle, .largeTitle),
        (.title, .title1),
        (.title2, .title2),
        (.title3, .title3),
        (.headline, .headline),
        (.subheadline, .subheadline),
        (.body, .body),
        (.callout, .callout),
        (.footnote, .footnote),
        (.caption, .caption1),
        (.caption2, .caption2)
    ]

    // MARK: - Role mapping

    /// Resolving a role is the only way to see which face it ACTUALLY renders
    /// with, and the rule that matters is the asymmetry: Orbitron owns the
    /// brand, Satoshi owns text, Space Mono owns telemetry — the display face
    /// must never end up on body copy. `Font.resolve(in:)` is iOS 26+; older
    /// runtimes skip (the faces themselves still resolve — that is covered
    /// above and does not need this API).
    func testTextRolesNeverResolveToTheDisplayFace() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Font.resolve(in:) needs iOS 26; face validity is covered above")
        }
        let context = EnvironmentValues().fontResolutionContext

        // (label, expected face, font)
        let brand: [(String, String, Font)] = [
            ("display", "Orbitron-Bold", ZiroType.display),
            ("wordmark", "Orbitron-SemiBold", ZiroType.wordmark)
        ]
        for (label, expected, font) in brand {
            XCTAssertEqual(
                postScriptName(of: font, in: context), expected,
                "\(label) is the brand voice and must render \(expected)"
            )
        }

        let copy: [(String, String, Font)] = [
            ("title", "Satoshi-Bold", ZiroType.title),
            ("heading", "Satoshi-Medium", ZiroType.heading),
            ("rowTitle", "Satoshi-Medium", ZiroType.rowTitle),
            ("body", "Satoshi-Regular", ZiroType.body),
            ("bodyMedium", "Satoshi-Medium", ZiroType.bodyMedium),
            ("bodyStrong", "Satoshi-Bold", ZiroType.bodyStrong),
            ("supporting", "Satoshi-Regular", ZiroType.supporting),
            ("footnote", "Satoshi-Regular", ZiroType.footnote),
            ("caption", "Satoshi-Regular", ZiroType.caption),
            ("micro", "Satoshi-Regular", ZiroType.micro),
            ("meta", "SpaceMono-Regular", ZiroType.meta),
            ("technical(.footnote)", "SpaceMono-Regular", ZiroType.technical()),
            ("technical(.caption2, .semibold)", "SpaceMono-Bold", ZiroType.technical(.caption2, .semibold))
        ]
        for (label, expected, font) in copy {
            XCTAssertEqual(
                postScriptName(of: font, in: context), expected,
                "\(label) must render \(expected)"
            )
        }
    }

    /// The user's own words and the accent-on-container buttons MUST land on a
    /// Bold face: `bodyStrong` exists because `.weight(.semibold)` on the
    /// Satoshi family resolves to Medium 500, not Bold — which would drop
    /// accent-on-`accentContainer` copy (3.84:1 / 3.20:1) below AA, since it
    /// clears the floor only as bold ≥14pt. Pins the platform behaviour the
    /// button styles and §4 of the spec depend on.
    func testSemiboldOnACustomFaceIsNotBold() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Font.resolve(in:) needs iOS 26")
        }
        let context = EnvironmentValues().fontResolutionContext
        XCTAssertEqual(
            postScriptName(of: ZiroType.body.weight(.semibold), in: context), "Satoshi-Medium",
            "If this ever resolves to Bold, bodyStrong can become .weight(.semibold)"
        )
        XCTAssertEqual(
            postScriptName(of: ZiroType.bodyStrong, in: context), "Satoshi-Bold",
            "bodyStrong is the AA-critical weight for accent-on-container copy"
        )
    }

    @available(iOS 26.0, *)
    private func postScriptName(of font: Font, in context: Font.Context) -> String {
        CTFontCopyPostScriptName(font.resolve(in: context).ctFont) as String
    }
}

private extension ZiroType.Face {
    /// The bundle file this face is registered from. Kept beside the face
    /// table so adding a face means touching one place.
    var fileName: String { "\(rawValue).ttf" }
}
