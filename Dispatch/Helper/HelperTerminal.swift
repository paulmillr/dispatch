#if canImport(Darwin)
  import Foundation
  @preconcurrency import Dispatch
  import Darwin

  /// A private renderer connection. Helper IDs and native terminal policy belong to its caller.
  @MainActor
  final class HelperRenderer {
    let directory: URL
    let executable: URL
    let path: String
    var command: String { Self.quote(executable.path) + " renderer" }
    var onConnect: (UUID, HelperTerminal) -> Void = { _, _ in }
    var count: Int { connections.count }
    nonisolated(unsafe) private var listener: DispatchSourceRead?
    private var connections: [UUID: HelperTerminal] = [:]
    private var credentials: [UUID: (token: String, boundary: AppReplay.Boundary?)] = [:]
    private var stopped = false

    init(directory: URL, executable: URL) throws {
      self.directory = directory
      self.executable = executable
      path = directory.appendingPathComponent("socket").path
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw POSIXError(.ENAMETOOLONG)
      }
      guard mkdir(directory.path, 0o700) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      var ready = false
      defer {
        if !ready {
          if fd >= 0 { Darwin.close(fd) }
          try? FileManager.default.removeItem(at: directory)
        }
      }
      guard fd >= 0 else { throw POSIXError(.ENFILE) }
      withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0,
        renderer_configure(fd) == 0
      else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
      source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept(fd) } }
      source.setCancelHandler { Darwin.close(fd) }
      listener = source
      ready = true
      source.resume()
    }

    deinit {
      listener?.cancel()
      if !stopped { try? FileManager.default.removeItem(at: directory) }
    }

    static func quote(_ value: String) -> String {
      "\""
        + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
          of: "\"", with: "\\\""
        )
        .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(
          of: "`", with: "\\`")
        + "\""
    }

    func environment(id: UUID) throws -> [String] {
      let credential = UUID().uuidString
      let terminal = try AppReplay.identity(kind: "terminal", value: id)
      let generation = try AppReplay.identity(kind: "renderer", value: UUID())
      let boundary = try AppReplay.boundary(kind: "renderer", data: JSONEncoder().encode([terminal, generation]))
      credentials.updateValue((credential, boundary), forKey: id)?.boundary?.cancel()
      return [
        "DISPATCH_RENDERER_SOCKET", path, "DISPATCH_RENDERER_TOKEN", credential,
        "DISPATCH_RENDERER_TAB", id.uuidString,
      ]
    }

    func revoke(_ id: UUID) {
      credentials.removeValue(forKey: id)?.boundary?.cancel()
      for connection in Array(connections.values) where connection.tab == id {
        connection.close()
      }
    }

    func stop() {
      guard !stopped else { return }
      stopped = true
      listener?.cancel()
      listener = nil
      for connection in Array(connections.values) { connection.close() }
      connections.removeAll()
      let abandoned = credentials.values.compactMap(\.boundary)
      credentials.removeAll()
      abandoned.forEach { $0.cancel() }
      try? FileManager.default.removeItem(at: directory)
    }

    private func accept(_ fd: Int32) {
      for _ in 0..<1024 {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard connections.count < 1024, getpeereid(client, &uid, &gid) == 0,
          uid == getuid(), renderer_configure(client) == 0
        else {
          Darwin.close(client)
          continue
        }
        var boundary: AppReplay.Boundary?
        let connection = HelperTerminal(
          fd: client,
          validate: { [weak self] id, token in
            guard let self, self.credentials[id]?.token == token else { return false }
            boundary = self.credentials.removeValue(forKey: id)?.boundary
            return true
          }, ready: { [weak self] id, channel in
            let deliver: @Sendable () -> Void = { [weak self, weak channel] in
              let receive: @MainActor @Sendable () -> Void = {
                guard let self, let channel, self.connections[channel.id] === channel else { return }
                self.onConnect(id, channel)
              }
              if Thread.isMainThread { MainActor.assumeIsolated { receive() } }
              else { DispatchQueue.main.sync { MainActor.assumeIsolated { receive() } } }
            }
            do {
              if let boundary {
                try boundary.arrive(ready: deliver, failed: { [weak channel] _ in
                  DispatchQueue.main.async { channel?.close() }
                })
              } else { deliver() }
            } catch { channel.close() }
          },
          retired: { [weak self] id in
            boundary?.cancel()
            self?.connections.removeValue(forKey: id)
          })
        connections[connection.id] = connection
        connection.start()
        Task { [weak connection] in
          try? await Task.sleep(for: .seconds(5))
          if let connection, connection.tab == nil { connection.close() }
        }
      }
    }
  }

  @MainActor
  final class HelperTerminal {
    let id = UUID()
    private(set) var tab: UUID?
    private(set) var grid = HelperTopology.Grid(columns: 1, rows: 1)
    /// Input read before a consumer is installed waits here, in order, and is handed over on install.
    var onInput: ((Data) -> Void)? {
      didSet {
        guard let onInput, !held.isEmpty else { return }
        let bytes = held
        held = Data()
        onInput(bytes)
      }
    }
    private var held = Data()
    var onResize: (HelperTopology.Grid) -> Void = { _ in }
    var onClose: () -> Void = {}
    private let fd: Int32
    nonisolated(unsafe) private var source: DispatchSourceRead?
    private var descriptors: [Int32] = []
    private var hello = Data()
    private var transport: HelperTransport?
    private(set) var files: [FileHandle] = []
    private var stopped = false
    private var ending = false
    private let validate: (UUID, String) -> Bool
    private let ready: (UUID, HelperTerminal) -> Void
    private let retired: (UUID) -> Void

    init(
      fd: Int32, validate: @escaping (UUID, String) -> Bool,
      ready: @escaping (UUID, HelperTerminal) -> Void, retired: @escaping (UUID) -> Void
    ) {
      self.fd = fd
      self.validate = validate
      self.ready = ready
      self.retired = retired
    }

    deinit {
      source?.cancel()
      for descriptor in descriptors { Darwin.close(descriptor) }
    }

    func start() {
      let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
      reader.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read() } }
      let descriptor = fd
      reader.setCancelHandler { Darwin.close(descriptor) }
      source = reader
      reader.resume()
    }

    func write(_ bytes: Data) {
      if !stopped, !ending {
        transport?.send(bytes)
      }
    }

    func suspend(_ token: UUID, _ suspended: Bool) {
      transport?.suspend(token, suspended)
    }

    func finish() {
      guard !stopped, !ending else { return }
      ending = true
      if let transport {
        transport.finish()
      } else {
        close()
      }
    }

    func close() {
      guard !stopped else { return }
      stopped = true
      source?.cancel()
      source = nil
      for descriptor in descriptors {
        Darwin.close(descriptor)
      }
      descriptors.removeAll()
      hello.removeAll()
      transport?.close()
      transport = nil
      files.removeAll()
      retired(id)
      onClose()
      held = Data()
      onInput = nil
      onResize = { _ in }
      onClose = {}
    }

    private func read() {
      var bytes = [UInt8](repeating: 0, count: 256)
      for _ in 0..<(65_536 / bytes.count) {
        guard !stopped else { return }
        var handles = [Int32](repeating: -1, count: 2)
        var count = 0
        let size = renderer_receive(fd, &bytes, bytes.count, &handles, &count)
        if size < 0, errno == EINTR { continue }
        if size < 0, errno == EAGAIN { return }
        guard size > 0 else {
          close()
          return
        }
        if count > 0 {
          guard tab == nil, descriptors.isEmpty else {
            for handle in handles.prefix(count) { Darwin.close(handle) }
            close()
            return
          }
          descriptors = Array(handles.prefix(count))
        }
        if tab == nil {
          hello.append(contentsOf: bytes.prefix(size))
          guard hello.count <= 256 else {
            close()
            return
          }
          let ends = hello.indices.filter { hello[$0] == 10 }
          guard ends.count >= 3 else { continue }
          let end = ends[2] + 1
          let fields = String(decoding: hello[..<end], as: UTF8.self).split(
            separator: "\n", omittingEmptySubsequences: false)
          guard fields.count == 4, fields[2] == "renderer",
            let id = UUID(uuidString: String(fields[0])),
            descriptors.count == 2, validate(id, String(fields[1]))
          else {
            close()
            return
          }
          files = descriptors.map { FileHandle(fileDescriptor: $0, closeOnDealloc: true) }
          descriptors.removeAll()
          tab = id
          let channel = HelperTransport(
            read: files[0], write: files[1], capacity: 32 * 1024 * 1024)
          transport = channel
          guard resize() else {
            close()
            return
          }
          ready(id, self)
          channel.start(
            receive: { [weak self] data in
              DispatchQueue.main.async {
                guard let self, !self.stopped, !self.ending else { return }
                if let onInput = self.onInput { onInput(data) } else { self.held.append(data) }
              }
            }, closed: { [weak self] _ in DispatchQueue.main.async { self?.close() } })
          let tail = Data(hello.dropFirst(end))
          hello.removeAll()
          guard tail.allSatisfy({ $0 == 82 }) else {
            close()
            return
          }
          if !tail.isEmpty, !resize() {
            close()
            return
          }
        } else {
          guard bytes.prefix(size).allSatisfy({ $0 == 82 }), resize() else {
            close()
            return
          }
        }
      }
    }

    private func resize() -> Bool {
      guard let input = files.first, !stopped, !ending else { return ending }
      var size = winsize()
      guard ioctl(input.fileDescriptor, TIOCGWINSZ, &size) == 0 else { return false }
      let columns = max(1, size.ws_col), rows = max(1, size.ws_row)
      // A PTY that does not know its pixel size reports 0.
      let known = { (cell: UInt16) in cell > 0 ? cell : nil }
      let next = HelperTopology.Grid(
        columns: columns, rows: rows, cell_width: known(size.ws_xpixel / columns),
        cell_height: known(size.ws_ypixel / rows))
      if next != grid {
        grid = next
        onResize(next)
      }
      return true
    }
  }
#endif
