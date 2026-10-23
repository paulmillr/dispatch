import XCTest
@testable import DispatchApp

final class FilesSettingsTests: XCTestCase {
    func testSettingsWithoutFilesFieldsTakeTheDefaults() throws {
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.filesEnabled, "Files is on by default")
        XCTAssertTrue(decoded.filesDragAndDrop, "Drag and drop is on by default")
        XCTAssertTrue(decoded.filesShowHidden, "Hidden files show until hidden")
        XCTAssertEqual(decoded, Preferences())
    }

    func testChangedFilesSettingsRoundTrip() throws {
        var changed = Preferences()
        changed.filesEnabled = false
        changed.filesDragAndDrop = false
        changed.filesShowHidden = false
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(decoded, changed)
        XCTAssertFalse(decoded.filesEnabled)
        XCTAssertFalse(decoded.filesDragAndDrop)
        XCTAssertFalse(decoded.filesShowHidden)
    }

    @MainActor func testDragAndDropIsOffWithFiles() {
        let runtime = TerminalRuntime.shared, preferences = runtime.preferences
        defer { runtime.preferences = preferences }
        runtime.preferences.filesEnabled = true
        runtime.preferences.filesDragAndDrop = true
        XCTAssertTrue(FilesTransferSettings.enabled())
        runtime.preferences.filesEnabled = false
        XCTAssertFalse(FilesTransferSettings.enabled(), "the card's options are off with the card")
    }
}
