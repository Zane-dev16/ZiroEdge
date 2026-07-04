// OnboardingTests.swift
// ZiroEdgeTests
//
// Tests for onboarding first-launch detection and skip logic.

import XCTest
@testable import ZiroEdge

@MainActor
final class OnboardingTests: XCTestCase {

    // MARK: - hasCompletedOnboarding Defaults

    func testHasCompletedOnboardingDefaultsToFalse() {
        // A fresh UserDefaults suite should not have the key set.
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removeSuite(named: #function) }

        // bool(forKey:) returns false when key is absent.
        XCTAssertFalse(defaults.bool(forKey: "hasCompletedOnboarding"))
    }

    // MARK: - Setting Flag Prevents Onboarding

    func testSettingFlagPreventsOnboarding() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removeSuite(named: #function) }

        // Simulate completion.
        defaults.set(true, forKey: "hasCompletedOnboarding")

        let manager = OnboardingManager(defaults: defaults)
        XCTAssertFalse(manager.showOnboarding, "Onboarding should not show after flag is set")
    }

    // MARK: - Skip Sets the Flag

    func testSkipSetsFlag() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removeSuite(named: #function) }

        let manager = OnboardingManager(defaults: defaults)
        XCTAssertTrue(manager.showOnboarding, "Onboarding should show initially")

        manager.completeOnboarding()

        XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"), "Flag should be set after skip")
        XCTAssertFalse(manager.showOnboarding, "showOnboarding should be false after skip")
    }

    // MARK: - Completion Sets the Flag

    func testCompletionSetsFlag() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removeSuite(named: #function) }

        let manager = OnboardingManager(defaults: defaults)
        XCTAssertTrue(manager.showOnboarding, "Onboarding should show initially")

        // Simulate completing onboarding (same path as skip).
        manager.completeOnboarding()

        XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"), "Flag should be set after completion")
        XCTAssertFalse(manager.showOnboarding, "showOnboarding should be false after completion")

        // Verify re-creating the manager respects the flag.
        let manager2 = OnboardingManager(defaults: defaults)
        XCTAssertFalse(manager2.showOnboarding, "Onboarding should not show on subsequent launches")
    }

    // MARK: - Onboarding Does Not Reappear

    func testOnboardingNeverReappears() {
        let defaults = UserDefaults(suiteName: #function)!
        defer { defaults.removeSuite(named: #function) }

        let manager1 = OnboardingManager(defaults: defaults)
        XCTAssertTrue(manager1.showOnboarding)

        manager1.completeOnboarding()

        // Simulate app restart by creating a new manager.
        let manager2 = OnboardingManager(defaults: defaults)
        XCTAssertFalse(manager2.showOnboarding, "Onboarding should not appear after completion")

        // Even after multiple "restarts".
        let manager3 = OnboardingManager(defaults: defaults)
        XCTAssertFalse(manager3.showOnboarding, "Onboarding should never reappear")
    }
}
