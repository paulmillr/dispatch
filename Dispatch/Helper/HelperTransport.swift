import Foundation

/// DispatchIO owns readiness and partial writes. Callbacks run on this serial queue.
final class HelperTransport: @unchecked Sendable {
  let queue: DispatchQueue
  private let reader: DispatchIO?
  private let writer: DispatchIO?
  private let ticket: AppReplay.Ticket?
  private let exited: ((Result<AppReplay.Event, any Error>) -> Void)?
  private var receive: ((Data) -> Void)?
  private var closed: ((any Error) -> Void)?
  private var output: [Data] = []
  private var queued = 0
  private var writing = false
  private var stopped = false
  private var finishing = false
  private var suspensions: Set<UUID> = []
  private let chunk = 65_536
  // Access only on queue, including negotiated bus bounds.
  var capacity: Int

  private struct Handlers: @unchecked Sendable {
    let receive: (Data) -> Void
    let closed: (any Error) -> Void
  }

  init(read: FileHandle, write: FileHandle, capacity: Int = 4 * (HelperWire.maximum + 13),
       ticket: AppReplay.Ticket? = nil, exited: ((Result<AppReplay.Event, any Error>) -> Void)? = nil) {
    queue = DispatchQueue(label: "dev.dispatch.helper")
    self.capacity = capacity
    self.ticket = ticket
    self.exited = exited
    if ticket?.replaying == true {
      reader = nil; writer = nil
      try? read.close(); try? write.close()
      return
    }
    reader = DispatchIO(type: .stream, fileDescriptor: read.fileDescriptor, queue: queue) { _ in
      try? read.close()
    }
    if read.fileDescriptor == write.fileDescriptor {
      writer = reader
    } else {
      writer = DispatchIO(type: .stream, fileDescriptor: write.fileDescriptor, queue: queue) {
        _ in
        try? write.close()
      }
    }
    reader?.setLimit(lowWater: 1)
    reader?.setLimit(highWater: chunk)
  }

  deinit {
    reader?.close(flags: .stop)
    if writer !== reader { writer?.close(flags: .stop) }
  }

  func start(receive: @escaping (Data) -> Void, closed: @escaping (any Error) -> Void) {
    let handlers = Handlers(receive: receive, closed: closed)
    queue.async {
      guard !self.stopped, self.receive == nil else { return }
      self.receive = handlers.receive
      self.closed = handlers.closed
      if let ticket = self.ticket, ticket.replaying {
        do {
          try ticket.listen({ event in
            self.queue.async {
              do {
                switch event.kind {
                case "in.read": self.receive?(event.data)
                case "in.end", "in.error": self.stop(try JSONDecoder().decode(AppReplay.Failure.self, from: event.data).error)
                case "in.started", "in.exit": self.exited?(.success(event))
                default: throw HelperFailure(code: "replay", message: "Unexpected helper journal event: " + event.kind)
                }
              } catch { AppReplay.fail(error); self.stop(error) }
            }
          }, failed: { error in
            self.queue.async {
              self.exited?(.failure(error))
              self.stop(error)
            }
          })
        } catch { self.stop(error) }
        return
      }
      self.read()
    }
  }

  private func read() {
    guard !stopped, !finishing else { return }
    reader?.read(offset: 0, length: chunk, queue: queue) {
      [weak self] done, bytes, error in
      guard let self, !self.stopped, !self.finishing else { return }
      if let bytes, !bytes.isEmpty {
        do { try self.ticket?.emit(kind: "read", data: Data(bytes)) }
        catch { self.stop(error); return }
        self.receive?(Data(bytes))
      }
      if error != 0 {
        self.stop(NSError(domain: NSPOSIXErrorDomain, code: Int(error)))
      } else if done, bytes?.isEmpty != false {
        self.stop(
          HelperFailure(code: "connection_closed", message: "Helper disconnected."))
      } else if done {
        self.read()
      }
    }
  }

  func send(_ bytes: Data) {
    queue.async {
      guard !self.stopped, !self.finishing else { return }
      do { try self.ticket?.action(kind: "wire", data: bytes) }
      catch { self.stop(error); return }
      if self.ticket?.replaying == true { return }
      guard bytes.count <= self.capacity - self.queued else {
        self.stop(HelperFailure(code: "limit", message: "Helper output buffer is full."))
        return
      }
      self.output.append(bytes)
      self.queued += bytes.count
      self.flush()
    }
  }

  func close() {
    queue.async {
      guard !self.stopped, !self.finishing || self.ticket?.replaying != true else { return }
      do { try self.ticket?.action(kind: "close") }
      catch { self.stop(error); return }
      if self.ticket?.replaying == true { self.finishing = true; return }
      self.stop(
        HelperFailure(code: "connection_closed", message: "Helper connection closed."))
    }
  }

  func suspend(_ token: UUID, _ suspended: Bool) {
    queue.async {
      guard !self.stopped else { return }
      if suspended { self.suspensions.insert(token) }
      else { self.suspensions.remove(token) }
      self.flush()
    }
  }

  func finish() {
    queue.async {
      do { try self.ticket?.action(kind: "finish") }
      catch { self.stop(error); return }
      if self.ticket?.replaying == true { self.finishing = true; return }
      self.finishing = true
      self.flush()
    }
  }

  private func flush() {
    guard !stopped, !writing, suspensions.isEmpty else { return }
    guard let bytes = output.first else {
      if finishing {
        stop(HelperFailure(code: "connection_closed", message: "Helper connection closed."))
      }
      return
    }
    writing = true
    let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
    writer?.write(offset: 0, data: data, queue: queue) { [weak self] done, _, error in
      guard let self, !self.stopped else { return }
      if error != 0 {
        self.stop(NSError(domain: NSPOSIXErrorDomain, code: Int(error)))
      } else if done {
        self.output.removeFirst()
        self.queued -= bytes.count
        self.writing = false
        self.flush()
      }
    }
  }

  private func stop(_ error: any Error) {
    guard !stopped else { return }
    stopped = true
    if ticket?.replaying != true {
      do { try ticket?.emit(kind: "end", data: JSONEncoder().encode(AppReplay.Failure(error))) }
      catch { AppReplay.fail(error) }
    }
    reader?.close(flags: .stop)
    if writer !== reader { writer?.close(flags: .stop) }
    output.removeAll()
    queued = 0
    let ended = closed
    receive = nil
    closed = nil
    ended?(error)
  }
}
