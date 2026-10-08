import Foundation
@testable import DispatchApp

// A client for a real herdr server's socket: tests set up and inspect herdr state through it.

/// Blocking operations run on a worker, never the main actor. Each request uses
/// its own connection; a subscription keeps a separate, buffered connection.
final class HerdrSocket {
    let fd: Int32
    private var buffer = HerdrLineBuffer()
    init(path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HerdrFailure("Could not open herdr socket.") }
        var connected = false
        defer { if !connected { close(descriptor) } }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw HerdrFailure("Herdr socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in bytes.withUnsafeBytes { target.copyBytes(from: $0) } }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw HerdrFailure("Could not connect to herdr at \(path): \(String(cString: strerror(errno)))") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else { throw HerdrFailure("Herdr socket belongs to another user.") }
        fd = descriptor; connected = true
    }
    deinit { close(fd) }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HerdrFailure("Herdr connection closed while sending a request.") }
                offset += count
            }
        }
    }
    func readable(milliseconds: Int32) -> Bool {
        if buffer.hasLine() { return true }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        return poll(&descriptor, 1, milliseconds) > 0
    }
    func line() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            if let line = buffer.next() { return line }
            guard buffer.count < 16 * 1024 * 1024 else { throw HerdrFailure("Herdr response exceeded the size limit.") }
            let count = recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw HerdrFailure("Herdr connection closed or timed out.") }
            try buffer.append(bytes.prefix(count))
        }
    }
    @discardableResult
    func request(_ method: String, params: Data = Data("{}".utf8)) throws -> Data {
        let rpc = HerdrRPC()
        try write(rpc.encode(method, params: params))
        return try rpc.decode(line())
    }
}

/// A bounded JSONL buffer shared by local and SSH herdr transports. Search only
/// newly received bytes; a large frame can arrive in hundreds of small reads.
struct HerdrLineBuffer {
    private var bytes = Data()
    private var consumed = 0
    private var searched = 0
    private var newline: Int?
    let limit: Int

    init(limit: Int = 16 * 1024 * 1024) { self.limit = limit }
    var count: Int { bytes.count - consumed }

    mutating func append<Bytes: Collection>(_ input: Bytes) throws where Bytes.Element == UInt8 {
        guard input.count <= limit - count else { throw HerdrFailure("Herdr response exceeded the size limit.") }
        // Compact once per read, not once per line in a burst of events.
        if consumed > 0 {
            bytes.removeFirst(consumed)
            searched -= consumed
            if let newline { self.newline = newline - consumed }
            consumed = 0
        }
        bytes.append(contentsOf: input)
    }

    mutating func hasLine() -> Bool {
        if newline != nil { return true }
        newline = bytes[(bytes.startIndex + searched)...].firstIndex(of: 10).map { $0 - bytes.startIndex }
        searched = bytes.count
        return newline != nil
    }

    mutating func next() -> Data? {
        guard hasLine(), let newline else { return nil }
        let end = bytes.startIndex + newline
        let line = Data(bytes[(bytes.startIndex + consumed)..<end])
        consumed = end - bytes.startIndex + 1
        searched = consumed
        self.newline = nil
        if consumed == bytes.count {
            // Do not retain a multi-megabyte allocation on an idle subscription.
            bytes.removeAll(keepingCapacity: bytes.count <= 65_536)
            consumed = 0; searched = 0
        }
        return line
    }
}

/// Wire behavior shared by local sockets and SSH streams. Transports retain
/// their own I/O, cancellation, and connection lifetime rules.
struct HerdrRPC {
    let id = UUID().uuidString

    func encode(_ method: String, params: Data) throws -> Data {
        let object: [String: Any] = ["id": id, "method": method,
                                     "params": try JSONSerialization.jsonObject(with: params)]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }

