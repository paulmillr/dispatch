import Foundation

/// One serial queue owns both descriptors through readiness sources: a wake reads everything available and hands it
/// over in one `receive`, and queued frames leave in as few `write` calls as the descriptor takes. Callbacks run on
/// this serial queue.
///
/// Writes coalesce without a timer. A send runs as a block on this queue and queues a flush behind itself, so the sends
/// already waiting on the queue (a burst) join it and leave in one `write`; a lone send (a keystroke) is written as
/// soon as its own block ends. Small frames are joined into one buffer of at most `join` bytes; a larger frame stays a
/// buffer of its own. While the descriptor is full the write source waits for room and everything sent meanwhile goes
/// out with the next write. An idle transport has no timer and no pending work: only its read source, waiting.
final class HelperTransport: @unchecked Sendable {
  let queue: DispatchQueue
  private let descriptors: Descriptors?
  private let ticket: AppReplay.Ticket?
  private let exited: ((Result<AppReplay.Event, any Error>) -> Void)?
  private var receive: ((Data) -> Void)?
  private var closed: ((any Error) -> Void)?
  private var reader: DispatchSourceRead?
  private var writer: DispatchSourceWrite?
  /// The write source is resumed: the descriptor took less than was queued and the rest waits for room.
  private var waiting = false
  /// A flush is queued behind the sends that came before it.
  private var scheduled = false
  /// Unsent bytes in order; `written` of the first are out.
  private var output: [Data] = []
  private var written = 0
  private var queued = 0
  private var stopped = false
  private var finishing = false
  private var suspensions: Set<UUID> = []
  private let chunk = 65_536
  /// Frames up to this size join one buffer (one `write`); the most one wake reads before it hands bytes over.
  private static let join = 65_536, wake = 1_048_576
  private var buffer: UnsafeMutableRawPointer?
  // Access only on queue, including negotiated bus bounds.
  var capacity: Int
  /// On queue: `write` calls made and reader wakes that handed bytes over (tests count them).
  private(set) var writes = 0
  private(set) var deliveries = 0

  private struct Handlers: @unchecked Sendable {
    let receive: (Data) -> Void
    let closed: (any Error) -> Void
  }

  /// The descriptors stay open until the transport and each source on them are done (a source's descriptor must outlive
  /// its cancellation). Like DispatchIO, the transport makes them non-blocking and its writes raise no SIGPIPE; their
  /// flags are restored before they close (a pty or socket may be shared with another process).
  private final class Descriptors: @unchecked Sendable {
    let read: FileHandle
    let write: FileHandle
    var input: Int32 { read.fileDescriptor }
    var output: Int32 { write.fileDescriptor }
    private let flags: (input: Int32, output: Int32, pipe: Int32)
    private let lock = NSLock()
    private var holds = 1

    init(read: FileHandle, write: FileHandle) {
      self.read = read
      self.write = write
      let input = read.fileDescriptor, output = write.fileDescriptor
      flags = (fcntl(input, F_GETFL), fcntl(output, F_GETFL), fcntl(output, F_GETNOSIGPIPE))
      if flags.input >= 0 { _ = fcntl(input, F_SETFL, flags.input | O_NONBLOCK) }
      if output != input, flags.output >= 0 { _ = fcntl(output, F_SETFL, flags.output | O_NONBLOCK) }
      _ = fcntl(output, F_SETNOSIGPIPE, 1)
    }

    func hold() { lock.withLock { holds += 1 } }

    func release() {
      let last = lock.withLock { () -> Bool in
        holds -= 1
        return holds == 0
      }
      guard last else { return }
      if flags.pipe >= 0 { _ = fcntl(output, F_SETNOSIGPIPE, flags.pipe) }
      if flags.input >= 0 { _ = fcntl(input, F_SETFL, flags.input) }
      if output != input {
        if flags.output >= 0 { _ = fcntl(output, F_SETFL, flags.output) }
        try? write.close()
      }
      try? read.close()
    }
  }

  init(read: FileHandle, write: FileHandle, capacity: Int = 4 * (HelperWire.maximum + 13),
       ticket: AppReplay.Ticket? = nil, exited: ((Result<AppReplay.Event, any Error>) -> Void)? = nil) {
    queue = DispatchQueue(label: "yachts.dispatch.helper")
    self.capacity = capacity
    self.ticket = ticket
    self.exited = exited
    if ticket?.replaying == true {
      descriptors = nil
      try? read.close(); try? write.close()
      return
    }
    descriptors = Descriptors(read: read, write: write)
  }

  deinit {
    if !stopped {
      cancelSources()
      descriptors?.release()
    }
    buffer?.deallocate()
  }

