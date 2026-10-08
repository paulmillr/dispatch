import XCTest
@testable import DispatchApp

final class SSHStatisticsTests: XCTestCase {
    private func counters(_ time: Double, boot: String = "boot", busy: UInt64 = 10, total: UInt64 = 100, received: UInt64 = 1000) -> SSHStatisticsCounters {
        .init(boot: boot, monotonic: time, cpu: [.init(name: "cpu", busy: busy, total: total), .init(name: "cpu0", busy: busy, total: total)],
              network: [.init(name: "eth0", received: received, sent: received)])
    }

    func testFirstSampleUnknownAndRatesUseRemoteTime() {
        var rates = SSHStatisticsRates()
        let connection = SSHConnectionID()
        XCTAssertNil(rates.sample(counters(10), connection: connection).cpu)
        let next = rates.sample(counters(12, busy: 30, total: 200, received: 2000), connection: connection, date: .distantPast)
        XCTAssertEqual(next.cpu, 20)
        XCTAssertEqual(next.receivedPerSecond, 500)
        XCTAssertEqual(next.cores, [20])
    }

    func testReconnectionRebootClockAndCounterResets() {
        for replacement in [counters(12, boot: "new"), counters(9), counters(.nan), counters(12, busy: 1, total: 2, received: 1)] {
            var rates = SSHStatisticsRates()
            let connection = SSHConnectionID()
            _ = rates.sample(counters(10), connection: connection)
            let next = rates.sample(replacement, connection: connection)
            XCTAssertNil(next.cpu)
            XCTAssertNil(next.receivedPerSecond)
        }
        var rates = SSHStatisticsRates()
        _ = rates.sample(counters(10), connection: SSHConnectionID())
        XCTAssertNil(rates.sample(counters(12), connection: SSHConnectionID()).receivedPerSecond)
    }

    func testInterfaceChangesAndUnavailableFieldsStayUnknown() {
        var rates = SSHStatisticsRates()
        let connection = SSHConnectionID()
        _ = rates.sample(counters(10), connection: connection)
        var changed = counters(12, busy: 20, total: 200)
        changed.network = [.init(name: "en0", received: 2000, sent: 2000)]
        XCTAssertNil(rates.sample(changed, connection: connection).receivedPerSecond)
        changed.cpu = nil; changed.network = nil
        let sample = rates.sample(changed, connection: connection)
        XCTAssertNil(sample.cpu)
        XCTAssertNil(sample.receivedPerSecond)
    }
}

extension SSHStatisticsTests {
    private func processes(_ time: Double, boot: String = "boot", start: String = "10", cpu: UInt64 = 1_000_000_000, pid: Int32 = 7) -> SSHProcessCounters {
        .init(boot: boot, monotonic: time, truncated: false, processes: [.init(pid: pid, start: start, name: "worker", cpuNanos: cpu, rss: 8192)])
    }
    func testProcessRatesMemoryImmediatelyAndMulticore() throws {
        let connection = SSHConnectionID(); var rates = SSHProcessRates()
        let first = try rates.sample(processes(10), connection: connection)
        XCTAssertNil(first[0].cpu); XCTAssertEqual(first[0].memory, 8192)
        let second = try rates.sample(processes(12, cpu: 6_000_000_000), connection: connection)
        XCTAssertEqual(second[0].cpu, 250)
    }
    func testProcessBaselinesResetForIdentityClockCounterAndMissingObservations() throws {
        let connection = SSHConnectionID()
        for changed in [processes(12, boot: "reboot"), processes(12, start: "11"), processes(10), processes(9), processes(12, cpu: 1), processes(12, pid: 8)] {
            var rates = SSHProcessRates(); _ = try rates.sample(processes(10), connection: connection)
            XCTAssertNil(try rates.sample(changed, connection: connection)[0].cpu)
        }
        var rates = SSHProcessRates(); _ = try rates.sample(processes(10), connection: connection)
        XCTAssertNil(try rates.sample(processes(12), connection: SSHConnectionID())[0].cpu)
        _ = try rates.sample(.init(boot: "boot", monotonic: 13, truncated: true, processes: []), connection: connection)
        XCTAssertNil(try rates.sample(processes(14), connection: connection)[0].cpu)
    }
    func testProcessWireValidationAndInvalidSamplesResetRates() throws {
        var rates = SSHProcessRates(); let connection = SSHConnectionID()
        _ = try rates.sample(processes(10), connection: connection)
        for name in ["", "bad\nname", "bad\u{202e}name", String(repeating: "a", count: 129)] {
            let value = SSHProcessCounters(boot: "boot", monotonic: 11, truncated: false, processes: [.init(pid: 7, start: "10", name: name, cpuNanos: 0, rss: 0)])
            XCTAssertThrowsError(try rates.sample(value, connection: connection))
        }
        for value in [SSHProcessCounters(boot: "", monotonic: 11, truncated: false, processes: []),
                      .init(boot: "boot", monotonic: .nan, truncated: false, processes: []),
                      .init(boot: "boot", monotonic: 11, truncated: false, processes: processes(10).processes + processes(10).processes),
                      .init(boot: "boot", monotonic: 11, truncated: false, processes: [.init(pid: 0, start: "x", name: "name", cpuNanos: 0, rss: .max)])] {
            XCTAssertThrowsError(try rates.sample(value, connection: connection))
        }
        XCTAssertNil(try rates.sample(processes(12), connection: connection)[0].cpu)
    }
}
