import Foundation
import ImageIO
import XCTest
#if canImport(AppKit)
@testable import DispatchApp
#else
@testable import DispatchMobile
#endif

/// Shared Files byte and wire contracts, independent of a helper process or a preview's platform UI.
final class FilesSharedTests: XCTestCase {
    func testTimestampNumericFormsAndReadRevisionRoundTrip() throws {
        let decoder = JSONDecoder()
        for (json, expected) in [
            (#""170141183460469231731687303715884105727""#, "170141183460469231731687303715884105727"),
            ("-9223372036854775808", "-9223372036854775808"),
            ("18446744073709551615", "18446744073709551615"),
            ("0", "0")
        ] {
            let stamp = try decoder.decode(FilesWire.Stamp.self, from: Data(json.utf8))
            XCTAssertEqual(stamp.text, expected)
            XCTAssertEqual(try JSONEncoder().encode(stamp), Data(("\"" + expected + "\"").utf8))
        }

        let revision = FileRevision(kind: .file, size: .max, device: .max, inode: .max - 1,
                                    modifiedNs: "170141183460469231731687303715884105727", changedNs: "-1")
        let request = FilesWire.Read(path: "/work/source", offset: .max - 2, length: 8192, revision: revision)
        let encoded = try JSONEncoder().encode(request)
        struct Request: Decodable {
            let path: String
            let offset: UInt64
            let length: UInt64?
            let revision: FilesWire.Metadata?
        }
        let decoded = try decoder.decode(Request.self, from: encoded)
        XCTAssertEqual(decoded.path, "/work/source")
        XCTAssertEqual(decoded.offset, .max - 2)
        XCTAssertEqual(decoded.length, 8192)
        XCTAssertEqual(decoded.revision?.model, revision)
        let toEnd = try JSONEncoder().encode(FilesWire.Read(path: "/work/source", offset: 0, length: nil, revision: nil))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: toEnd) as? [String: Any])
        XCTAssertNil(fields["length"], "Only the Mac permits an absent read length")
        XCTAssertNil(fields["revision"])
    }

    func testListingsRetainUnsignedIdentitiesAndAllowOlderMissingFields() throws {
        let json = #"{"path":"/work","device":18446744073709551615,"inode":42,"truncated":false,"entries":[{"name":"link","kind":"symlink","size":7,"modified_ns":-1,"target":"file","device":5,"inode":18446744073709551614}]}"#
        let listing = try JSONDecoder().decode(FilesWire.Listing.self, from: Data(json.utf8)).model
        XCTAssertEqual(listing.identity, FileIdentity(device: .max, inode: 42))
        XCTAssertEqual(listing.entries.first?.identity, FileIdentity(device: 5, inode: .max - 1))
        XCTAssertEqual(listing.entries.first?.targetKind, .file)
        let older = #"{"path":"/work","truncated":true,"entries":[{"name":"future","kind":"new_kind","size":0,"modified_ns":"0"}]}"#
        let missing = try JSONDecoder().decode(FilesWire.Listing.self, from: Data(older.utf8)).model
        XCTAssertNil(missing.identity)
        XCTAssertNil(missing.entries.first?.identity)
        XCTAssertEqual(missing.entries.first?.kind, .other)
    }

    func testBinaryWireKeepsUnsignedNumbersAndStringStamps() throws {
        let revision = FileRevision(kind: .file, size: .max, device: .max - 1, inode: .max - 2,
                                    modifiedNs: "170141183460469231731687303715884105727", changedNs: "-1")
        let request = FilesWire.Read(path: "/work/source", offset: .max - 3, length: 8192, revision: revision)
        let encoded = try HelperBinary.value(encoding: request)
        guard case .object(let fields) = encoded, case .object(let metadata)? = fields["revision"] else {
            return XCTFail("A read carries its revision metadata")
        }
        XCTAssertEqual(fields["offset"], .unsigned(.max - 3))
        XCTAssertEqual(fields["length"], .unsigned(8192))
        XCTAssertEqual(metadata["device"], .unsigned(.max - 1))
        XCTAssertEqual(metadata["inode"], .unsigned(.max - 2))
        XCTAssertEqual(metadata["size"], .unsigned(.max))
        XCTAssertEqual(metadata["modified_ns"], .string(revision.modifiedNs))
        for (value, expected) in [(HelperBinary.Value.signed(.min), String(Int64.min)),
                                  (.unsigned(.max), String(UInt64.max)), (.string(revision.modifiedNs), revision.modifiedNs)] {
            let bytes = try HelperBinary.encode(value)
            let decoded = try HelperBinary.decode(bytes)
            XCTAssertEqual(try HelperBinary.decode(FilesWire.Stamp.self, from: decoded).text, expected)
        }
        XCTAssertEqual(try HelperBinary.decode(FilesWire.Metadata.self, from: .object(metadata)).model, revision)
    }

    func testUTF8AcceptsOnlyWellFormedIncompleteSuffixes() {
        for scalar in ["é", "€", "😀"] {
            let encoded = Array(scalar.utf8)
            for count in 1..<encoded.count {
                let window = Data([0x61] + encoded.prefix(count))
                XCTAssertEqual(FilePreviewContent.text(window, allowingIncompleteSuffix: true), "a")
                XCTAssertNil(FilePreviewContent.text(window), "An entire file cannot end inside a scalar")
            }
            XCTAssertEqual(FilePreviewContent.text(Data(scalar.utf8)), scalar)
        }
        for malformed: [UInt8] in [
            [0xFF], [0x80], [0xC0, 0xAF], [0xE0, 0x80], [0xED, 0xA0],
            [0xF0, 0x80], [0xF4, 0x90], [0xF5], [0xE2, 0x28], [0xF0, 0x90, 0x41]
        ] {
            let data = Data([0x61] + malformed)
            XCTAssertNil(FilePreviewContent.text(data, allowingIncompleteSuffix: true), "\(malformed)")
            XCTAssertNil(FilePreviewContent.text(data), "\(malformed)")
            XCTAssertEqual(FilePreviewContent.kind(name: "source.txt", size: 100, head: data, imageLimit: 32), .binary)
        }
    }

    func testUTF8BOMEmptyAndSlicedData() {
        XCTAssertEqual(FilePreviewContent.text(Data()), "")
        XCTAssertEqual(FilePreviewContent.text(Data([0xEF, 0xBB, 0xBF])), "")
        XCTAssertEqual(FilePreviewContent.text(Data([0xEF, 0xBB, 0xBF, 0x61])), "a")
        XCTAssertEqual(FilePreviewContent.text(Data([0xEF, 0xBB]), allowingIncompleteSuffix: true), "")
        let padded = Data([0xFF, 0xEF, 0xBB, 0xBF, 0x61, 0xE2])
        XCTAssertEqual(FilePreviewContent.text(padded.dropFirst(), allowingIncompleteSuffix: true), "a")
        XCTAssertNil(FilePreviewContent.text(padded.dropFirst()))
        XCTAssertEqual(FilePreviewContent.text(Data("a\u{FEFF}b".utf8)), "a\u{FEFF}b")
    }

    func testClassificationOrderAndImageBound() {
        let nul = Data([0])
        XCTAssertEqual(FilePreviewContent.kind(name: "photo.PNG", size: 32, head: nul, imageLimit: 32), .image)
        XCTAssertEqual(FilePreviewContent.kind(name: "photo.png", size: 33, head: nul, imageLimit: 32), .binary)
        XCTAssertEqual(FilePreviewContent.kind(name: "notes.md", size: 1, head: nul, imageLimit: 32), .binary)
        XCTAssertEqual(FilePreviewContent.kind(name: "notes.MD", size: 1, head: Data([0x61]), imageLimit: 32), .markdown)
        XCTAssertEqual(FilePreviewContent.kind(name: "empty", size: 0, head: Data(), imageLimit: 32), .text)
    }

    func testFailurePoliciesPreservePathAndConnectionMeaning() {
        let desktop = FilesSourceFailure.Context.desktop(host: nil)
        let mobile = FilesSourceFailure.Context.mobile(host: "test-host")
        for (code, expected) in [("changed", FilesSourceError.changed("/work/file")), ("permission_denied", .permissionDenied("/work/file")),
                                 ("is_directory", .isDirectory("/work/file")), ("cancelled", .cancelled)] {
            let failure = FilesSourceFailure(code: code, message: "")
            XCTAssertEqual(failure.error(path: "/work/file", context: desktop), expected)
            XCTAssertEqual(failure.error(path: "/work/file", context: mobile), expected)
        }
        let closed = FilesSourceFailure(code: "invalid_response", message: "")
        XCTAssertEqual(closed.error(path: "/work", context: desktop), .other(code: "disconnected", message: "This Mac’s helper is unavailable"))
        XCTAssertEqual(closed.error(path: "/work", context: mobile), .offline("test-host"))
        let limit = FilesSourceFailure(code: "limit", message: "read is too large")
        XCTAssertEqual(limit.error(path: "/work", context: mobile), .limit("read is too large"))
        let future = FilesSourceFailure(code: "future_code", message: "specific detail")
        XCTAssertEqual(future.error(path: "/work", context: desktop), .other(code: "future_code", message: "specific detail"))
    }

    func testOccurrenceBoundsAndUnicode() {
        let lines = ["aaaa", "É and é", "", "last"]
        XCTAssertEqual(TextOccurrences.scan(of: "aa", in: lines, limit: 10), [.init(line: 0, occurrence: 0), .init(line: 0, occurrence: 1)])
        XCTAssertEqual(TextOccurrences.scan(of: "é", in: lines, limit: 1), [.init(line: 1, occurrence: 0)])
        XCTAssertEqual(TextOccurrences.scan(of: "é", in: lines, limit: 2), [.init(line: 1, occurrence: 0), .init(line: 1, occurrence: 1)])
        XCTAssertTrue(TextOccurrences.scan(of: "", in: lines, limit: 10).isEmpty)
        XCTAssertTrue(TextOccurrences.scan(of: "aa", in: lines, limit: 0).isEmpty)
        XCTAssertTrue(TextOccurrences.scan(of: "aa", in: lines, limit: -1).isEmpty)
    }

    func testImageHeaderRotationAndThumbnailBounds() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(FilePreviewImage.pixelSize(data as Data), CGSize(width: 4, height: 12))
        let thumbnail = try XCTUnwrap(FilePreviewImage.thumbnail(data as Data, maxPixels: 500, dimensionLimit: 6))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 6)
        XCTAssertGreaterThan(thumbnail.height, thumbnail.width)
        XCTAssertNil(FilePreviewImage.pixelSize(Data("not an image".utf8)))
        XCTAssertFalse(FilePreviewImage.isSafeSize(CGSize(width: CGFloat.infinity, height: 1), dimensionLimit: 32_768))
        XCTAssertFalse(FilePreviewImage.isSafeSize(CGSize(width: 32_769, height: 1), dimensionLimit: 32_768))
        XCTAssertTrue(FilePreviewImage.isSafeSize(CGSize(width: 8_000, height: 8_000), dimensionLimit: 32_768, pixelLimit: 64_000_000))
        XCTAssertFalse(FilePreviewImage.isSafeSize(CGSize(width: 8_001, height: 8_000), dimensionLimit: 32_768, pixelLimit: 64_000_000))
    }
}
