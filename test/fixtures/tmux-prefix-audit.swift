import AppKit

// UI model stand-ins only. PrefixKeys.swift, HelperClient.Prefix and the extracted AppDelegate methods
// (prefixTable(for:) with its neighbours, the selectWindow case) are production code; the runner copies them
// verbatim at build time. The server table is what the real helper read from a real tmux server.
enum LayoutPreset { case single, columns, rows, twoAbove, grid, six, eight }
struct AuditTab { var id = UUID(); var surfaceIDs: [UUID]; var terminal: UInt64? = 7 }
struct AuditSpace {
    var tabs: [AuditTab]
    var structured = true
    var backend: UInt64? = 1
    var node: UInt64? = 2
    var remote: String? = nil
}
final class AuditHelper {
    var server: PrefixTable??
    init(server: PrefixTable??) { self.server = server }
    func multiplexer(of: UInt64) -> String? { "tmux" }
    func prefixTable(session node: UInt64) -> PrefixTable?? { server }
    func readPrefixTable(session node: UInt64) { print("READ_PREFIX=\(node)") }
    func command(_ node: UInt64, _ text: String) { print("COMMAND=\(text)") }
    func selectWindow(_ node: UInt64, index: Int) { command(node, "select-window -t :=\(index)") }
}
struct AuditWorkspace {
    var spaces: [AuditSpace]
    var server: AuditHelper
    func helper(_ space: AuditSpace) -> AuditHelper? { server }
    func helper(containing id: UUID) -> AuditHelper? { server }
    func selectNumberedItem(at index: Int) { print("SELECTED_ORDINAL=\(index)") }
}
struct AuditValues { var prefixKeys = PrefixSpaces.multiplexers }
struct AuditSettings { var values = AuditValues() }
struct AppDelegate {
    var workspace: AuditWorkspace
    var settings = AuditSettings()
}
struct HerdrKeyConfig {
    static let shared = HerdrKeyConfig()
    var table: PrefixTable? { nil }
}

@main
struct Audit {
    @MainActor static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2 && arguments[0] == "--key" {
            print("PARSED_KEY=\(String(describing: PrefixKey(tmux: arguments[1])))")
            return
        }
        // --server FILE: the helper's backends.prefix reply as JSON (wire names), else none read yet.
        var server: PrefixTable?? = nil
        if arguments.first == "--server" {
            let reply = try JSONDecoder().decode(HelperClient.Prefix.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
            server = .some(PrefixTable.tmux(server: reply))
            arguments.removeFirst(2)
        }
        let surface = UUID()
        let app = AppDelegate(workspace: AuditWorkspace(spaces: [AuditSpace(tabs: [AuditTab(surfaceIDs: [surface])])],
                                                        server: AuditHelper(server: server)))
        guard let table = app.prefixTable(for: surface) else { print("APP_PREFIX=none"); return }
        print("APP_PREFIX=\(table.prefix.name) CONTROL=\(table.prefix.control) REPEAT=\(table.repeatTime) PREFIX2=\(table.prefix2?.name ?? "none")")
        if let index = arguments.first.flatMap(Int.init), arguments.count == 1 {
            app.auditSelectWindow(index, surface: surface)
            return
        }
        let keys = PrefixKeys()
        keys.table = { _ in table }
        keys.perform = { action, _ in print("ACTION=\(action)") }
        keys.reject = { command, _ in print("REJECTED=\(command)") }
        // ⌃A c, then ⌃B unarmed, then ⌃A h.
        let sequence: [(UInt16, String, NSEvent.ModifierFlags)] = [(0, "a", .control), (8, "c", []), (11, "b", .control), (0, "a", .control), (4, "h", [])]
        for (step, (code, text, flags)) in sequence.enumerated() {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)!
            print("HANDLED_\(step)_\(text)=\(keys.handle(event, surface: surface))")
        }
        for command in arguments {
            print("MAPPED=\(command) => \(String(describing: PrefixTable.tmuxAction(command)))")
        }
    }
}
