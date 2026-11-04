import XCTest
@testable import DispatchApp

/// The binary preview without a window: what a file's first bytes say it is, how the hex view reads pages, selects,
/// copies, finds strings and reads numbers.
@MainActor
final class FileHexTests: XCTestCase {
    private let base = "/Users/ivan/src/api"

    // MARK: Formats

    func testFormatsFromTheirHeaders() {
        let cases: [(String, [UInt8], [UInt8]?, String)] = [
            ("pie", Self.elf(type: 3, machine: 62, interpreter: true), nil, "ELF 64-bit LSB pie executable, x86-64"),
            ("so", Self.elf(type: 3, machine: 183, interpreter: false), nil, "ELF 64-bit LSB shared object, arm64"),
            ("object", Self.elf(type: 1, machine: 243, interpreter: false), nil, "ELF 64-bit LSB relocatable, RISC-V"),
            ("macho", Self.machO(cpu: 0x0100_000C, sub: 0, type: 2), nil, "Mach-O 64-bit executable, arm64"),
            ("dylib", Self.machO(cpu: 0x0100_000C, sub: 0x8000_0002, type: 6), nil, "Mach-O 64-bit dynamic library, arm64e"),
            ("fat", Self.fat([0x0100_0007, 0x0100_000C]), nil, "Mach-O universal (x86_64, arm64)"),
            ("java", [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 65], nil, "Java class, Java 21"),
            ("exe", Self.pe(machine: 0x8664, dll: false, wide: true, subsystem: 3), nil, "PE32+ executable (console), x86-64"),
            ("dll", Self.pe(machine: 0x14C, dll: true, wide: false, subsystem: 2), nil, "PE32 DLL (GUI), x86"),
            ("sqlite", Array("SQLite format 3\0".utf8) + [0x10, 0x00], nil, "SQLite 3 database, 4,096-byte pages"),
            ("sqlite64k", Array("SQLite format 3\0".utf8) + [0x00, 0x01], nil, "SQLite 3 database, 65,536-byte pages"),
            ("gzip", [0x1F, 0x8B, 8, 8, 0, 0, 0, 0, 0, 3] + Array("core.tar\0".utf8), nil,
             "gzip compressed data, was \u{201C}core.tar\u{201D}"),
            ("gzip plain", [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3], nil, "gzip compressed data"),
            ("zip", Self.zipHead("src/main.c"), Self.eocd(entries: 1), "zip archive, 1 entry"),
            ("docx", Self.zipHead("[Content_Types].xml"), Self.eocd(entries: 12, comment: "hi"),
             "Office Open XML document (zip), 12 entries"),
            ("epub", Self.zipHead("mimetype", stored: "application/epub+zip") + Array("PK\u{3}\u{4}".utf8), nil,
             "zip archive (application/epub+zip)"),
            ("zip64", Self.zipHead("a"), Self.eocd(entries: 0xFFFF), "zip archive, zip64"),
            ("png", Self.png(width: 512, height: 256), nil, "PNG image, 512 × 256, 8-bit RGBA"),
            ("jpeg", Self.jpeg(width: 400, height: 300), nil, "JPEG image, 400 × 300"),
            ("gif", Array("GIF89a".utf8) + [0x40, 0x01, 0xF0, 0x00], nil, "GIF image, 320 × 240"),
            ("pdf", Array("%PDF-1.7\n%".utf8) + [0xE2, 0xE3], nil, "PDF document, version 1.7"),
            ("tar", [UInt8](repeating: 0, count: 257) + Array("ustar\0".utf8) + [UInt8](repeating: 0, count: 249), nil,
             "tar archive"),
            ("wasm", [0x00, 0x61, 0x73, 0x6D, 1, 0, 0, 0], nil, "WebAssembly module, version 1"),
            ("pack", Array("PACK".utf8) + [0, 0, 0, 2, 0, 0, 0x04, 0xD2], nil, "git pack, version 2, 1,234 objects"),
            ("gguf", Array("GGUF".utf8) + [3, 0, 0, 0], nil, "GGUF model, version 3"),
            ("safetensors", [0x40, 0, 0, 0, 0, 0, 0, 0] + Array("{\"w\":".utf8), nil, "safetensors"),
            ("deb", Array("!<arch>\ndebian-binary   ".utf8), nil, "Debian package"),
            ("mp4", [0, 0, 0, 0x20] + Array("ftypisom".utf8), nil, "MPEG-4 (isom)"),
            ("mov", [0, 0, 0, 0x14] + Array("ftypqt  ".utf8), nil, "QuickTime movie"),
        ]
        for (name, head, tail, expected) in cases {
            XCTAssertEqual(FileFormat.describe(Data(head), tail: tail.map { Data($0) }), expected, name)
        }
        XCTAssertNil(FileFormat.describe(Data()))
        XCTAssertNil(FileFormat.describe(Data([0x41, 0x00, 0x42])), "Bytes no format starts with")
        XCTAssertEqual(FileFormat.describe(Data(Self.zipHead("a"))), "zip archive", "No tail: no count")
    }

