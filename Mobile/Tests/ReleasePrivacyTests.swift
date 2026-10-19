import XCTest
@testable import DispatchMobile

/// docs/security.md (Dispatch for iPhone): every file the app keeps is owner-only and out of device backups, so a
/// backup restored onto another phone brings no host, key, trusted host key, cache or activity along.
@MainActor
final class ReleasePrivacyTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func assertPrivate(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, url.lastPathComponent, file: file, line: line)
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .complete, url.lastPathComponent, file: file, line: line)
        } else {
            // Simulator files live on the Mac filesystem, which accepts the attribute but does not report an iOS
            // protection class. A real device must expose the Class A value.
            #if !targetEnvironment(simulator)
            XCTFail("Missing NSFileProtectionComplete: \(url.lastPathComponent)", file: file, line: line)
            #endif
        }
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, url.lastPathComponent, file: file, line: line)
    }

    func testTabActivityIsPrivateAndOutOfBackups() throws {
        let url = directory.appendingPathComponent("tab-activity.json")
        let host = UUID(), now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let store = TabActivityStore(url: url)
        store.note(host: host, key: "%1", at: now)
        store.save()
        try assertPrivate(url)
        XCTAssertEqual(TabActivityStore(url: url).date(host: host, key: "%1"), now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["tab-activity.json"])
    }

    func testStoreDocumentsArePrivateAndOutOfBackups() throws {
        struct Document: Codable { var version = 1; var value = "x" }
        let url = directory.appendingPathComponent("hosts.json")
        try MobileFiles.write(Document(), to: url)
        try assertPrivate(url)
        XCTAssertEqual(MobileFiles.read(Document.self, from: url, version: 1)?.value, "x")
    }
}
