import Foundation
import XCTest
@testable import Orchard

final class AssistantPreferencesTests: XCTestCase {
    func testDefaultsAreAppliedToEmptySuite() {
        let defaults = isolatedDefaults()

        let preferences = AssistantPreferences.load(from: defaults)

        XCTAssertEqual(preferences.modelID, AssistantPreferences.defaultModelID)
        XCTAssertTrue(preferences.speakResponses)
        XCTAssertTrue(preferences.autoSubmitVoice)
        XCTAssertTrue(preferences.confirmActions)
        XCTAssertTrue(preferences.enableActions)
        XCTAssertFalse(preferences.onDeviceRecognition)
    }

    func testValuesRoundTripAndBlankModelUsesAccountDefault() {
        let defaults = isolatedDefaults()
        defaults.set("   ", forKey: PreferenceKeys.modelID)
        defaults.set(false, forKey: PreferenceKeys.speakResponses)
        defaults.set(true, forKey: PreferenceKeys.onDeviceRecognition)

        let preferences = AssistantPreferences.load(from: defaults)

        XCTAssertEqual(preferences.modelID, "")
        XCTAssertFalse(preferences.speakResponses)
        XCTAssertTrue(preferences.onDeviceRecognition)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "AssistantPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
