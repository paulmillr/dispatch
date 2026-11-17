import SSHEngine

/// One direction of an in-memory connection: a bounded buffer. Writes suspend while it is full (backpressure), reads
/// while it is empty. Waiting tasks honour cancellation.
actor MemoryPipe {
  private var buffer: [UInt8] = []
  /// The writer sent EOF: reads drain the buffer, then return empty.
  private var writerFinished = false
  /// The reader closed: reads return empty at once, writes fail as a reset.
  private var readerClosed = false
  /// Injected failure: every read and write throws it.
  private var failure: SSHError?
  private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
  private var nextWaiter: UInt64 = 0
  let capacity: Int

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  func read(maximum: Int) async throws(SSHError) -> [UInt8] {
    while true {
      if let failure { throw failure }
      if readerClosed { return [] }
      if !buffer.isEmpty {
        let count = min(max(1, maximum), buffer.count)
        let chunk = Array(buffer.prefix(count))
        buffer.removeFirst(count)
        wakeAll()
        return chunk
      }
      if writerFinished { return [] }
      if Task.isCancelled { throw .cancelled }
      await wait()
    }
  }

  func write(_ bytes: [UInt8]) async throws(SSHError) {
    var offset = 0
    while offset < bytes.count {
      if let failure { throw failure }
      if writerFinished { throw .closed(.byClient) }
      if readerClosed { throw .closed(.connectionLost) }
      if buffer.count < capacity {
        let count = min(capacity - buffer.count, bytes.count - offset)
        buffer.append(contentsOf: bytes[offset..<offset + count])
        offset += count
        wakeAll()
        continue
      }
      if Task.isCancelled { throw .cancelled }
      await wait()
    }
  }

  func finishWriting() {
    writerFinished = true
    wakeAll()
  }

  func closeReading() {
    readerClosed = true
    buffer.removeAll()
    wakeAll()
  }

  func fail(_ error: SSHError) {
    if failure == nil { failure = error }
    wakeAll()
  }

  /// Bytes written and not yet read.
  var buffered: Int { buffer.count }

  private func wait() async {
    let id = nextWaiter
    nextWaiter += 1
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        if Task.isCancelled {
          continuation.resume()
        } else {
          waiters[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.wake(id) }
    }
  }

  private func wake(_ id: UInt64) {
    waiters.removeValue(forKey: id)?.resume()
  }

  private func wakeAll() {
    let waiting = waiters
    waiters.removeAll()
    for continuation in waiting.values { continuation.resume() }
  }
}

/// One end of an in-memory connection (`pair`): what the driver's tests run the engine over instead of a socket.
struct MemoryByteStream: ByteStream {
  let incoming: MemoryPipe
  let outgoing: MemoryPipe

  /// Two connected ends, each direction buffering at most `capacity` bytes.
  static func pair(capacity: Int = 64 * 1024) -> (MemoryByteStream, MemoryByteStream) {
    let forward = MemoryPipe(capacity: capacity), backward = MemoryPipe(capacity: capacity)
    return (MemoryByteStream(incoming: backward, outgoing: forward), MemoryByteStream(incoming: forward, outgoing: backward))
  }

  func read(maximum: Int) async throws(SSHError) -> [UInt8] {
    try await incoming.read(maximum: maximum)
  }

  func write(_ bytes: [UInt8]) async throws(SSHError) {
    try await outgoing.write(bytes)
  }

  /// EOF to the peer, and this end's reads end at once.
  func close() async {
    await outgoing.finishWriting()
    await incoming.closeReading()
  }

  /// Half-close: EOF to the peer, this end keeps reading.
  func finishWriting() async {
    await outgoing.finishWriting()
  }

  /// A reset: every read and write on both ends throws `error` from now on.
  func reset(with error: SSHError = .closed(.connectionLost)) async {
    await incoming.fail(error)
    await outgoing.fail(error)
  }
}

/// A connector that hands out a prepared stream, or fails as told.
struct MemoryConnector: StreamConnector {
  let result: Result<MemoryByteStream, SSHError>

  func connect(host: String, port: UInt16, deadline: ContinuousClock.Instant) async throws(SSHError) -> any ByteStream {
    try result.get()
  }
}
