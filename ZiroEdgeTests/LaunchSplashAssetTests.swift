// LaunchSplashAssetTests.swift
// ZiroEdgeTests
//
// Splash-moment asset contract: the UILaunchScreen splash (AppLogoLaunch over
// LaunchBackground) and the in-app LaunchLoadingView must hand off seamlessly
// (ZiroTheme.pageBackground matches LaunchBackground in both appearances).
// These unit tests verify what ships in the bundle — the compiled asset
// catalog plus Info.plist — while ZiroEdgeUITests/LaunchLoadingTests proves
// the live identifiers + screenshot on-simulator.

import XCTest
@testable import ZiroEdge

final class LaunchSplashAssetTests: XCTestCase {

    // MARK: - Logo imageset

    /// The launch logo must resolve from the shipped asset catalog: the
    /// UILaunchScreen UIImageName and any in-app splash reference both
    /// depend on it, and a missing imageset renders the splash imageless.
    func testAppLogoLaunchImagesetIsBundled() {
        let logo = UIImage(named: "AppLogoLaunch")
        XCTAssertNotNil(logo, "AppLogoLaunch imageset must be bundled (UILaunchScreen UIImageName)")
        XCTAssertGreaterThan(logo?.size.width ?? 0, 0, "Bundled launch logo must have nonzero width")
        XCTAssertGreaterThan(logo?.size.height ?? 0, 0, "Bundled launch logo must have nonzero height")
    }

    /// The imageset source must carry all three launch scales (120/240/360pt
    /// artwork): the in-app AppLogo asset is a single-scale 1254px file that
    /// iOS renders cropped/zoomed on the splash, which is why the launch
    /// screen uses this dedicated imageset.
    func testAppLogoLaunchImagesetDeclaresAllScales() throws {
        let imagesetDir = try XCTUnwrap(
            sourceAssetDirectory()
                .appendingPathComponent("AppLogoLaunch.imageset"),
            "AppLogoLaunch.imageset must exist in the asset catalog source"
        )
        let contentsURL = imagesetDir.appendingPathComponent("Contents.json")
        let data = try Data(contentsOf: contentsURL)
        let contents = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let images = contents?["images"] as? [[String: Any]] ?? []
        let scales = Set(images.compactMap { $0["scale"] as? String })
        XCTAssertEqual(
            scales, ["1x", "2x", "3x"],
            "AppLogoLaunch.imageset must declare 1x/2x/3x scales"
        )
        for image in images {
            guard let filename = image["filename"] as? String else {
                return XCTFail("Every AppLogoLaunch scale entry must reference a file")
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: imagesetDir.appendingPathComponent(filename).path),
                "AppLogoLaunch scale file \(filename) must exist"
            )
        }
    }

    // MARK: - Background colorset

    /// LaunchBackground must resolve in both appearances: the splash renders
    /// before the app's trait collection exists, so a missing universal or
    /// dark variant flashes the wrong ground.
    func testLaunchBackgroundResolvesInBothAppearances() {
        let background = UIColor(named: "LaunchBackground")
        XCTAssertNotNil(background, "LaunchBackground colorset must be bundled (UILaunchScreen UIColorName)")

        let light = background?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = background?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertNotNil(light, "LaunchBackground must resolve in light appearance")
        XCTAssertNotNil(dark, "LaunchBackground must resolve in dark appearance")

        // Dark splash ground is the navy handoff token #0A0F1E (10, 15, 30).
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        dark?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(red, 10.0 / 255.0, accuracy: 0.02, "LaunchBackground dark red must match navy #0A0F1E")
        XCTAssertEqual(green, 15.0 / 255.0, accuracy: 0.02, "LaunchBackground dark green must match navy #0A0F1E")
        XCTAssertEqual(blue, 30.0 / 255.0, accuracy: 0.02, "LaunchBackground dark blue must match navy #0A0F1E")

        // The in-app loading surface sits on ZiroTheme.pageBackground, which
        // must equal the splash ground in both appearances for a seamless
        // handoff (warm paper #F7F3EC / navy #0A0F1E).
        let page = UIColor(ZiroTheme.pageBackground)
        let pageLight = page.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let pageDark = page.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        assertColorsEqual(
            pageLight, light,
            message: "pageBackground (light) must match LaunchBackground so the handoff is seamless"
        )
        assertColorsEqual(
            pageDark, dark,
            message: "pageBackground (dark) must match LaunchBackground so the handoff is seamless"
        )
    }

    // MARK: - Launch screen plist

    /// The generated Info.plist must wire the splash assets: without the
    /// UILaunchScreen dictionary the system shows a bare black launch.
    func testLaunchScreenPlistReferencesSplashAssets() {
        let launchScreen = Bundle.main.infoDictionary?["UILaunchScreen"] as? [String: Any]
        XCTAssertNotNil(launchScreen, "Info.plist must contain the UILaunchScreen dictionary")
        XCTAssertEqual(
            launchScreen?["UIColorName"] as? String, "LaunchBackground",
            "UILaunchScreen must reference the LaunchBackground colorset"
        )
        XCTAssertEqual(
            launchScreen?["UIImageName"] as? String, "AppLogoLaunch",
            "UILaunchScreen must reference the AppLogoLaunch imageset"
        )
    }

    // MARK: - Helpers

    /// Asset-catalog source directory, located relative to this test file so
    /// the scale-declaration check reads the checkout (not the compiled
    /// Assets.car, which no longer carries filenames).
    private func sourceAssetDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LaunchSplashAssetTests.swift -> ZiroEdgeTests
            .deletingLastPathComponent() // ZiroEdgeTests -> app root
            .appendingPathComponent("ZiroEdge/Resources/Assets.xcassets", isDirectory: true)
    }

    private func assertColorsEqual(
        _ lhs: UIColor, _ rhs: UIColor?,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let rhs else {
            return XCTFail("Missing comparison color: \(message)", file: file, line: line)
        }
        var lr: CGFloat = 0, lg: CGFloat = 0, lb: CGFloat = 0, la: CGFloat = 0
        var rr: CGFloat = 0, rg: CGFloat = 0, rb: CGFloat = 0, ra: CGFloat = 0
        lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la)
        rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)
        XCTAssertEqual(lr, rr, accuracy: 0.02, message, file: file, line: line)
        XCTAssertEqual(lg, rg, accuracy: 0.02, message, file: file, line: line)
        XCTAssertEqual(lb, rb, accuracy: 0.02, message, file: file, line: line)
    }
}
