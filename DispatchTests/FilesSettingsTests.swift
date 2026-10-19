import XCTest
@testable import DispatchApp

final class FilesSettingsTests: XCTestCase {
    func testSettingsWithoutFilesFieldsTakeTheDefaults() throws {
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.filesDragAndDrop, "Drag and drop is on by default")
        XCTAssertTrue(decoded.filesFollowShell)
        XCTAssertTrue(decoded.filesShowHidden, "Hidden files show until hidden")
        XCTAssertEqual(decoded.filesOpenWith, .editorInTab)
        XCTAssertTrue(decoded.filesAskBeforeReplacing)
        XCTAssertEqual(decoded, Preferences())
    }

    func testChangedFilesSettingsRoundTrip() throws {
        var changed = Preferences()
        changed.filesDragAndDrop = false
        changed.filesFollowShell = false
        changed.filesShowHidden = false
        changed.filesAskBeforeReplacing = false
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(decoded, changed)
        XCTAssertFalse(decoded.filesDragAndDrop)
        XCTAssertFalse(decoded.filesFollowShell)
        XCTAssertFalse(decoded.filesShowHidden)
        XCTAssertFalse(decoded.filesAskBeforeReplacing)
        for choice in FilesOpenWith.allCases {
            var preferences = changed
            preferences.filesOpenWith = choice
            XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)), preferences)
        }
        XCTAssertEqual(FilesOpenWith.editorInTab.title, "$EDITOR in this tab")
    }

    func testUnknownOpenWithChoiceKeepsTheOtherSettings() throws {
        let json = #"{"filesOpenWith":"unknownEditor","filesShowHiddenFiles":false,"filesDragAndDrop":false,"fontFamily":"0xProto"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.filesOpenWith, .editorInTab)
        XCTAssertFalse(decoded.filesShowHidden)
        XCTAssertFalse(decoded.filesDragAndDrop)
        XCTAssertEqual(decoded.fontFamily, "0xProto")
    }
}