  func start(receive: @escaping (Data) -> Void, closed: @escaping (any Error) -> Void) {
    let handlers = Handlers(receive: receive, closed: closed)
    queue.async {
      guard !self.stopped, self.receive == nil else { return }
      self.receive = handlers.receive
      self.closed = handlers.closed
      self.ticket?.through(self.queue)
      if let ticket = self.ticket, ticket.replaying {
        do {
          try ticket.listen({ event in
            self.queue.async {
              do {
                switch event.kind {
                case "in.read": self.receive?(AppReplay.bytes(event.value))
                case "in.end", "in.error": self.stop(try AppReplay.decode(AppReplay.Failure.self, event.value).error)
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
      self.listen()
    }
  }

  private func listen() {
    guard !finishing, let descriptors else { return }
    buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptors.input, queue: queue)
    source.setEventHandler { [weak self] in self?.readable() }
    descriptors.hold()
    source.setCancelHandler { descriptors.release() }
    reader = source
    source.resume()
  }

  /// One wake: everything the descriptor has now (up to `wake` bytes), handed over at once.
  private func readable() {
    guard !stopped, !finishing, let descriptors, let buffer else { return }
    var bytes = Data()
    var ended: (any Error)?
    while bytes.count < Self.wake {
      let count = Darwin.read(descriptors.input, buffer, chunk)
      if count > 0 {
        bytes.append(buffer.assumingMemoryBound(to: UInt8.self), count: count)
        // A short read emptied the descriptor: the source wakes again for what comes next.
        if count < chunk { break }
        continue
      }
      if count == 0 {
        ended = HelperFailure(code: "connection_closed", message: "Helper disconnected.")
        break
      }
      if errno == EINTR { continue }
      if errno != EAGAIN && errno != EWOULDBLOCK { ended = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      break
    }
    if !bytes.isEmpty {
      do { try ticket?.emit(kind: "read", value: .bytes(bytes)) }
      catch { stop(error); return }
      deliveries += 1
      receive?(bytes)
    }
    if let ended { stop(ended) }
  }

  /// `asking`: a waiting test's check sent it (AppReplay.asking, carried past the queue hop to its record).
  func send(_ bytes: Data, asking: Bool = false) {
    queue.async {
      guard !self.stopped, !self.finishing else { return }
      do { try AppReplay.$asking.withValue(asking) { try self.ticket?.action(kind: "wire", value: .bytes(bytes)) } }
      catch { self.stop(error); return }
      if self.ticket?.replaying == true { return }
      guard bytes.count <= self.capacity - self.queued else {
        self.stop(HelperFailure(code: "limit", message: "Helper output buffer is full."))
        return
      }
      guard !bytes.isEmpty else { return }
      self.queued += bytes.count
      if let last = self.output.indices.last, self.output[last].count + bytes.count <= Self.join {
        self.output[last].append(bytes)
      } else {
        self.output.append(bytes)
      }
      self.schedule()
    }
  }

  /// Queues one flush behind the sends already on the queue; none while the descriptor is full (its room flushes).
  private func schedule() {
    guard !scheduled, !waiting else { return }
    scheduled = true
    queue.async {
      self.scheduled = false
      self.flush()
    }
  }

  func close() {
    queue.async {
      guard !self.stopped, !self.finishing || self.ticket?.replaying != true else { return }
      do { if !self.finishing { try self.ticket?.action(kind: "close") } }
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
      // The journal records where the app ended its side, not how: a finish has nothing left to flush in replay.
      do { try self.ticket?.action(kind: "close") }
      catch { self.stop(error); return }
      if self.ticket?.replaying == true { self.finishing = true; return }
      self.finishing = true
      // Nothing more is read once the app ends its side.
      self.reader?.cancel()
      self.reader = nil
      self.flush()
    }
  }

  private func flush() {
    guard !stopped, !waiting, suspensions.isEmpty, let descriptors else { return }
    while let first = output.first {
      let count = first.withUnsafeBytes { bytes in
        Darwin.write(descriptors.output, bytes.baseAddress! + written, bytes.count - written)
      }
      writes += 1
      if count > 0 {
        written += count
        queued -= count
        if written == first.count {
          output.removeFirst()
          written = 0
        }
      } else if count < 0 && errno == EINTR {
        continue
      } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
        wait(descriptors)
        return
      } else {
        stop(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        return
      }
    }
    if finishing {
      stop(HelperFailure(code: "connection_closed", message: "Helper connection closed."))
    }
  }

  /// The descriptor is full: the write source flushes once it has room.
  private func wait(_ descriptors: Descriptors) {
    waiting = true
    if writer == nil {
      let source = DispatchSource.makeWriteSource(fileDescriptor: descriptors.output, queue: queue)
      source.setEventHandler { [weak self] in self?.writable() }
      descriptors.hold()
      source.setCancelHandler { descriptors.release() }
      writer = source
    }
    writer?.resume()
  }

  private func writable() {
    guard !stopped, waiting else { return }
    waiting = false
    writer?.suspend()
    flush()
  }

  /// A suspended source is resumed first: one must not be cancelled (or released) suspended.
  private func cancelSources() {
    reader?.cancel()
    reader = nil
    if let writer {
      if !waiting { writer.resume() }
      writer.cancel()
    }
    writer = nil
    waiting = false
  }

  private func stop(_ error: any Error) {
    guard !stopped else { return }
    stopped = true
    if ticket?.replaying != true {
      do { try ticket?.emit(kind: "end", value: AppReplay.value(AppReplay.Failure(error))) }
      catch { AppReplay.fail(error) }
    }
    // The descriptors close once the sources' cancellations ran (EOF for the helper: its orderly shutdown).
    cancelSources()
    descriptors?.release()
    output.removeAll()
    written = 0
    queued = 0
    let ended = closed
    receive = nil
    closed = nil
    ended?(error)
  }
}
