import XCTest
@testable import Ferry

final class AppPasteRulesTests: XCTestCase {
    private var suite: String!
    private var rules: AppPasteRules!

    override func setUp() {
        suite = "ferry.test.rules.\(UUID().uuidString)"
        rules = AppPasteRules(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testUnknownAppsGetOneCommandVExcludedAppsDoNot() {
        XCTAssertEqual(rules.mode(for: "com.google.antigravity"), .oneCommandV)
        XCTAssertEqual(rules.mode(for: "com.anthropic.claudefordesktop"), .oneCommandV)
        XCTAssertEqual(rules.mode(for: "com.apple.Terminal"), .normalPaste)
        XCTAssertEqual(rules.mode(for: "dev.spectreax.ferry"), .normalPaste)
        XCTAssertEqual(rules.mode(for: nil), .normalPaste)
    }

    func testLearning() {
        let app = "com.example.chat"
        rules.record(.failed, for: app, name: "Chat")
        XCTAssertEqual(rules.mode(for: app), .oneCommandV, "one failure isn't enough")
        rules.record(.worked, for: app, name: "Chat")
        rules.record(.failed, for: app, name: "Chat")
        XCTAssertEqual(rules.mode(for: app), .oneCommandV, "a success resets the count")
        rules.record(.failed, for: app, name: "Chat")
        XCTAssertEqual(rules.mode(for: app), .normalPaste)
        rules.record(.worked, for: app, name: "Chat")
        XCTAssertEqual(rules.mode(for: app), .oneCommandV)
        XCTAssertEqual(rules.all.first?.rule.name, "Chat")
        XCTAssertFalse(rules.all.first?.rule.setByUser ?? true)
    }

    func testUserChoiceIsNeverRelearnedAndCanBeReset() {
        let app = "com.example.chat"
        rules.setMode(.oneCommandV, for: app, name: "Chat")
        rules.record(.failed, for: app, name: "Chat")
        rules.record(.failed, for: app, name: "Chat")
        XCTAssertEqual(rules.mode(for: app), .oneCommandV)
        rules.setMode(nil, for: app, name: "Chat")
        XCTAssertTrue(rules.all.isEmpty)
    }

    func testBrowsersAreNotDowngradedBySiteFailures() {
        for _ in 0..<3 { rules.record(.failed, for: "com.google.Chrome", name: "Chrome") }
        XCTAssertEqual(rules.mode(for: "com.google.Chrome"), .oneCommandV)
        rules.record(.worked, for: "com.google.Chrome", name: "Chrome")
        XCTAssertEqual(rules.all.first?.rule.mode, .oneCommandV)
    }

    func testExcludedAppsAreNeverRecorded() {
        rules.record(.worked, for: "com.apple.Terminal", name: "Terminal")
        XCTAssertTrue(rules.all.isEmpty)
    }

    func testRulesPersist() {
        rules.setMode(.normalPaste, for: "com.example.chat", name: "Chat")
        let reloaded = AppPasteRules(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(reloaded.mode(for: "com.example.chat"), .normalPaste)
    }

    func testFieldSuitability() {
        XCTAssertNil(TargetSnapshot(valueLength: 0, levels: []).unsuitableReason)
        XCTAssertNil(TargetSnapshot(valueLength: 0, levels: [], focusedRole: "AXGroup").unsuitableReason)
        XCTAssertEqual(TargetSnapshot(valueLength: 0, levels: [], focusedRole: "AXTextField", focusedSubrole: "AXSecureTextField").unsuitableReason, "password field")
        XCTAssertEqual(TargetSnapshot(valueLength: 0, levels: [], focusedRole: "AXTextField", focusedSubrole: "AXSearchField").unsuitableReason, "search field")
        XCTAssertEqual(TargetSnapshot(valueLength: 0, levels: [], focusedRole: "AXTextField").unsuitableReason, "single-line field")
    }
}
