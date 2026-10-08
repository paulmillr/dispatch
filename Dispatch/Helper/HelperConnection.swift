import Foundation

struct HelperFailure: Codable, Error, Equatable, Sendable, LocalizedError {
  let code: String
  let message: String
  var errorDescription: String? {
    code == "uncertain" ? message + " Its outcome may be uncertain; it was not retried." : message
  }
}

/// The common app API. Payloads are normalized UI data; native formats stay in the helper.
final class HelperConnection: @unchecked Sendable {
  private struct Request<P: Encodable>: Encodable {
    let method: String
    let params: P
  }

  private final class Pending: @unchecked Sendable {
    var id: UInt64?
    var canceled = false
    var notify: (@Sendable (String, Data) -> Void)?
    var complete: ((Result<HelperWire.Content, any Error>) -> Void)?
  }

  private let transport: HelperTransport
  private var decoder = HelperWire.Decoder(limit: HelperWire.limit)
  private var limit = HelperWire.limit
  /// Generated binary body codec (HelperBinary.swift, from the helper build): reassembles chunks.
  private var collector = HelperBinary.Collector(
    limit: HelperWire.maximum, chunkKind: HelperWire.Kind.chunk.rawValue, chunkLimit: 0)
  private var pending: [UInt64: Pending] = [:]
  private var next: UInt64 = 1
  private var failure: (any Error)?
  private var ops: Set<String>?

  init(read: FileHandle, write: FileHandle, ticket: AppReplay.Ticket? = nil, exited: ((Result<AppReplay.Event, any Error>) -> Void)? = nil) {
    transport = HelperTransport(read: read, write: write, ticket: ticket, exited: exited)
    transport.start(
      receive: { [weak self] in self?.receive($0) },
      closed: { [weak self] in self?.end($0) })
  }

  /// One submitted request, consumed once. Dropping it cancels abandoned work.
  final class Call<R: Decodable & Sendable>: Sendable {
    fileprivate let stream: AsyncThrowingStream<Data, any Error>
    fileprivate let cancel: @Sendable () -> Void

    fileprivate init(stream: AsyncThrowingStream<Data, any Error>, cancel: @escaping @Sendable () -> Void) {
      self.stream = stream
      self.cancel = cancel
    }

    deinit { cancel() }

    var value: R {
      get async throws {
        try await withTaskCancellationHandler {
          try Task.checkCancellation()
          var iterator = stream.makeAsyncIterator()
          guard let bytes = try await iterator.next() else { throw CancellationError() }
          return try JSONDecoder().decode(R.self, from: bytes)
        } onCancel: { cancel() }
      }
    }
  }

  /// Waits for enqueue, not the response, so callers can pipeline in an explicit order.
  nonisolated(nonsending) func submit<P: Encodable, R: Decodable & Sendable>(
    _ method: String, params: P
  ) async -> Call<R> {
    let item = Pending()
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let call = Call<R>(stream: stream) { self.transport.queue.async { self.cancel(item) } }
    item.complete = { result in
      do {
        let content = try result.get()
        guard content.bytes == nil else { throw HelperWire.Failure.kind }
        continuation.yield(content.json)
        continuation.finish()
      } catch { continuation.finish(throwing: error) }
    }
    do {
      try Task.checkCancellation()
      let body = try encode(Request(method: method, params: params))
      await withCheckedContinuation { ready in
        transport.queue.async {
          do { _ = try self.begin(item, method: method, body: body) }
          catch { self.finish(item, result: .failure(error)) }
          ready.resume()
        }
      }
    } catch { continuation.finish(throwing: error) }
    if Task.isCancelled { call.cancel() }
    return call
  }

  nonisolated(nonsending) func request<P: Encodable, R: Decodable>(
    _ method: String, params: P,
    notify: (@Sendable (String, Data) -> Void)? = nil
  ) async throws -> R {
    let content = try await perform(method, params: params, notify: notify)
    guard content.bytes == nil else { throw HelperWire.Failure.kind }
    return try JSONDecoder().decode(R.self, from: content.json)
  }

  nonisolated(nonsending) func requestBinary<P: Encodable, R: Decodable>(
    _ method: String, params: P
  ) async throws -> (result: R, bytes: Data) {
    let content = try await perform(method, params: params, notify: nil)
    guard let bytes = content.bytes else { throw HelperWire.Failure.kind }
    return (try JSONDecoder().decode(R.self, from: content.json), bytes)
  }

