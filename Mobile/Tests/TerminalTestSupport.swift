import Foundation
import UIKit
import XCTest
@_spi(Test) import Term
@testable import DispatchMobile

/// Reading the emulator's cells (Term's test SPI) and driving a session or host view in tests.
struct TerminalCell {
    var text: String
    var style: Style
    var wide: Cell.Wide
}

extension TerminalSession {
    /// A session at a known grid: `columns` x `rows` cells of the default font at scale 3, no padding beyond the
    /// configuration's.
    @MainActor static func testing(columns: Int = 40, rows: Int = 12, configuration: TerminalConfiguration = TerminalConfiguration()) throws -> TerminalSession {
        let session = try TerminalSession(configuration: configuration, scale: 3)
        let cell = session.currentSize
        let padding = session.locked { session.surface.size.padding }
        let width = Double(columns * cell.cellWidth + padding.left + padding.right) / 3
        let height = Double(rows * cell.cellHeight + padding.top + padding.bottom) / 3
        session.setSize(width: width + 0.1, height: height + 0.1)
        return session
    }

    func feed(_ text: String) { feed(Data(text.utf8)) }

    /// The active screen's cell at a viewport position.
    func cell(_ x: Int, _ y: Int) -> TerminalCell {
        locked {
            let view = surface.terminal.view
            let screen = view.isAlternate ? view.alternate! : view.primary
            let pin = screen.pin(.viewport, x: x, y: y)!
            let c = pin.page.cell(pin.cell)
            let text = c.codepoint == 0 ? " " : String(Character(UnicodeScalar(c.codepoint)!))
            return TerminalCell(text: text, style: pin.page.style(c.styleID), wide: c.wide)
        }
    }

    /// A viewport row's characters (spacer cells of wide characters left out), trailing blanks trimmed.
    func row(_ y: Int) -> String {
        let columns = locked { surface.terminal.grid.cols }
        var out = ""
        for x in 0..<columns {
            let c = cell(x, y)
            if c.wide == .spacerTail || c.wide == .spacerHead { continue }
            out += c.text
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    var cursor: (x: Int, y: Int) {
        locked {
            let view = surface.terminal.view
            let screen = view.isAlternate ? view.alternate! : view.primary
            return (screen.view.cursor.x, screen.view.cursor.y)
        }
    }

    var isAlternate: Bool { locked { surface.terminal.isAlternate } }
}

extension ScriptedHelper {
    /// A helper for terminal feeds: answers every request at once except the methods in `open`, which the test answers
    /// later (`reply`).
    static func terminal(open: Set<String> = ["terminals.attach"]) -> ScriptedHelper {
        ScriptedHelper { open.contains($0.method) ? .open : .empty }
    }

    /// A terminal update on the attach subscription `id`.
    func notify(_ id: UInt64, _ update: HelperClient.Update, method: String) {
        notify(id, method, value: try! update.encode())
    }
}

/// Collects what a session or a host view sends to the program.
final class SentBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var data: Data { lock.withLock { bytes } }
    var text: String { String(decoding: data, as: UTF8.self) }
    func clear() { lock.withLock { bytes.removeAll() } }
}

@MainActor
enum TerminalTestWindow {
    /// A window on the app's scene holding `view` at `size` (the host view needs a window for frames and focus).
    static func show(_ view: UIView, size: CGSize = CGSize(width: 402, height: 600)) -> UIWindow {
        let scene = TestSupport.windowScene()!
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        view.frame = controller.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(view)
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }
}