    func decode(_ response: Data, peer: String = "Herdr") throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              json["id"] as? String == id else {
            throw HerdrFailure("\(peer) returned an unexpected request ID.")
        }
        if let error = json["error"] as? [String: Any] {
            throw HerdrFailure(error["message"] as? String ?? "\(peer) request failed.")
        }
        guard let result = json["result"] else { throw HerdrFailure("\(peer) response has no result.") }
        return try JSONSerialization.data(withJSONObject: result)
    }

    static func snapshot(from data: Data) throws -> HerdrSnapshot {
        struct Result: Decodable { let snapshot: HerdrSnapshot }
        return try JSONDecoder().decode(Result.self, from: data).snapshot
    }

    static func subscriptions() throws -> Data {
        let names = ["workspace.created", "workspace.updated", "workspace.renamed", "workspace.closed", "workspace.moved", "workspace.reordered", "workspace.focused",
                     "tab.created", "tab.renamed", "tab.closed", "tab.moved", "tab.focused", "pane.created", "pane.closed", "pane.moved", "pane.focused", "layout.updated"]
        return try JSONSerialization.data(withJSONObject: ["subscriptions": names.map { ["type": $0] }])
    }

    static func isFocusEvent(_ data: Data) -> Bool {
        struct Event: Decodable { let event: String }
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else { return false }
        return ["workspace.focused", "tab.focused", "pane.focused"].contains(event.event)
    }
}

struct HerdrSnapshot: Decodable, Equatable, Sendable {
    struct Workspace: Decodable, Equatable, Sendable {
        let workspace_id: String
        let label: String
        let active_tab_id: String
    }
    struct Tab: Decodable, Equatable, Sendable {
        let tab_id: String
        let workspace_id: String
        let label: String
    }
    struct Pane: Decodable, Equatable, Sendable {
        let pane_id: String
        let terminal_id: String
        let tab_id: String
        let cwd: String?
        let title: String?
    }
    struct Rect: Codable, Equatable, Sendable {
        let x: Double, y: Double, width: Double, height: Double
    }
    struct Layout: Codable, Equatable, Sendable {
        struct Pane: Codable, Equatable, Sendable { let pane_id: String; let rect: Rect }
        struct Split: Codable, Equatable, Sendable, Identifiable {
            let id: String
            let direction: String
            let ratio: Double
            let rect: Rect
            var path: [Bool]? {
                let parts = id.split(separator: "_", omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0] == "split", Int(parts[1]) != nil else { return nil }
                if parts[2] == "root" { return [] }
                guard !parts[2].isEmpty, parts[2].allSatisfy({ $0 == "0" || $0 == "1" }) else { return nil }
                return parts[2].map { $0 == "1" }
            }
        }
        let tab_id: String
        var focused_pane_id: String
        let area: Rect
        var panes: [Pane]
        var zoomed: Bool? = nil
        var splits: [Split]? = nil

        var preset: LayoutPreset? {
            guard zoomed != true else { return nil }
            if panes.count == 1 { return .single }
            let dividers = splits ?? []
            if panes.count == 2, dividers.count == 1, let root = dividers.first, root.path == [] {
                if abs(root.ratio - 0.5) < 0.015 { return root.direction == "right" ? .columns : (root.direction == "down" ? .rows : nil) }
            }
            if panes.count == 3, dividers.count == 2,
               dividers.allSatisfy({ abs($0.ratio - 0.5) < 0.015 }),
               dividers.contains(where: { $0.path == [] && $0.direction == "down" }),
               dividers.contains(where: { $0.path == [false] && $0.direction == "right" }) { return .twoAbove }
            if panes.count == 4, dividers.count == 3,
               dividers.allSatisfy({ abs($0.ratio - 0.5) < 0.015 }),
               dividers.contains(where: { $0.path == [] && $0.direction == "down" }),
               dividers.contains(where: { $0.path == [false] && $0.direction == "right" }),
               dividers.contains(where: { $0.path == [true] && $0.direction == "right" }) { return .grid }
            return nil
        }
    }
    var focused_workspace_id: String?
    var focused_tab_id: String?
    var focused_pane_id: String?
    var workspaces: [Workspace]
    var tabs: [Tab]
    var panes: [Pane]
    var layouts: [Layout]
}
