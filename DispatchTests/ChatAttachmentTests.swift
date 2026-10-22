import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DispatchApp

/// What the composer uploads for a picked, dropped or pasted file (ChatAttachmentImage) and how a transcript names
/// attachments (HelperChat.Record.attachments, ChatAttachment.merge). Fixture images are drawn here.
final class ChatAttachmentTests: XCTestCase {
    /// An opaque sRGB image: a gradient, or deterministic noise that compresses badly (a large PNG and JPEG).
    private func image(width: Int, height: Int, noise: Bool = false) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        if noise {
            let words = try XCTUnwrap(context.data).bindMemory(to: UInt64.self, capacity: width * height / 2)
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in 0..<(width * height / 2) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                words[index] = state
            }
        } else {
            for row in 0..<height {
                context.setFillColor(red: CGFloat(row) / CGFloat(height), green: 0.4, blue: 0.7, alpha: 1)
                context.fill(CGRect(x: 0, y: row, width: width, height: 1))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func encode(_ image: CGImage, _ type: UTType) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "Encoding \(type.identifier)")
        return data as Data
    }

    private func pixels(_ data: Data) throws -> (type: String, width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try XCTUnwrap(CGImageSourceGetType(source) as String?),
                try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int), try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    func testPortableImagesKeepTheirBytesAndOthersBecomeJPEG() throws {
        let picture = try image(width: 1200, height: 800)
        let png = try encode(picture, .png)
        let kept = try ChatAttachmentImage.prepare(name: "harbour chart.png", data: png)
        XCTAssertEqual(kept.name, "harbour chart.png")
        XCTAssertEqual(kept.kind, .image)
        XCTAssertEqual(kept.bytes, png, "A PNG within the limit is sent as it is")
        let thumbnail = try pixels(try XCTUnwrap(kept.thumbnail))
        XCTAssertEqual(thumbnail.type, UTType.jpeg.identifier)
        XCTAssertEqual(max(thumbnail.width, thumbnail.height), ChatAttachmentImage.thumbnailEdge)
        XCTAssertEqual(try ChatAttachmentImage.prepare(name: "chart", data: png).name, "chart.png",
                       "An agent recognizes an image path by its extension")

        for (type, name) in [(UTType.heic, "deck photo.heic"), (UTType.tiff, "scan.tiff"), (UTType.bmp, "Screen.BMP")] {
            let prepared = try ChatAttachmentImage.prepare(name: name, data: try encode(picture, type))
            XCTAssertEqual(prepared.kind, .image, name)
            XCTAssertEqual(prepared.name, (name as NSString).deletingPathExtension + ".jpg", name)
            let converted = try pixels(prepared.bytes)
            XCTAssertEqual(converted.type, UTType.jpeg.identifier, name)
            XCTAssertEqual([converted.width, converted.height], [1200, 800], "\(name) keeps its size")
        }
    }

    func testOversizedImagesAreScaledUnderTheLimit() throws {
        let png = try encode(try image(width: 3000, height: 3000, noise: true), .png)
        XCTAssertGreaterThan(png.count, ChatAttachment.limit)
        let prepared = try ChatAttachmentImage.prepare(name: "noise.png", data: png)
        XCTAssertEqual(prepared.kind, .image)
        XCTAssertEqual(prepared.name, "noise.jpg")
        XCTAssertLessThanOrEqual(prepared.bytes.count, ChatAttachment.limit)
        let scaled = try pixels(prepared.bytes)
        XCTAssertEqual(scaled.type, UTType.jpeg.identifier)
        XCTAssertLessThan(max(scaled.width, scaled.height), 3000, "Scaled down until it fits")
        XCTAssertEqual(scaled.width, scaled.height)
    }

    func testFilesAreKeptAsTheyAreAndRefusedOverTheLimit() throws {
        let notes = Data("Moored at the example quay.\n".utf8)
        let prepared = try ChatAttachmentImage.prepare(name: "log notes.txt", data: notes)
        XCTAssertEqual(prepared.kind, .file)
        XCTAssertEqual(prepared.name, "log notes.txt")
        XCTAssertEqual(prepared.bytes, notes)
        XCTAssertNil(prepared.thumbnail)
        // Image bytes named as something else are an image; bytes named .png that are no image are a file.
        XCTAssertEqual(try ChatAttachmentImage.prepare(name: "fake.png", data: notes).kind, .file)

        XCTAssertThrowsError(try ChatAttachmentImage.prepare(name: "archive.zip", data: Data(count: ChatAttachment.limit + 1))) {
            XCTAssertEqual($0 as? ChatAttachmentError, .tooLarge("archive.zip"))
        }
        XCTAssertNoThrow(try ChatAttachmentImage.prepare(name: "archive.zip", data: Data(count: ChatAttachment.limit)))
    }

    func testNamesAreCleaned() {
        XCTAssertEqual(ChatAttachmentImage.clean("../..hidden\u{7}name.png"), "hiddenname.png")
        XCTAssertEqual(ChatAttachmentImage.clean("folder/report.pdf"), "report.pdf")
        XCTAssertEqual(ChatAttachmentImage.clean(""), "attachment")
        XCTAssertEqual(ChatAttachmentImage.clean("..."), "attachment")
        XCTAssertEqual(ChatAttachmentImage.clean("  spaced.txt "), "spaced.txt")
        let long = ChatAttachmentImage.clean(String(repeating: "a", count: 300) + ".png")
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertTrue(long.hasSuffix(".png"))
    }

    /// The files a message read from a transcript names, in order, and the composer's copies they replace in place.
    func testRecordAttachmentsAndMergeKeepTheComposersThumbnails() throws {
        let path = "/home/example/.dispatch/attachments/0123456789abcdef0123456789abcdef/chart.png"
        let record = try JSONDecoder().decode(HelperChat.Record.self, from: JSONSerialization.data(withJSONObject: [
            "id": "u1", "turn": "t1", "kind": "user", "text": "look", "title": "", "output": "", "completed": true,
            "documents": [], "inline_reasoning": false, "blocks": [
                ["kind": "image", "path": path, "text": "chart.png"],
                ["kind": "markdown", "text": "ignored"],
                ["kind": "image", "path": NSNull(), "text": NSNull()],
                ["kind": "file", "path": "/home/example/.dispatch/attachments/fedcba9876543210fedcba9876543210/notes.txt", "text": NSNull()],
            ]]))
        XCTAssertEqual(record.attachments.map(\.name), ["chart.png", "Image", "notes.txt"])
        XCTAssertEqual(record.attachments.map(\.kind), [.image, .image, .file])
        XCTAssertEqual(record.attachments.map(\.id), ["u1#0", "u1#2", "u1#3"])
        guard case .item(let item)? = record.display?.action else { return XCTFail("A user record is an item") }
        XCTAssertEqual(item.attachments, record.attachments)

        let sent = [ChatAttachment(id: "a", name: "chart.png", kind: .image, size: 10, path: path, thumbnail: Data([1])),
                    ChatAttachment(id: "b", name: "deck.jpeg", kind: .image, size: 20, path: "/elsewhere/deck.jpeg", thumbnail: Data([2])),
                    ChatAttachment(id: "c", name: "notes.txt", kind: .file, size: 30, path: nil)]
        let merged = ChatAttachment.merge(record.attachments, keeping: sent)
        XCTAssertEqual(merged.map(\.id), ["a", "b", "c"], "Rows keep their identity")
        XCTAssertEqual(merged.map(\.thumbnail), [Data([1]), Data([2]), nil])
        XCTAssertEqual(merged[1].name, "deck.jpeg", "An unnamed image takes the sent one's name")
        XCTAssertEqual(merged[1].path, "/elsewhere/deck.jpeg")
        XCTAssertEqual(merged.map(\.size), [10, 20, 30])
        XCTAssertEqual(ChatAttachment.merge([], keeping: sent), sent, "A record of text alone keeps what was sent")
    }

    /// Each earlier attachment lends its identity once: a path match is not reused by position, positions count only
    /// the ones not matched yet, and an unmatched attachment never takes an id another one now has.
    func testMergeUsesEachEarlierAttachmentOnceAndKeepsIdsUnique() {
        let chart = "/home/example/.dispatch/attachments/0123456789abcdef0123456789abcdef/chart.png"
        let deck = "/home/example/.dispatch/attachments/fedcba9876543210fedcba9876543210/deck.png"
        let sent = [ChatAttachment(id: "a", name: "chart.png", kind: .image, size: 10, path: chart, thumbnail: Data([1])),
                    ChatAttachment(id: "b", name: "deck.png", kind: .image, size: 20, path: nil, thumbnail: Data([2]))]
        // The transcript names the second image first, by path, and the first without one.
        let record = [ChatAttachment(id: "u#0", name: "Image", kind: .image, size: 0, path: nil),
                      ChatAttachment(id: "u#1", name: "chart.png", kind: .image, size: 0, path: chart)]
        let merged = ChatAttachment.merge(record, keeping: sent)
        XCTAssertEqual(merged.map(\.id), ["b", "a"], "By path first, then by position among the rest")
        XCTAssertEqual(merged.map(\.thumbnail), [Data([2]), Data([1])])
        XCTAssertEqual(merged.map(\.name), ["deck.png", "chart.png"])

        // Another host copy is another file, even in the same position; its own id must not repeat one now taken.
        let earlier = [ChatAttachment(id: "u#1", name: "chart.png", kind: .image, size: 10, path: chart)]
        let later = [ChatAttachment(id: "u#0", name: "chart.png", kind: .image, size: 0, path: chart),
                     ChatAttachment(id: "u#1", name: "deck.png", kind: .image, size: 0, path: deck)]
        let again = ChatAttachment.merge(later, keeping: earlier)
        XCTAssertEqual(again[0].id, "u#1")
        XCTAssertEqual(Set(again.map(\.id)).count, 2, "\(again.map(\.id))")
        XCTAssertNil(again[1].thumbnail)
        XCTAssertEqual(again[1].path, deck)
        // No earlier image of that kind: nothing borrowed.
        let file = ChatAttachment.merge([ChatAttachment(id: "f", name: "File", kind: .file, size: 0, path: nil)], keeping: sent)
        XCTAssertEqual(file.map(\.id), ["f"])

        XCTAssertTrue(ChatAttachment.same(sent, record), "As many, and no path disagrees")
        XCTAssertFalse(ChatAttachment.same(sent, [sent[0]]))
        XCTAssertFalse(ChatAttachment.same([sent[0]], [ChatAttachment(name: "deck.png", kind: .image, size: 0, path: deck)]))
        XCTAssertTrue(ChatAttachment.same([], []))
    }

    /// A photo's GPS position, camera and author leave with neither the JPEG nor the PNG: the JPEG is copied without
    /// re-encoding (same pixels), its orientation kept; an image without such metadata is sent byte for byte.
    func testPhotoMetadataIsStrippedWithoutReencoding() throws {
        let picture = try image(width: 64, height: 48)
        func tagged(_ type: UTType) throws -> Data {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
            let properties: [CFString: Any] = [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                                kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E"],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Example Lens", kCGImagePropertyExifUserComment: "harbour"],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Example", kCGImagePropertyTIFFModel: "Camera One",
                                                 kCGImagePropertyTIFFOrientation: 6],
                kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCByline: "Sam Example"],
            ]
            CGImageDestinationAddImage(destination, picture, properties as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        func properties(_ data: Data) throws -> [CFString: Any] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        }
        /// The decoded pixels, as stored (orientation not applied).
        func decoded(_ data: Data) throws -> Data {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                                  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
        }
        for (type, name) in [(UTType.jpeg, "harbour.jpg"), (UTType.png, "harbour.png")] {
            let original = try tagged(type)
            XCTAssertNotNil(try properties(original)[kCGImagePropertyGPSDictionary], "The fixture carries GPS")
            let prepared = try ChatAttachmentImage.prepare(name: name, data: original)
            XCTAssertEqual(prepared.name, name)
            XCTAssertNotEqual(prepared.bytes, original)
            let kept = try properties(prepared.bytes)
            XCTAssertNil(kept[kCGImagePropertyGPSDictionary], name)
            XCTAssertNil(kept[kCGImagePropertyIPTCDictionary], name)
            XCTAssertNil((kept[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel], name)
            XCTAssertNil((kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake], name)
            XCTAssertEqual(kept[kCGImagePropertyOrientation] as? Int, 6, "\(name) stays upright")
            XCTAssertEqual(try pixels(prepared.bytes).type, type.identifier)
            XCTAssertEqual(try decoded(prepared.bytes), try decoded(original), "\(name): the same pixels, not re-compressed")
            let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.bytes as CFData, nil))
            XCTAssertFalse(ChatAttachmentImage.identifies(source, type: type), name)
        }
        let plain = try encode(picture, .jpeg)
        XCTAssertEqual(try ChatAttachmentImage.prepare(name: "plain.jpg", data: plain).bytes, plain, "Nothing to strip: as it is")
    }

    /// Thumbnails read from a host: an answer that will not change (`not_found`, `invalid_request`, no image) is not
    /// asked again; a lost link or a timeout is, after a wait that doubles.
    @MainActor
    func testThumbnailReadsRetryTransientFailuresOnly() {
        let cache = ChatAttachmentThumbnails()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let gone = ChatAttachmentThumbnails.Key(endpoint: .local, path: "/stored/gone.png")
        let flaky = ChatAttachmentThumbnails.Key(endpoint: .local, path: "/stored/flaky.png")
        let refused = ChatAttachmentThumbnails.Key(endpoint: .local, path: "/stored/refused.png")
        cache.finish(gone, .failure(HelperFailure(code: "not_found", message: "Gone.")), now: now)
        cache.finish(refused, .failure(HelperFailure(code: "invalid_request", message: "No.")), now: now)
        XCTAssertFalse(cache.asks(gone, now: now.addingTimeInterval(86_400)))
        XCTAssertFalse(cache.asks(refused, now: now.addingTimeInterval(86_400)))
        cache.finish(flaky, .failure(HelperFailure(code: "unavailable", message: "Not connected.")), now: now)
        XCTAssertFalse(cache.asks(flaky, now: now.addingTimeInterval(4)))
        XCTAssertTrue(cache.asks(flaky, now: now.addingTimeInterval(5)))
        cache.finish(flaky, .failure(CancellationError()), now: now)
        XCTAssertFalse(cache.asks(flaky, now: now.addingTimeInterval(9)), "The wait doubles")
        XCTAssertTrue(cache.asks(flaky, now: now.addingTimeInterval(10)))
        XCTAssertEqual(ChatAttachmentThumbnails.backoff(20), 300, "At most five minutes")
        cache.finish(flaky, .success(NSImage(size: NSSize(width: 2, height: 2))), now: now)
        XCTAssertFalse(cache.asks(flaky, now: now), "Shown")
        XCTAssertNotNil(cache.image(ChatAttachment(name: "flaky.png", kind: .image, size: 0, path: flaky.path), endpoint: .local))
    }

    /// Quick Look's private copies: the next preview replaces the last, and closing the panel or quitting removes them.
    @MainActor
    func testQuickLookCopiesAreRemoved() throws {
        let preview = ChatAttachmentPreview()
        let first = try XCTUnwrap(preview.write(Data("one".utf8), name: "notes.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(preview.acceptsControl)
        let second = try XCTUnwrap(preview.write(Data("two".utf8), name: "notes.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path), "Replaced")
        XCTAssertEqual(preview.item, second)
        preview.removeCopy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.deletingLastPathComponent().path), "Closed")
        XCTAssertFalse(preview.acceptsControl)
        let third = try XCTUnwrap(preview.write(Data("three".utf8), name: "notes.txt"))
        preview.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ChatAttachmentPreview.folder.path), "Quit")
    }

    /// This Mac's helper (feature `chat.attachments`): it keeps a private copy of what the app uploads, reads it back,
    /// and refuses empty uploads and paths outside its attachment folder.
    @MainActor
    func testTheLocalHelperStoresAndReadsAnAttachment() async throws {
        let features = await HelperApp.shared.features(.local)
        XCTAssertTrue(features.contains(ChatAttachment.feature), "\(features)")
        let connection = try await HelperApp.shared.connection()
        let prepared = try ChatAttachmentImage.prepare(name: "chart.png", data: try encode(try image(width: 64, height: 48), .png))
        let stored: HelperChat.StoredAttachment = try await connection.request(
            "attachments.put", params: HelperChat.AttachmentUpload(name: prepared.name, bytes: prepared.bytes))
        XCTAssertEqual(stored.kind, "image")
        XCTAssertEqual(stored.name, "chart.png")
        XCTAssertEqual(stored.size, UInt64(prepared.bytes.count))
        let parts = stored.path.split(separator: "/").suffix(3).map(String.init)
        XCTAssertEqual(parts.first, "attachments", stored.path)
        XCTAssertEqual(parts.dropFirst().first?.count, 32, stored.path)
        XCTAssertEqual(parts.last, "chart.png")
        XCTAssertEqual(stored.attachment(id: "a", thumbnail: prepared.thumbnail).kind, .image)

        let read: HelperChat.AttachmentBytes = try await connection.request("attachments.read", params: HelperChat.AttachmentRead(path: stored.path))
        XCTAssertEqual(read.bytes, prepared.bytes)
        XCTAssertEqual(read.size, stored.size)
        // The composer's upload: on the host's helper, not bound to a chat (no terminal needed).
        let notes = try await ChatCoordinator.put(.init(name: "log notes.txt", kind: .file, bytes: Data("Moored.\n".utf8)), endpoint: .local)
        XCTAssertEqual(notes.kind, "file")

        for (method, code) in [("attachments.put", "invalid_input"), ("attachments.read", "invalid_request")] {
            do {
                if method == "attachments.put" {
                    let _: HelperChat.StoredAttachment = try await connection.request(
                        method, params: HelperChat.AttachmentUpload(name: "empty.txt", bytes: Data()))
                } else {
                    let _: HelperChat.AttachmentBytes = try await connection.request(method, params: HelperChat.AttachmentRead(path: "/etc/hosts"))
                }
                XCTFail("\(method) must refuse")
            } catch let failure as HelperFailure {
                XCTAssertEqual(failure.code, code, method)
            }
        }
    }
}