    /// Every header cut short, and noise, names less or nothing; no read past the end traps.
    func testHeadersCutShortOrHostileNeverTrap() {
        let samples: [[UInt8]] = [
            Self.elf(type: 3, machine: 62, interpreter: true), Self.machO(cpu: 0x0100_000C, sub: 0, type: 2),
            Self.fat([0x0100_0007, 0x0100_000C]), Self.pe(machine: 0x8664, dll: false, wide: true, subsystem: 3),
            Self.zipHead("mimetype", stored: "application/epub+zip"), Self.png(width: 1, height: 1),
            Self.jpeg(width: 1, height: 1), [0x1F, 0x8B, 8, 0x0C, 0, 0, 0, 0, 0, 3, 0xFF, 0xFF],
        ]
        for sample in samples {
            for length in 0...sample.count {
                _ = FileFormat.describe(Data(sample.prefix(length)), tail: Data(sample.suffix(length)))
            }
        }
        XCTAssertEqual(FileFormat.describe(Data([0x7F, 0x45, 0x4C, 0x46, 2])), "ELF")
        // A program header table claimed far past the head, and a huge count.
        var hostile = Self.elf(type: 3, machine: 62, interpreter: false)
        Self.put(&hostile, 32, 0xFFFF_FFFF_FFFF_FF00, 8)
        Self.put(&hostile, 56, 0xFFFF, 2)
        XCTAssertEqual(FileFormat.describe(Data(hostile)), "ELF 64-bit LSB shared object, x86-64")
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<200 {
            let noise = (0..<Int(state % 600)).map { _ -> UInt8 in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 56)
            }
            _ = FileFormat.describe(Data(noise), tail: Data(noise.reversed()))
        }
    }

    func testZipEntryCountIsReadFromTheEnd() async throws {
        let source = FakeFilesSource.mockupAPI()
        let path = base + "/bundle.zip"
        var bytes = Self.zipHead("src/main.c") + [UInt8](repeating: 0, count: 200_000)
        bytes += Self.eocd(entries: 3)
        source.file(path, Data(bytes))
        let preview = try await loaded(path, in: source)
        guard case .binary(_, _, let format) = preview.kind else { return XCTFail("bundle.zip: \(preview.kind)") }
        XCTAssertEqual(format, "zip archive, 3 entries")
        XCTAssertEqual(source.calls.filter { $0 == "read \(path)" }.count, 2, "The first window, then the end once")
        XCTAssertTrue(FilesFormatting.meta(preview, now: Date(timeIntervalSince1970: 1_760_000_000))
            .hasPrefix("200 KB · zip archive, 3 entries"))
    }

    // MARK: Pages

    func testPagesAreReadAsTheirRowsShow() async throws {
        let (source, path, bytes, document) = try await binary(size: 300_000)
        XCTAssertEqual(document.byte(at: 100), bytes[100], "The loader's first window shows at once")
        XCTAssertNil(document.byte(at: 70_000))
        let reads = { source.calls.filter { $0 == "read \(path)" }.count }
        let before = reads()
        document.want(0..<4_096)
        XCTAssertEqual(document.readsInFlight, 0, "Rows the first window holds need no read")

        document.want(70_000..<70_100)
        try await TestSupport.eventually { document.byte(at: 70_000) != nil }
        XCTAssertEqual(document.bytes(at: 70_000, count: 4), Array(bytes[70_000..<70_004]))
        document.want(299_990..<300_000)
        try await TestSupport.eventually { document.byte(at: 299_999) != nil }
        XCTAssertEqual(document.byte(at: 299_999), bytes[299_999], "The last page is short")
        XCTAssertNil(document.byte(at: 300_000))
        XCTAssertEqual(reads() - before, 2)
        document.want(70_000..<70_100)
        XCTAssertEqual(document.readsInFlight, 0, "A page read is kept")
        XCTAssertEqual(document.loaded, 2)
    }

    func testAtMostTwoPagesReadAtOnceAndCloseStopsThem() async throws {
        let (source, path, _, document) = try await binary(size: 300_000)
        source.hangs = ["read \(path)"]
        document.want(65_536..<300_000)
        XCTAssertEqual(document.readsInFlight, FileHexDocument.concurrentReads)
        document.close()
        XCTAssertEqual(document.readsInFlight, 0)
        document.want(65_536..<300_000)
        XCTAssertEqual(document.readsInFlight, 0, "A closed document reads nothing")
    }

    func testAChangedFileStopsTheDocumentAndAFailureIsShown() async throws {
        let (source, path, _, document) = try await binary(size: 300_000)
        source.failures["read \(path)"] = .permissionDenied(path)
        document.want(70_000..<70_100)
        try await TestSupport.eventually { document.failure != nil }
        XCTAssertFalse(document.changed)

        source.failures = [:]
        source.file(path, Data(repeating: 0, count: 300_001))
        document.want(140_000..<140_100)
        try await TestSupport.eventually { document.changed }
        XCTAssertEqual(document.readsInFlight, 0)
    }

    // MARK: Selection

    func testSelectionClicksMovesAndExtends() {
        let document = FileHexDocument(path: "/x", size: 1_000, revision: nil, head: Data(count: 1_000), source: nil)
        document.click(10, extend: false)
        XCTAssertEqual(document.selection, 10...10)
        document.move(by: 16, extend: true)
        XCTAssertEqual(document.selection, 10...26)
        XCTAssertEqual(document.reveal?.offset, 26)
        XCTAssertEqual(document.reveal?.jump, false)
        document.move(by: -100, extend: false)
        XCTAssertEqual(document.selection, 0...0, "Clamped at the start")
        document.move(to: 5_000, extend: false)
        XCTAssertEqual(document.selection, 999...999, "Clamped at the end")
        document.click(5, extend: false)
        document.click(2, extend: true)
        XCTAssertEqual(document.selection, 2...5)
        document.drag(to: 40)
        XCTAssertEqual(document.selection, 5...40, "A drag runs from where the click started")
        document.selectAll()
        XCTAssertEqual(document.selection, 0...999)
        document.select(100..<104)
        XCTAssertEqual(document.selection, 100...103)
        XCTAssertEqual(document.reveal?.jump, true)
    }

    func testGoToOffsets() {
        let size: UInt64 = 300_000
        let cases: [(String, UInt64?)] = [
            ("0x1a0", 416), ("1A0", 416), ("$ff", 255), ("416", 416), (" 1_000 ", 1_000), ("-16", size - 16),
            ("end", size - 1), ("0", 0), ("0x", nil), ("zz", nil), ("300000", nil), ("-0", nil), ("-300001", nil), ("", nil),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(FileHexDocument.offset(text, size: size), expected, text)
        }
        XCTAssertNil(FileHexDocument.offset("0", size: 0))
    }

    // MARK: Copy

    func testCopyFormats() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(FileHexDocument.render(data, as: .hex), "de ad be ef")
        XCTAssertEqual(FileHexDocument.render(data, as: .base64), "3q2+7w==")
        XCTAssertNil(FileHexDocument.render(data, as: .text), "Not UTF-8")
        XCTAssertEqual(FileHexDocument.render(Data("héllo".utf8), as: .text), "héllo")
        XCTAssertEqual(FileHexDocument.render(Data(0..<14), as: .cArray), """
            unsigned char bytes[14] = {
                0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
                0x0c, 0x0d
            };
            """)
    }

    func testCopyReadsWhatIsNotLoadedAndRefusesPastTheLimit() async throws {
        let (_, _, bytes, document) = try await binary(size: 1_200_000)
        document.select(70_000..<70_004)
        let copied = await document.copyText(.hex)
        XCTAssertEqual(copied, bytes[70_000..<70_004].map { String(format: "%02x", $0) }.joined(separator: " "))
        XCTAssertEqual(document.notice, "Copied 4 bytes")
        document.selectAll()
        let refused = await document.copyText(.hex)
        XCTAssertNil(refused)
        XCTAssertEqual(document.notice, "Copy takes at most 1.0 MB: select less")
    }

    // MARK: Strings

    func testStringsScanContinuesRunsAcrossChunks() {
        let first = FileHexDocument.scanStrings(Data("ab\0hello world\0xyz\tw\u{1}tail".utf8), at: 100, continuing: nil, last: false)
        XCTAssertEqual(first.found, [
            .init(offset: 103, length: 11, text: "hello world"),
            .init(offset: 115, length: 5, text: "xyz w"),
        ], "Runs of four or more, a tab read as a space; \"ab\" is too short")
        XCTAssertEqual(first.run?.offset, 121, "\"tail\" may continue in the next chunk")
        let second = FileHexDocument.scanStrings(Data("ed\0".utf8), at: 125, continuing: first.run, last: false)
        XCTAssertEqual(second.found, [.init(offset: 121, length: 6, text: "tailed")])
        XCTAssertNil(second.run)
        let end = FileHexDocument.scanStrings(Data("\0last".utf8), at: 0, continuing: nil, last: true)
        XCTAssertEqual(end.found, [.init(offset: 1, length: 4, text: "last")], "The last chunk closes its run")

        let long = FileHexDocument.scanStrings(Data(repeating: 0x41, count: 300), at: 0, continuing: nil, last: true)
        XCTAssertEqual(long.found.first?.length, 300)
        XCTAssertEqual(long.found.first?.text, String(repeating: "A", count: FileHexDocument.stringShown) + " …")
    }

    func testStringsModeScansTheFileOnce() async throws {
        let source = FakeFilesSource.mockupAPI()
        let path = base + "/firmware.bin"
        var bytes = Data(count: 1_200_000)
        bytes.replaceSubrange(1_048_570..<1_048_585, with: Data("BOUNDARY-STRING".utf8))
        bytes.replaceSubrange(10..<16, with: Data("header".utf8))
        source.file(path, bytes)
        let preview = try await loaded(path, in: source)
        guard case .binary(let size, let head, _) = preview.kind else { return XCTFail("\(preview.kind)") }
        let document = FileHexDocument(path: path, size: size, revision: preview.revision, head: head, source: source)
        document.mode = .strings
        try await TestSupport.eventually { !document.scanning && document.scanned == size }
        XCTAssertEqual(document.strings, [
            .init(offset: 10, length: 6, text: "header"),
            .init(offset: 1_048_570, length: 15, text: "BOUNDARY-STRING"),
        ], "A string split between two reads is found whole")
        let reads = source.calls.count
        document.mode = .hex
        document.mode = .strings
        XCTAssertEqual(source.calls.count, reads, "Scanned once")
        document.close()
    }

    // MARK: Inspector

    func testInspectorReadsTheSelectionsBytes() {
        func values(_ bytes: [UInt8], little: Bool = true) -> [String: String] {
            Dictionary(uniqueKeysWithValues: FileHexDocument.values(bytes, littleEndian: little).map { ($0.label, $0.value) })
        }
        let one = values([0x00, 0x00, 0x80, 0x3F])
        XCTAssertEqual(one["8-bit"], "0")
        XCTAssertEqual(one["32-bit"], "1,065,353,216")
        XCTAssertEqual(one["float"], "1")
        XCTAssertEqual(one["64-bit"], "—", "Four bytes reach no 64-bit value")
        XCTAssertEqual(one["double"], "—")
        let big = values([0x00, 0x00, 0x80, 0x3F], little: false)
        XCTAssertEqual(big["32-bit"], "32,831")
        XCTAssertEqual(big["float"], "4.6006e−41")
        let negative = values([0xFF, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(negative["8-bit"], "255 (−1)")
        XCTAssertEqual(negative["16-bit"], "65,279 (−257)")
        XCTAssertEqual(negative["64-bit"], "18,446,744,073,709,551,359 (−257)")
        XCTAssertEqual(negative["double"], "NaN")
        XCTAssertEqual(values([0xA5])["bits"], "1010 0101")
        XCTAssertEqual(values([1, 2, 3])["32-bit"], "—")
        XCTAssertEqual(FileHexDocument.values([], littleEndian: true).map(\.value), Array(repeating: "—", count: 7),
                       "Every row stays while the page is read, so the inspector keeps its height")
        XCTAssertEqual(FileHexDocument.utf8(Array("hi".utf8)), "hi")
        XCTAssertNil(FileHexDocument.utf8([0xFF]))
        XCTAssertNil(FileHexDocument.utf8([UInt8](repeating: 0x41, count: 65)), "Past 64 bytes nothing is decoded")
    }

    // MARK: Support

    private func loaded(_ path: String, in source: any FilesSource) async throws -> FilePreviewState {
        let preview = FilePreviewState(path: path, entry: nil)
        await FilePreviewLoader.load(preview, from: source)
        return preview
    }

    /// A binary of `size` bytes (each its offset modulo 251, one NUL early), loaded, and its hex document.
    private func binary(size: Int) async throws -> (FakeFilesSource, String, Data, FileHexDocument) {
        let source = FakeFilesSource.mockupAPI()
        let path = base + "/core.bin"
        var bytes = Data((0..<size).map { UInt8($0 % 251) })
        bytes[3] = 0
        source.file(path, bytes)
        let preview = try await loaded(path, in: source)
        guard case .binary(let total, let head, _) = preview.kind else {
            XCTFail("core.bin did not load as binary: \(preview.kind)")
            throw CancellationError()
        }
        XCTAssertEqual(total, UInt64(size))
        let document = FileHexDocument(path: path, size: total, revision: preview.revision, head: head, source: source)
        addTeardownBlock { @MainActor in document.close() }
        return (source, path, bytes, document)
    }

    static func put(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64, _ width: Int, big: Bool = false) {
        if bytes.count < offset + width { bytes += [UInt8](repeating: 0, count: offset + width - bytes.count) }
        for index in 0..<width {
            let shift = big ? (width - 1 - index) * 8 : index * 8
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(shift))
        }
    }

    /// A 64-bit little-endian ELF header with two program headers, the second the interpreter when asked.
    static func elf(type: UInt16, machine: UInt16, interpreter: Bool) -> [UInt8] {
        var bytes: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1]
        put(&bytes, 16, UInt64(type), 2)
        put(&bytes, 18, UInt64(machine), 2)
        put(&bytes, 32, 64, 8)
        put(&bytes, 54, 56, 2)
        put(&bytes, 56, 2, 2)
        put(&bytes, 64, 6, 4)
        put(&bytes, 120, interpreter ? 3 : 1, 4)
        put(&bytes, 172, 0, 4)
        return bytes
    }

    static func machO(cpu: UInt32, sub: UInt32, type: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE]
        put(&bytes, 4, UInt64(cpu), 4)
        put(&bytes, 8, UInt64(sub), 4)
        put(&bytes, 12, UInt64(type), 4)
        return bytes
    }

    static func fat(_ cpus: [UInt32]) -> [UInt8] {
        var bytes: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]
        put(&bytes, 4, UInt64(cpus.count), 4, big: true)
        for (index, cpu) in cpus.enumerated() { put(&bytes, 8 + index * 20, UInt64(cpu), 4, big: true) }
        put(&bytes, 8 + cpus.count * 20, 0, 4)
        return bytes
    }

    static func pe(machine: UInt16, dll: Bool, wide: Bool, subsystem: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0x4D, 0x5A]
        put(&bytes, 0x3C, 0x80, 4)
        put(&bytes, 0x80, 0x0000_4550, 4)
        put(&bytes, 0x84, UInt64(machine), 2)
        put(&bytes, 0x80 + 22, dll ? 0x2022 : 0x0022, 2)
        put(&bytes, 0x98, wide ? 0x20B : 0x10B, 2)
        put(&bytes, 0x98 + 68, UInt64(subsystem), 2)
        return bytes
    }

    /// A zip's first local header naming `name`, with `stored` as its uncompressed content.
    static func zipHead(_ name: String, stored: String = "") -> [UInt8] {
        var bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        put(&bytes, 18, UInt64(stored.utf8.count), 4)
        put(&bytes, 22, UInt64(stored.utf8.count), 4)
        put(&bytes, 26, UInt64(name.utf8.count), 2)
        put(&bytes, 28, 0, 2)
        return bytes + Array(name.utf8) + Array(stored.utf8)
    }

    static func eocd(entries: UInt16, comment: String = "") -> [UInt8] {
        var bytes: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        put(&bytes, 8, UInt64(entries), 2)
        put(&bytes, 10, UInt64(entries), 2)
        put(&bytes, 20, UInt64(comment.utf8.count), 2)
        return bytes + Array(comment.utf8)
    }

    static func png(width: UInt32, height: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8)
        put(&bytes, 16, UInt64(width), 4, big: true)
        put(&bytes, 20, UInt64(height), 4, big: true)
        bytes += [8, 6, 0, 0, 0]
        return bytes
    }

    static func jpeg(width: UInt16, height: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + [UInt8](repeating: 0, count: 14)
        bytes += [0xFF, 0xC0, 0x00, 0x11, 0x08]
        put(&bytes, bytes.count, UInt64(height), 2, big: true)
        put(&bytes, bytes.count, UInt64(width), 2, big: true)
        return bytes + [3, 1, 0x22, 0]
    }
}
