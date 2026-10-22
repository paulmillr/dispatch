import XCTest
@testable import DispatchApp

/// Nautical's radar layout (HarbourChart): range by how much a tab needs you, bearing by host and space.
final class HarbourRadarTests: XCTestCase {
    private static let mini = HostID(rawValue: "ssh:mini")

    private func vessel(_ status: HarbourVessel.Status, host: HostID = .local, convoy: UUID, inRange: Bool = true) -> HarbourVessel {
        HarbourVessel(id: UUID(), name: "tab", host: host == .local ? "Local" : "mini", hostID: host, inRange: inRange,
                      status: status, since: nil, selected: false, shortcut: "", convoy: convoy)
    }

    func testTabsCloseOnTheHarbourAsTheyNeedYou() throws {
        let space = UUID()
        let vessels = [vessel(.anchor, convoy: space), vessel(.underWay, convoy: space), vessel(.inbound, convoy: space),
                       vessel(.calling, convoy: space)]
        let chart = HarbourChart(vessels)
        let distances = try vessels.map { try XCTUnwrap(chart.fixes[$0.id]).distance }
        XCTAssertEqual(distances, distances.sorted(by: >), "anchor, under way, inbound, calling: each nearer the harbour")
        for (vessel, distance) in zip(vessels, distances) { XCTAssertTrue(HarbourChart.band(vessel.status).contains(distance)) }
        // One tab per band sails on its convoy's middle bearing, so a tab keeps its bearing as its range changes.
        XCTAssertEqual(Set(vessels.compactMap { chart.fixes[$0.id]?.bearing }).count, 1)
    }

    func testHostsTakeSectorsAndSpacesSailInConvoys() throws {
        let api = UUID(), docs = UUID(), remote = UUID()
        let vessels = [vessel(.anchor, convoy: api), vessel(.calling, convoy: api), vessel(.anchor, convoy: docs),
                       vessel(.underWay, host: Self.mini, convoy: remote, inRange: false)]
        let chart = HarbourChart(vessels)
        XCTAssertEqual(chart.sectors.map(\.host), [.local, Self.mini])
        XCTAssertEqual(chart.sectors.first?.start, 0)
        XCTAssertEqual(chart.sectors.last?.end ?? 0, 360, accuracy: 0.001)
        XCTAssertEqual(chart.sectors.map(\.inRange), [true, false])
        // Shares follow the tabs: three local tabs and one remote, each sector one more.
        XCTAssertEqual(chart.sectors[0].end, 360 * 4 / 6, accuracy: 0.001)
        XCTAssertEqual(chart.convoys.map(\.leading), [true, false, true])
        for (vessel, convoy) in zip(vessels, [0, 0, 1, 2]) {
            let bearing = try XCTUnwrap(chart.fixes[vessel.id]).bearing
            XCTAssertTrue((chart.convoys[convoy].start...chart.convoys[convoy].end).contains(bearing))
        }
    }

    func testNorthStaysClearForTheBandNames() {
        let space = UUID()
        let chart = HarbourChart((0..<12).map { _ in vessel(.anchor, convoy: space) })
        for fix in chart.fixes.values { XCTAssertTrue((10...350).contains(fix.bearing), "\(fix.bearing)") }
        // A band's tabs alternate in and out, so neighbours on one arc keep apart.
        XCTAssertEqual(Set(chart.fixes.values.map(\.distance)).count, 2)
    }
}

