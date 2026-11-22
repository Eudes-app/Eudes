import XCTest

/// Les mentions d’usage sont une condition d’exécution : sans `NSCameraUsageDescription`,
/// iOS termine l’app au premier accès à l’appareil photo, sans message ni journal.
final class PrivacyUsageTests: XCTestCase {
    private func usage(_ key: String) throws -> String {
        try XCTUnwrap(Bundle.main.infoDictionary?[key] as? String, "\(key) absent de l’Info.plist")
    }

    func testCameraUsageIsDeclared() throws {
        let text = try usage("NSCameraUsageDescription")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testMicrophoneUsageIsDeclared() throws {
        let text = try usage("NSMicrophoneUsageDescription")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
