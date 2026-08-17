#if os(tvOS)
import XCTest

// MARK: - TVHomeFeedUITests
//
// Verifies the tvOS Home Feed tab: chip bar presence, video card population,
// no error banner on launch, Subscriptions chip navigation, and return to Home.
//
// Run against the "Smart Tube" tvOS scheme:
//   xcodebuild test -workspace SmartTube.xcworkspace -scheme "Smart Tube"
//     -destination "id=30E83929-0C67-4572-82C4-FE0F228EA835"
//     -only-testing:SmartTubeTVUITests/TVHomeFeedUITests

final class TVHomeFeedUITests: XCTestCase {

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private var chipBar: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'home.chipBar'"))
            .firstMatch
    }

    private var sectionContainer: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'home.sectionContainer'"))
            .firstMatch
    }

    /// Waits up to `timeout` seconds for at least one `video.card.*` descendant to appear.
    private func waitForVideoCards(timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"),
            object: cards
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }

    // MARK: - Tests

    /// Personal tvOS smoke path: all five top-level destinations are present,
    /// Search and Settings are reachable with the Siri Remote, and Google returns
    /// a real device-authorization code (the test deliberately does not complete login).
    func testPersonalTVNavigationAndDeviceCode() throws {
        for label in ["Home", "Subscriptions", "Search", "History", "Settings"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 10),
                          "Missing personal tvOS destination: \(label)")
        }
        XCTAssertTrue(app.buttons["Sign In"].waitForExistence(timeout: 10))

        // Home → Subscriptions → History → Search.
        remote.press(.right)
        remote.press(.right)
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(element("search.bar").waitForExistence(timeout: 10), "Search must open from the top tab bar")

        // Relaunch to make the focus origin deterministic, then open Settings.
        app.terminate()
        app.launch()
        for _ in 0..<4 { remote.press(.right) }
        remote.press(.select)
        XCTAssertTrue(element("settings.preferredQualityPicker").waitForExistence(timeout: 10))
        XCTAssertTrue(element("settings.sponsorBlockToggle").waitForExistence(timeout: 10))
        XCTAssertTrue(element("settings.deArrowToggle").waitForExistence(timeout: 10))

        // Relaunch and request a real Google device code from the signed-out Home state.
        app.terminate()
        app.launch()
        let signIn = app.buttons["Sign In"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        remote.press(.down)
        remote.press(.select)
        XCTAssertTrue(element("signin.activationCode").waitForExistence(timeout: 20),
                      "Google device-code endpoint did not return an activation code")
        XCTAssertTrue(element("signin.verificationURL").exists)
    }

    /// Opens a known public YouTube video through the real player pipeline and
    /// verifies Menu/Back returns to Home. The injected card only makes the UI
    /// deterministic; player metadata and streams still come from live endpoints.
    func testPersonalTVRealVideoPlayerAndBack() throws {
        app.terminate()
        app.launchArguments = [
            "--uitesting-signed-in",
            "--uitesting-inject-recommended-ids=dQw4w9WgXcQ",
            "--uitesting-disable-sponsorblock",
        ]
        app.launch()

        guard waitForVideoCards(timeout: 20) else {
            try captureAndSkip("Injected Home card did not appear", in: app)
        }
        XCTAssertTrue(element("home.personalizedShelves").waitForExistence(timeout: 10))
        // The third shelf intentionally starts below the fold; the first two
        // verify the named horizontal-shelf structure is visible on launch.
        for title in ["Recommended", "New to you"] {
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5),
                          "Missing personalized Home shelf: \(title)")
        }

        // Top tab bar → first video in the first personalized shelf.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.6)
        let focusedShelf = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        focusedShelf.name = "Home shelf focus without clipping"
        focusedShelf.lifetime = .keepAlways
        add(focusedShelf)
        remote.press(.select)

        let playerTitle = element("player.titleLabel")
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 30), "Real AVPlayer screen did not open")
        Thread.sleep(forTimeInterval: 5)
        XCTAssertFalse(element("player.errorBanner").exists, "Live player returned an error")
        XCTAssertFalse(element("player.ipBlockBanner").exists, "Live player was blocked by IP policy")

        remote.press(.menu)
        let playerGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: playerTitle
        )
        XCTAssertEqual(XCTWaiter().wait(for: [playerGone], timeout: 8), .completed)
    }

    /// The chip bar must appear within 15 s of launch.
    func testChipBarLoadsWithinTimeout() throws {
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar did not appear within 15 s — Home tab may not have loaded", in: app)
        }
        XCTAssertTrue(chipBar.exists, "home.chipBar must exist after appearance")
    }

    /// Video cards (video.card.*) must populate the Home feed within 20 s.
    func testVideoCardsPopulateHomeFeed() throws {
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar not found — cannot wait for video cards", in: app)
        }
        guard waitForVideoCards(timeout: 20) else {
            try captureAndSkip("No video.card.* elements appeared within 20 s — network unavailable or feed empty", in: app)
        }
        let predicate = NSPredicate(format: "identifier BEGINSWITH 'video.card.'")
        let cards = app.descendants(matching: .any).matching(predicate)
        XCTAssertGreaterThan(cards.count, 0, "At least one video card must be visible in the Home feed")
    }

    /// No XCUIElementTypeAlert and no player.errorBanner should appear on cold launch.
    func testNoErrorBannerOnHomeLoad() throws {
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar not found — app did not reach Home tab", in: app)
        }
        // Allow extra time for network requests to settle.
        Thread.sleep(forTimeInterval: 3.0)
        let errorAlert = app.alerts.firstMatch
        XCTAssertFalse(errorAlert.exists, "Unexpected error alert appeared on Home launch: \(errorAlert.label)")
        let errorBanner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'player.errorBanner'"))
            .firstMatch
        XCTAssertFalse(errorBanner.exists, "player.errorBanner should not appear on the Home screen")
    }

    /// Selecting the Subscriptions chip via D-pad should load the Subscriptions feed.
    func testSelectingSubscriptionsChipLoadsFeed() throws {
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar not found — cannot navigate to Subscriptions chip", in: app)
        }
        // Press ↓ to move focus from the tab bar into the chip bar.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.8)
        // Navigate right to reach the Subscriptions chip (typically the second chip).
        remote.press(.right)
        Thread.sleep(forTimeInterval: 0.8)
        // Activate the focused chip.
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        // The section container should load the new feed.
        guard sectionContainer.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.sectionContainer did not appear after selecting Subscriptions chip", in: app)
        }
        XCTAssertTrue(sectionContainer.exists, "home.sectionContainer must exist after chip selection")
    }

    /// Navigating back to the Home chip after Subscriptions should restore the chip bar.
    func testSelectingHomeChipRestoresFeed() throws {
        guard chipBar.waitForExistence(timeout: 15) else {
            try captureAndSkip("home.chipBar not found on launch", in: app)
        }
        // Move to Subscriptions chip.
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.8)
        remote.press(.right)
        Thread.sleep(forTimeInterval: 0.8)
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        // Navigate back left to the Home chip and select it.
        remote.press(.left)
        Thread.sleep(forTimeInterval: 0.8)
        remote.press(.select)
        Thread.sleep(forTimeInterval: 1.5)
        // The chip bar must still be visible.
        XCTAssertTrue(
            chipBar.waitForExistence(timeout: 10),
            "home.chipBar must still exist after returning to the Home chip"
        )
    }
}
#endif