  private nonisolated(nonsending) func perform<P: Encodable>(
    _ method: String, params: P, notify: (@Sendable (String, Data) -> Void)?
  ) async throws -> HelperWire.Content {
    let body = try encode(Request(method: method, params: params))
    let item = Pending()
    item.notify = notify
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { reply in
        transport.queue.async {
          item.complete = { reply.resume(with: $0) }
          do { _ = try self.begin(item, method: method, body: body) } catch {
            self.finish(item, result: .failure(error))
          }
        }
      }
    } onCancel: {
      self.transport.queue.async { self.cancel(item) }
    }
  }

  nonisolated(nonsending) func subscribe<P: Encodable>(
    _ method: String, params: P,
    notify: @escaping @Sendable (String, Data) -> Void,
    ended: @escaping @Sendable (Result<Data, any Error>) -> Void
  ) async throws -> UInt64 {
    let body = try encode(Request(method: method, params: params))
    let item = Pending()
    item.notify = notify
    item.complete = { result in
      ended(
        result.flatMap { content in
          guard content.bytes == nil else { return .failure(HelperWire.Failure.kind) }
          return .success(content.json)
        })
    }
    return try await withCheckedThrowingContinuation { reply in
      transport.queue.async {
        do { reply.resume(returning: try self.begin(item, method: method, body: body)) } catch {
          self.finish(item, result: .failure(error))
          reply.resume(throwing: error)
        }
      }
    }
  }

  func cancel(_ id: UInt64) {
    transport.queue.async {
      if let item = self.pending[id] { self.cancel(item) }
    }
  }

  func close() {
    transport.close()
  }

  nonisolated(nonsending) func configure(limit: UInt32, chunkKind: UInt8? = nil, chunkLimit: UInt32? = nil, ops: [String]? = nil) async throws {
    try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, any Error>) in
      transport.queue.async {
        // The advertised limit only lowers the app's own frame bound.
        let limit = min(Int(limit), HelperWire.limit)
        guard limit > 0 else {
          reply.resume(throwing: HelperWire.Failure.limit)
          return
        }
        let kind = chunkKind.flatMap(HelperWire.Kind.init(rawValue:))
        guard
          (chunkKind == nil && chunkLimit == nil)
            || (kind == .chunk && chunkLimit != nil && chunkLimit! > 0
              && Int(chunkLimit!) + 8 <= limit)
        else {
          reply.resume(throwing: HelperWire.Failure.limit)
          return
        }
        self.limit = limit
        self.ops = ops.map(Set.init)
        // A chunked reply may exceed one frame; retain the whole-reply bound.
        self.collector = HelperBinary.Collector(
          limit: HelperWire.maximum, chunkKind: (kind ?? .chunk).rawValue, chunkLimit: Int(chunkLimit ?? 0))
        self.decoder.limit = limit
        self.transport.capacity = 4 * (limit + 13)
        reply.resume()
      }
    }
  }

  /// Request bodies use the generated binary value codec; the DTOs stay Codable.
  private func encode<P: Encodable>(_ value: P) throws -> Data {
    let json = try JSONEncoder().encode(value)
    return try HelperBinary.encode(
      HelperBinary.value(JSONSerialization.jsonObject(with: json, options: .fragmentsAllowed)))
  }

  private func begin(_ item: Pending, method: String, body: Data) throws -> UInt64 {
    if let failure { throw failure }
    guard !item.canceled else { throw CancellationError() }
    guard ops?.contains(method) != false else {
      throw HelperFailure(code: "permission_denied", message: "This operation is unavailable in the helper connection profile.")
    }
    guard next < UInt64.max else {
      throw HelperFailure(code: "limit", message: "Helper request ids exhausted.")
    }
    let id = next
    let bytes = try HelperWire.encode(.init(kind: .request, id: id, body: body), limit: limit)
    next += 1
    item.id = id
    pending[id] = item
    transport.send(bytes)
    return id
  }

  private func receive(_ bytes: Data) {
    do {
      var frames: [HelperWire.Message] = []
      try decoder.feed(bytes) { frames.append($0) }
      for frame in frames {
        guard let item = pending[frame.id] else { continue }
        guard let reply = try collector.push(kind: frame.kind.rawValue, id: frame.id, body: frame.body)
        else { continue }
        // A binary stream completes with its result metadata itself (no envelope).
        if let bytes = reply.binary {
          guard frame.kind == .response else { throw HelperWire.Failure.kind }
          finish(item, result: .success(
            HelperWire.Content(json: try json(HelperBinary.foundation(reply.value)), bytes: bytes)))
          continue
        }
        guard let object = HelperBinary.foundation(reply.value) as? [String: Any] else {
          throw HelperFailure(
            code: "invalid_response", message: "Invalid helper message.")
        }
        switch frame.kind {
        case .response:
          let result: Result<HelperWire.Content, any Error>
          if let error = object["error"], object["result"] == nil {
            result = .failure(
              try JSONDecoder().decode(HelperFailure.self, from: json(error)))
          } else if let value = object["result"], object["error"] == nil {
            result = .success(HelperWire.Content(json: try json(value), bytes: nil))
          } else {
            throw HelperFailure(
              code: "invalid_response", message: "Invalid helper response.")
          }
          finish(item, result: result)
        case .notify:
          guard let method = object["method"] as? String, let params = object["params"],
            let notify = item.notify
          else {
            throw HelperFailure(
              code: "invalid_response", message: "Unexpected helper notification.")
          }
          notify(method, try json(params))
        default:
          throw HelperFailure(
            code: "invalid_response", message: "Unexpected helper message kind.")
        }
      }
    } catch {
      end(error)
      transport.close()
    }
  }

  private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: value,
      options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
  }

  private func cancel(_ item: Pending) {
    item.canceled = true
    if let id = item.id, pending[id] != nil {
      collector.cancel(id)
      do {
        transport.send(
          try HelperWire.encode(.init(kind: .cancel, id: id, body: Data()), limit: limit))
      } catch {
        end(error)
        transport.close()
      }
      finish(item, result: .failure(CancellationError()))
    }
  }

  private func finish(_ item: Pending, result: Result<HelperWire.Content, any Error>) {
    if let id = item.id { pending.removeValue(forKey: id) }
    let complete = item.complete
    item.complete = nil
    item.notify = nil
    complete?(result)
  }

  private func end(_ error: any Error) {
    guard failure == nil else { return }
    var error = error
    if let closed = error as? HelperFailure, closed.code == "connection_closed" {
      do { try decoder.finish() } catch let framing { error = framing }
      do { try collector.finish() } catch let streaming { error = streaming }
    }
    failure = error
    let items = Array(pending.values)
    for item in items { finish(item, result: .failure(error)) }
  }
}
