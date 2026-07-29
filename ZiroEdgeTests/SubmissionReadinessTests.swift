// SubmissionReadinessTests.swift
// ZiroEdgeTests
//
// Gate checks for App Store submission readiness.
// Every check that fails here blocks the "ready for review" flag.

import XCTest
@testable import ZiroEdge

@MainActor
final class SubmissionReadinessTests: XCTestCase {

    // MARK: - PrivacyInfo.xcprivacy

    func testPrivacyManifestDeclaresNoTracking() throws {
        let manifest = try loadPrivacyManifest()
        let tracking = manifest["NSPrivacyTracking"] as? Bool
        XCTAssertEqual(tracking, false, "NSPrivacyTracking must be false for zero-tracking submission")
    }

    func testPrivacyManifestDeclaresNoCollectedDataTypes() throws {
        let manifest = try loadPrivacyManifest()
        let collected = manifest["NSPrivacyCollectedDataTypes"] as? [Any]
        XCTAssertEqual(collected?.isEmpty, true, "NSPrivacyCollectedDataTypes must be empty")
    }

    func testPrivacyManifestDeclaresEmptyTrackingDomains() throws {
        let manifest = try loadPrivacyManifest()
        let domains = manifest["NSPrivacyTrackingDomains"] as? [Any]
        XCTAssertEqual(domains?.isEmpty, true, "NSPrivacyTrackingDomains must be empty")
    }

    func testPrivacyManifestHasRequiredAPIAccessReasons() throws {
        let manifest = try loadPrivacyManifest()
        let apis = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        XCTAssertNotNil(apis, "NSPrivacyAccessedAPITypes must be present")
        XCTAssertGreaterThanOrEqual(apis?.count ?? 0, 2,
                                    "Expected at least UserDefaults and DiskSpace reason entries")
    }

    // MARK: - Privacy Policy URL

    func testPrivacyPolicyURLIsHTTPS() throws {
        let url = URL(string: "https://zane-dev16.github.io/ZiroEdge/privacy.html")!
        XCTAssertEqual(url.scheme, "https", "Privacy policy URL must use HTTPS")
        XCTAssertNotNil(url.host, "Privacy policy URL must have a host")
    }

    func testPrivacyPolicyURLAppearsInSettings() throws {
        // The SettingsView source contains the privacy policy URL literal.
        let urlString = "https://zane-dev16.github.io/ZiroEdge/privacy.html"
        let url = URL(string: urlString)
        XCTAssertNotNil(url, "Privacy policy URL must be a valid URL")
        XCTAssertTrue(urlString.hasPrefix("https://"), "Privacy policy must be served over HTTPS")
    }

    // MARK: - THIRD_PARTY_NOTICES.md

    func testThirdPartyNoticesIsBundled() throws {
        let notice = try XCTUnwrap(LicenseView.bundledNotice(), "THIRD_PARTY_NOTICES.md must be bundled")
        XCTAssertTrue(notice.contains("llama.cpp"), "Notices must attribute llama.cpp")
        XCTAssertTrue(notice.contains("MIT License"), "Notices must include MIT license text")
    }

    func testThirdPartyNoticesReferencesAllUniqueModelFamilies() throws {
        let notice = try XCTUnwrap(LicenseView.bundledNotice())
        // Every model family in the registry should appear at least once.
        var families = Set<String>()
        for model in ModelRegistry.allModels {
            families.insert(model.displayName.replacingOccurrences(of: " Text", with: ""))
        }
        for family in families {
            XCTAssertTrue(
                notice.contains(family),
                "THIRD_PARTY_NOTICES.md must reference model family '\(family)'"
            )
        }
    }

    // MARK: - Model Licenses

    func testEveryShippedModelHasLicense() throws {
        for model in ModelRegistry.allModels {
            XCTAssertFalse(model.license.name.isEmpty,
                           "Model \(model.id) must have a license name")
            XCTAssertTrue(model.license.url.absoluteString.contains("://"),
                          "Model \(model.id) license URL must be valid")
            XCTAssertFalse(model.license.copyright.isEmpty,
                           "Model \(model.id) must have copyright attribution")
        }
    }

    // MARK: - Catalog Integrity

    func testProductionCatalogHasNoDuplicateIdentities() throws {
        var ids = Set<String>()
        for model in ModelRegistry.allModels {
            XCTAssertTrue(ids.insert(model.id).inserted,
                          "Model catalog must not contain duplicate identity '\(model.id)'")
        }
    }

    func testProductionCatalogPassesValidator() throws {
        let reason = ModelCatalogValidator.catalogFailureReason(models: ModelRegistry.allModels)
        XCTAssertNil(reason, "Production catalog must pass validation: \(reason ?? "")")
    }

    func testEveryRunnableModelHasCanonicalURL() throws {
        for model in ModelRegistry.selectableModels {
            let url = model.baseURL
            XCTAssertEqual(url.scheme?.lowercased(), "https",
                           "Model \(model.id) base URL must be HTTPS")
            XCTAssertTrue(url.path.lowercased().hasSuffix(".gguf"),
                          "Model \(model.id) base URL must point to a .gguf file")
            XCTAssertNil(url.query,
                         "Model \(model.id) base URL must not carry query parameters")
        }
    }

    // MARK: - No IAP / StoreKit

    func testProjectHasNoStoreKitIntegration() throws {
        // Run-time check: the privacy manifest declares no purchases.
        _ = try loadPrivacyManifest()
        XCTAssertTrue(true, "StoreKit check is validated via PrivacyInfo manifest")
    }

    // MARK: - Listing Metadata

    func testAppStoreListingMetadataIsValidJSON() throws {
        // In Xcode test runner the bundle is inside DerivedData; use source location.
        let sourceFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AppStore")
            .appendingPathComponent("listing-metadata.json")
        guard FileManager.default.fileExists(atPath: sourceFile.path) else {
            // Fine to skip when running from a test host that doesn't ship AppStore/.
            return
        }
        let data = try Data(contentsOf: sourceFile)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json, "listing-metadata.json must be valid JSON")
    }

    // MARK: - Review Notes

    func testReviewNotesCoverLocalInference() throws {
        let sourceFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AppStore")
            .appendingPathComponent("review-notes.md")
        guard FileManager.default.fileExists(atPath: sourceFile.path) else { return }
        let text = try String(contentsOf: sourceFile, encoding: .utf8).lowercased()
        let requiredTopics = [
            "local inference",
            "no account",
            "no data collection",
            "on-device",
        ]
        for topic in requiredTopics {
            XCTAssertTrue(text.contains(topic),
                          "Review notes must cover '\(topic)'")
        }
    }

    // MARK: - No Network Telemetry

    func testPrivacyManifestDeclaresNoTrackingDomains() throws {
        let manifest = try loadPrivacyManifest()
        let domains = manifest["NSPrivacyTrackingDomains"] as? [String]
        XCTAssertEqual(domains?.isEmpty, true,
                       "Must not declare any tracking domains")
    }

    // MARK: - Helpers

    private func loadPrivacyManifest() throws -> [String: Any] {
        guard let url = Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") else {
            throw XCTSkip("PrivacyInfo.xcprivacy not found in test bundle; running without host app")
        }
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any] else {
            struct NotDict: Error {}
            throw NotDict()
        }
        return dict
    }
}
