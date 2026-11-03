import Foundation
import XCTest
#if canImport(AppKit)
@testable import DispatchApp
#else
@testable import DispatchMobile
#endif

/// The shared wire, chart, and announcement boundaries, without platform stores or audio/UI lifecycles.
final class SharedStatsVoiceTests: XCTestCase {
    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testSampleDecodingKeepsPlatformMissingFieldPolicies() throws {
        let partial = try decode(HostStatsWire.Sample.self, #"{"cpu":null}"#)
        XCTAssertNil(partial.cpu)
        XCTAssertNil(partial.memory)
        XCTAssertEqual(partial.load, [])
        XCTAssertEqual(try decode(HostStatsWire.Sample.self, #"{"load":null}"#).load, [])
        // A mobile sample ignores fields that only the Mac consumes, even if they are malformed.
        XCTAssertEqual(try decode(HostStatsWire.Sample.self, #"{"load":[1],"cores":"unused","uptime":false}"#).load, [1])
        for json in [#"{"cores":[],"uptime":10}"#, #"{"load":null,"cores":[],"uptime":10}"#,
                     #"{"load":[],"uptime":10}"#, #"{"load":[],"cores":[]}"#] {
            XCTAssertThrowsError(try decode(HostStatsWire.CompleteSample.self, json))
        }
        XCTAssertThrowsError(try decode(HostStatsWire.Sample.self, #"{"load":"invalid"}"#))
    }

    func testCompleteSampleProcessesAndDiskWireShapes() throws {
        let sample = try decode(HostStatsWire.CompleteSample.self,
            #"{"boot":"fixture","cpu":27,"cores":[20,34],"load":[1,2,3],"memory":[100,40],"swap":[50,10],"received_per_second":12,"sent_per_second":3,"uptime":99}"#)
        XCTAssertEqual(sample.boot, "fixture")
        XCTAssertEqual(sample.cpu, 27)
        XCTAssertEqual(sample.cores, [20, 34])
        XCTAssertEqual(sample.load, [1, 2, 3])
        XCTAssertEqual(sample.memory, [100, 40])
        XCTAssertEqual(sample.swap, [50, 10])
        XCTAssertEqual(sample.received, 12)
        XCTAssertEqual(sample.sent, 3)
        XCTAssertEqual(sample.uptime, 99)
        let processes = try decode(HostStatsWire.Processes.self,
            #"[[{"pid":42,"name":"fixture","cpu":null,"rss":null}],true]"#)
        XCTAssertTrue(processes.partial)
        XCTAssertEqual(processes.rows.first?.pid, 42)
        XCTAssertNil(processes.rows.first?.cpu)
        XCTAssertNil(processes.rows.first?.rss)
        XCTAssertThrowsError(try decode(HostStatsWire.Processes.self, #"{"rows":[],"partial":false}"#))
        XCTAssertThrowsError(try decode(HostStatsWire.Processes.self, #"[[]]"#))
        let disk = #"{"paths":["/fixture"],"total":100,"available":40}"#
        XCTAssertEqual(try decode(HostStatsWire.Disk.self, disk).available, 40)
        XCTAssertThrowsError(try decode(HostStatsWire.IdentifiedDisk.self, disk))
        let identified = try decode(HostStatsWire.IdentifiedDisk.self,
            #"{"identity":7,"paths":["/fixture"],"total":100,"available":40}"#)
        XCTAssertEqual(identified.identity, 7)
        XCTAssertEqual(identified.paths, ["/fixture"])
        XCTAssertEqual(identified.total, 100)
        XCTAssertEqual(identified.available, 40)
    }

    private struct Point {
        let date: Date
        let value: Double?
        init(_ seconds: Double, _ value: Double?) {
            date = Date(timeIntervalSinceReferenceDate: seconds)
            self.value = value
        }
    }

    private func bars(_ history: [Point], now: Double = 59, hold: Double = 20) -> [Double?] {
        StatisticsHistory.bars(history, at: Date(timeIntervalSinceReferenceDate: now), window: 60, count: 4,
                               hold: hold, date: { $0.date }, value: { $0.value })
    }

    func testBucketsUseFixedGridPeakAndOwnSamplesBeforeHeldValues() {
        let history = [Point(1, 40), Point(8, 10), Point(31, 90), Point(40, 120), Point(59, -3), Point(60, 100)]
        XCTAssertEqual(bars(history, hold: 35), [40, 90, 100, 0])
        XCTAssertEqual(bars([Point(1, 40), Point(31, 90)], hold: 35), [40, 90, 90, nil])
        XCTAssertEqual(bars([Point(1, 40), Point(31, 90)], now: 60, hold: 35), [90, 90, nil, nil])
        XCTAssertEqual(bars([Point(1, 40), Point(31, 90), Point(20, 10)], hold: 35), [40, 10, 90, nil],
                       "an own sample takes precedence over a held higher value")
        XCTAssertEqual(bars([Point(1, 40), Point(31, 90)], hold: 20), [40, nil, 90, nil], "Mac's shorter hold")
    }

    func testBucketHoldIncludesBoundaryAndMissingValuesStillAdvanceTime() {
        XCTAssertEqual(bars([Point(14, 20), Point(34, 60)]), [20, 60, 60, nil], "exactly 20 seconds")
        XCTAssertEqual(bars([Point(1, 20), Point(36, 60)], hold: 35), [20, 60, 60, nil], "phone's 35 s boundary")
        XCTAssertEqual(bars([Point(1, 20), Point(36.01, 60)], hold: 35), [20, nil, 60, nil])
        XCTAssertEqual(bars([Point(14, 20), Point(34.01, 60)]), [20, nil, 60, nil])
        XCTAssertEqual(bars([Point(1, 20), Point(29, nil), Point(46, 60)]), [20, nil, 60, 60],
                       "missing values do not bridge the silence before them")
        XCTAssertEqual(bars([Point(1, .nan), Point(31, .infinity), Point(46, 60)]), [nil, nil, nil, 60])
        XCTAssertEqual(bars([Point(31, 20), Point(14, 40), Point(46, 60)]), [40, nil, 20, 60],
                       "a backwards clock does not hold a value across it")
        XCTAssertEqual(StatisticsHistory.bars([Point(1, 20)], at: Date(), window: 60, count: 0, hold: 20,
                                              date: { $0.date }, value: { $0.value }), [])
    }

    func testSpokenMarkdownRendersInlineTextAndNamesCodeAndTables() {
        let markdown = "# Done\n\n- **one**\n- [two](https://example.com)\n\n---\n\n```swift\nsecret()\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |"
        XCTAssertEqual(SpokenMarkdown.text(markdown),
                       "Done\none\ntwo\nThere's a code block on screen.\nThere's a table on screen.")
        XCTAssertEqual(SpokenMarkdown.text("hello\u{202E}world"), "hello⟦RLO⟧world")
    }

    func testSpokenMarkdownBoundsUnicodeScalarsAndOnlyAppendsNoticeWhenTruncated() {
        let exact = String(repeating: "é", count: 1_500)
        XCTAssertEqual(SpokenMarkdown.text(exact), exact)
        XCTAssertEqual(SpokenMarkdown.text(exact + "x"), exact + " The rest is on screen.")
        let combined = "a" + String(repeating: "\u{0301}", count: 1_501)
        let bounded = SpokenMarkdown.bounded(combined, 1_500)
        XCTAssertEqual(bounded.unicodeScalars.count, 1_501, "1,500 scalars plus the ellipsis, even within one grapheme")
        XCTAssertEqual(bounded.unicodeScalars.last, "…")
    }

    func testSignatureExplanationsKeepEveryVerdictAndEffectiveKind() {
        XCTAssertEqual(GitSignatureExplanation.detail(nil, kind: .gpg), "Checking the GPG signature…")
        let cases: [(GitSignatureCheck.Verdict, String)] = [
            (.good(certified: true), "Good GPG signature"),
            (.good(certified: false), "Good GPG signature, key not certified"),
            (.bad, "Bad GPG signature"),
            (.unknownKey, "GPG signature from a key not in your keyring"),
            (.expiredSignature, "Expired GPG signature"),
            (.expiredKey, "GPG signature from an expired key"),
            (.revokedKey, "GPG signature from a revoked key"),
            (.unsigned, "Not signed"),
            (.unchecked("fixture unavailable"), "Signed with GPG · couldn’t check: fixture unavailable"),
        ]
        for (verdict, text) in cases {
            XCTAssertEqual(GitSignatureExplanation.detail(GitSignatureCheck(verdict: verdict), kind: .gpg), text)
        }
        XCTAssertEqual(GitSignatureExplanation.detail(
            GitSignatureCheck(verdict: .unknownKey, kind: .ssh, signer: "Alex Example", key: "SHA256:fixture"), kind: .gpg),
            "SSH signature from a key not in your allowed signers · Alex Example · SSH key: SHA256:fixture")
        XCTAssertEqual(GitSignatureExplanation.detail(
            GitSignatureCheck(verdict: .good(certified: true), signer: "Alex Example", key: "fixture"), kind: .x509),
            "Alex Example · X.509 key ID: fixture")
    }
}
