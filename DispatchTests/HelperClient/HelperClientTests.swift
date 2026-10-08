import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import DispatchHelperClient
#else
    @testable import DispatchApp
#endif

final class HelperClientTests: XCTestCase {
    func testUnadvertisedMethodsAreRefusedBeforeSendingAnyRequest() async throws {
        struct OK: Decodable { let ok: Bool }
        let incoming = Pipe(), outgoing = Pipe()
        let client = HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        let peer = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        var decoder = HelperWire.Decoder()
        peer.start(receive: { bytes in
            do {
                try decoder.feed(bytes) { message in
                    let request = try Self.object(message.body) as! [String: Any]
                    XCTAssertEqual(request["method"] as? String, "stats.sample")
                    XCTAssertEqual(message.id, 1, "Rejected operations must not allocate requests")
                    let body = try HelperBinary.encode(.object(["result": .object(["ok": .bool(true)])]))
                    peer.send(try HelperWire.encode(.init(kind: .response, id: message.id, body: body)))
                }
            } catch { XCTFail(String(describing: error)) }
        }, closed: { _ in })
        defer { client.close(); peer.close() }
        try await client.configure(limit: 1_048_576, ops: ["stats.sample"])
        for method in ["exec", "socket", "file.replace", "path.resolve", "file.read", "agent.inspect", "hooks.configure"] {
            do {
                _ = try await client.subscribe(method, params: [String: String](), notify: { _, _ in }, ended: { _ in })
                XCTFail("Forbidden method opened: \(method)")
            } catch { XCTAssertTrue(error.localizedDescription.contains("profile")) }
        }
        let response: OK = try await client.request("stats.sample", params: [String: String]())
        XCTAssertTrue(response.ok)
    }

    struct Fixture {
        struct Frame {
            let kind: UInt8
            let id: UInt64
            let body: Data
            var message: HelperWire.Message {
                HelperWire.Message(kind: HelperWire.Kind(rawValue: kind)!, id: id, body: body)
            }
            var wire: Data { try! HelperWire.encode(message) }
        }
        let frames: [String: [Frame]]
    }

    /// A frame body as the client reads it: the generated binary value codec, then Foundation.
    static func object(_ body: Data) throws -> Any { HelperBinary.foundation(try HelperBinary.decode(body)) }

    /// A frame body decoded into a Codable type the way HelperConnection does.
    static func decode<T: Decodable>(_ type: T.Type, _ body: Data) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object(body), options: [.fragmentsAllowed]))
    }

    /// Fixtures hold decoded messages (provenance.md); the frames are encoded here with the current
    /// codec. The hello reply names the codec, so it carries the current version; a streamed reply is
    /// chunked by that hello's chunk settings, as the helper sends it.
    static func fixture(_ name: String = "request-error") throws -> Fixture {
        #if SWIFT_PACKAGE
            let url = Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        #else
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name).json")
        #endif
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let messages = root["frames"] as! [String: [[String: Any]]]
        let hello = messages["read"]?.first { ($0["value"] as? [String: Any])?["method"] as? String == "hello" }?["id"] as? UInt64
        var chunk = (kind: UInt8(0), limit: 1)
        return Fixture(frames: try messages.mapValues { try $0.flatMap { message -> [Fixture.Frame] in
            let kind = message["kind"] as! UInt8, id = message["id"] as! UInt64
            guard var value = try message["value"].map(HelperBinary.value) else { return [.init(kind: kind, id: id, body: Data())] }
            if kind == HelperWire.Kind.response.rawValue, id == hello, case .object(var envelope) = value,
               case .object(var result)? = envelope["result"], case .unsigned(let chunkKind)? = result["chunk_kind"],
               case .unsigned(let chunkLimit)? = result["chunk_limit"] {
                chunk = (UInt8(chunkKind), Int(chunkLimit))
                result["version"] = .unsigned(HelperBinary.version)
                envelope["result"] = .object(result)
                value = .object(envelope)
            }
            guard let encoding = message["stream"] as? String else { return [.init(kind: kind, id: id, body: try HelperBinary.encode(value))] }
            let payload = encoding == "binary" ? Data(base64Encoded: message["bytes"] as! String)! : try HelperBinary.encode(value)
            let chunks = stride(from: 0, to: payload.count, by: chunk.limit).enumerated().map { index, start in
                Fixture.Frame(kind: chunk.kind, id: id, body: withUnsafeBytes(of: UInt64(index).littleEndian) { Data($0) }
                    + payload[start..<min(start + chunk.limit, payload.count)])
            }
            guard case .object(var end) = encoding == "binary" ? value : .object([:]) else { throw HelperBinary.Failure.invalid }
            end["stream"] = .object(["chunks": .unsigned(UInt64(chunks.count)), "bytes": .unsigned(UInt64(payload.count)), "encoding": .string(encoding)])
            return chunks + [.init(kind: kind, id: id, body: try HelperBinary.encode(.object(end)))]
        } })
    }

    func testStreamedRepliesPreserveWholeRealHelperResults() async throws {
        struct Echo: Codable, Equatable, Sendable { let value: String }
        struct Request: Decodable { let params: Echo }
        let fixture = try Self.fixture("streamed-replies").frames
        let inputs = fixture["read"]!
        let outputs = fixture["write"]!
        let incoming = Pipe()
        let outgoing = Pipe()
        let client = HelperConnection(
            read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        let replay = HelperTransport(
            read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        var decoder = HelperWire.Decoder()
        var index = 0
        replay.start(
            receive: { bytes in
                do {
                    try decoder.feed(bytes) { message in
                        XCTAssertEqual(message, inputs[index].message)
                        index += 1
                        if index == 1 {
                            replay.send(outputs[0].wire)
                        } else if index == inputs.count {
                            for frame in outputs.dropFirst() { replay.send(frame.wire) }
                        }
                    }
                } catch { XCTFail(String(describing: error)) }
            }, closed: { _ in })
        defer {
            client.close()
            replay.close()
        }
        let info: HelperSession.Info = try await client.request("hello", params: [String: String]())
        try await client.configure(
            limit: info.limit!, chunkKind: info.chunkKind!, chunkLimit: info.chunkLimit!)
        let large = try Self.decode(Request.self, inputs[1].body).params
        let small = try Self.decode(Request.self, inputs[2].body).params
        let (results, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        _ = try await client.subscribe(
            "echo", params: large,
            notify: { _, _ in
                XCTFail("Unexpected notification")
            },
            ended: { result in
                switch result {
                case .success(let data):
                    continuation.yield(data)
                    continuation.finish()
                case .failure(let error): continuation.finish(throwing: error)
                }
            })
        let reply: Echo = try await client.request("echo", params: small)
        var actual = [reply]
        for try await data in results {
            actual.insert(try JSONDecoder().decode(Echo.self, from: data), at: 0)
        }
        XCTAssertEqual(actual, [large, small])
    }

    func testBinaryReplyReturnsBothBytesAndMetadata() async throws {
        // A real files.read of a 200 000-byte file (bytes 0...255 repeating): binary chunks, then Metadata.
        struct Metadata: Decodable, Equatable { let size: UInt64 }
        let fixture = try Self.fixture("binary-reply").frames
        let hello = fixture["write"]![0]
        let input = fixture["read"]![1]
        struct Request: Decodable {
            struct Params: Codable, Sendable { let path: String; let offset: UInt64; let length: UInt64 }
            let method: String
            let params: Params
        }
        // The same captured reply also spans multiple minimally sized frames.
        for limited in [false, true] {
            let incoming = Pipe()
            let outgoing = Pipe()
            let client = HelperConnection(
                read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
            let replay = HelperTransport(
                read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
            var decoder = HelperWire.Decoder()
            replay.start(
                receive: { data in
                    do {
                        try decoder.feed(data) { message in
                            for frame in message.id == hello.id ? [hello] : Array(fixture["write"]!.dropFirst()) {
                                replay.send(frame.wire)
                            }
                        }
                    } catch { XCTFail(String(describing: error)) }
                }, closed: { _ in })
            defer {
                client.close()
                replay.close()
            }
            let info: HelperSession.Info = try await client.request("hello", params: [String: String]())
            try await client.configure(
                limit: limited ? UInt32(fixture["write"]!.map { $0.body.count }.max()!) : info.limit!,
                chunkKind: info.chunkKind!, chunkLimit: info.chunkLimit!)
            let request = try Self.decode(Request.self, input.body)
            let result: (result: Metadata, bytes: Data) = try await client.requestBinary(request.method, params: request.params)
            XCTAssertEqual(result.result, Metadata(size: 200_000))
            XCTAssertEqual(result.bytes, Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) }))
        }
    }

    /// The generated body codec's collector (HelperBinary.swift) rejects every incomplete or
    /// inconsistent chunked delivery. Fixture bodies are binary-codec envelopes.
    func testStreamCollectorRejectsEveryIncompleteOrInconsistentDelivery() throws {
        let fixture = try Self.fixture("streamed-replies").frames
        guard case .object(let hello) = try HelperBinary.decode(fixture["write"]![0].body),
              case .object(let result)? = hello["result"], case .unsigned(let kind)? = result["chunk_kind"],
              case .unsigned(let limit)? = result["chunk_limit"] else { return XCTFail("hello lacks chunk settings") }
        let chunks = fixture["write"]!.filter { UInt64($0.kind) == kind }
        let end = fixture["write"]!.last {
            $0.id == chunks[0].id && $0.kind == HelperWire.Kind.response.rawValue
        }!
        func push(_ collector: inout HelperBinary.Collector, _ message: HelperWire.Message) throws {
            _ = try collector.push(kind: message.kind.rawValue, id: message.id, body: message.body)
        }
        var actual: [HelperBinary.Failure?] = []
        for variant in 0..<8 {
            var collector = HelperBinary.Collector(limit: HelperWire.maximum, chunkKind: UInt8(kind), chunkLimit: Int(limit))
            do {
                if variant == 0 {
                    try push(&collector, chunks[1].message)
                } else if variant == 1 {
                    try push(&collector, HelperWire.Message(kind: .chunk, id: chunks[0].id, body: Data([0])))
                } else {
                    for chunk in chunks { try push(&collector, chunk.message) }
                    if variant == 2 {
                        try collector.finish()
                    } else if variant == 3 {
                        try push(&collector, chunks[0].message)
                    } else {
                        guard case .object(var object) = try HelperBinary.decode(end.body),
                              case .object(var stream)? = object["stream"] else { return XCTFail("end frame lacks stream") }
                        switch variant {
                        case 4: stream["chunks"] = .unsigned(UInt64(chunks.count + 1))
                        case 5: stream["bytes"] = .unsigned(0)
                        case 6: stream["encoding"] = .string("unknown")
                        default:
                            object.removeValue(forKey: "stream")
                            object["result"] = .bool(true)
                        }
                        if variant != 7 { object["stream"] = .object(stream) }
                        try push(&collector, .init(kind: .response, id: end.id, body: HelperBinary.encode(.object(object))))
                    }
                }
                actual.append(nil)
            } catch let error as HelperBinary.Failure { actual.append(error) }
        }
        XCTAssertEqual(actual, [.limit, .invalid, .invalid, .limit, .invalid, .invalid, .invalid, .limit])
    }

    func testStreamProtocolFailureSurvivesConnectionCleanup() async throws {
        let fixture = try Self.fixture("streamed-replies").frames
        let hello = fixture["write"]![0]
        let chunks = fixture["write"]!.filter { $0.kind == HelperWire.Kind.chunk.rawValue }
        let end = fixture["write"]!.last {
            $0.id == chunks[0].id && $0.kind == HelperWire.Kind.response.rawValue
        }!
        var actual: [HelperBinary.Failure?] = []
        for variant in 0..<3 {
            let incoming = Pipe()
            let outgoing = Pipe()
            let client = HelperConnection(
                read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
            let replay = HelperTransport(
                read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
            var decoder = HelperWire.Decoder()
            replay.start(
                receive: { bytes in
                    do {
                        try decoder.feed(bytes) { message in
                            if message.id == hello.id {
                                replay.send(hello.wire)
                            } else if variant == 0 {
                                replay.send(chunks[0].wire)
                                replay.send(chunks[2].wire)
                            } else if variant == 1 {
                                for frame in chunks { replay.send(frame.wire) }
                                guard case .object(var object) = try HelperBinary.decode(end.body),
                                      case .object(var stream)? = object["stream"] else { return XCTFail("end frame lacks stream") }
                                stream["chunks"] = .unsigned(UInt64(chunks.count + 1))
                                object["stream"] = .object(stream)
                                replay.send(
                                    try HelperWire.encode(
                                        .init(kind: .response, id: end.id, body: HelperBinary.encode(.object(object)))))
                            } else {
                                replay.send(chunks[0].wire)
                                replay.finish()
                            }
                        }
                    } catch { XCTFail(String(describing: error)) }
                }, closed: { _ in })
            let info: HelperSession.Info = try await client.request(
                "hello", params: [String: String]())
            try await client.configure(
                limit: info.limit!, chunkKind: info.chunkKind!, chunkLimit: info.chunkLimit!)
            do {
                let _: String = try await client.request("echo", params: [String: String]())
                actual.append(nil)
            } catch let error as HelperBinary.Failure { actual.append(error) }
            client.close()
            replay.close()
        }
        // The body codec's collector names them (as in the collector test): a skipped chunk, a
        // stream whose totals disagree, a connection that ends inside a stream.
        XCTAssertEqual(actual, [.limit, .invalid, .invalid])
    }

    func testRealFramesAcrossEveryReadBoundary() throws {
        let frames = try ["request-error", "live-tmux", "startup"].flatMap {
            try Self.fixture($0).frames.values.flatMap { $0 }
        }
        for frame in frames {
            for boundary in 0...frame.wire.count {
                var decoder = HelperWire.Decoder()
                var messages: [HelperWire.Message] = []
                try decoder.feed(Data(frame.wire.prefix(boundary))) { messages.append($0) }
                try decoder.feed(Data(frame.wire.dropFirst(boundary))) { messages.append($0) }
                try decoder.finish()
                XCTAssertEqual(messages, [frame.message])
            }
        }
        var decoder = HelperWire.Decoder()
        var messages: [HelperWire.Message] = []
        try decoder.feed(frames.reduce(into: Data()) { $0.append($1.wire) }) { messages.append($0) }
        try decoder.finish()
        XCTAssertEqual(messages, frames.map(\.message))
    }

    func testRealTopologyPreservesWholeLayoutAndNodes() throws {
        let frames = try Self.fixture("live-tmux").frames["write"]!
        let objects = try frames.filter { $0.kind == HelperWire.Kind.notify.rawValue }.map {
            try Self.object($0.body) as! [String: Any]
        }
        let object = try XCTUnwrap(objects.first { $0["method"] as? String == "topology" })
        let data = try JSONSerialization.data(withJSONObject: object["params"]!)
        let topology = try JSONDecoder().decode(HelperTopology.self, from: data)
        let encoded = try JSONEncoder().encode(topology)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: encoded) as! NSDictionary,
            object["params"] as! NSDictionary)
    }

    func testRealHelloPreservesWholeRecord() throws {
        struct Response: Decodable { let result: HelperSession.Info }
        let frame = try XCTUnwrap(Self.fixture("startup").frames["write"]?.first)
        let response = try Self.decode(Response.self, frame.body)
        let object = try Self.object(frame.body) as! [String: Any]
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(response.result))
                as! NSDictionary,
            object["result"] as! NSDictionary)
    }

    func testCommonConsumerPreservesCapturedNotifications() throws {
        for name in ["notifications"] {
            for frame in try Self.fixture(name).frames["write"]!
            where frame.kind == HelperWire.Kind.notify.rawValue {
                let object = try Self.object(frame.body) as! [String: Any]
                let method = object["method"] as! String
                let params = try JSONSerialization.data(
                    withJSONObject: object["params"]!, options: [.fragmentsAllowed])
                if let update = try HelperClient.Update.decode(method, params) {
                    XCTAssertEqual(
                        try JSONSerialization.jsonObject(
                            with: update.encode(), options: [.fragmentsAllowed]) as! NSObject,
                        object["params"] as! NSObject)
                } else {
                    XCTFail("Missing common notification \(method)")
                }
            }
        }
    }

    func testRealRequestAndErrorThroughAsyncTransport() async throws {
        struct Params: Codable, Sendable { let key: String }
        struct Request: Decodable {
            let method: String
            let params: Params
        }
        struct Response: Decodable { let error: HelperFailure }
        let frames = try Self.fixture().frames
        let input = frames["read"]!.first!
        let output = frames["write"]!.first!
        let request = try Self.decode(Request.self, input.body)
        let expected = try Self.decode(Response.self, output.body).error
        let incoming = Pipe()
        let outgoing = Pipe()
        let client = HelperConnection(
            read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        let replay = HelperTransport(
            read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        let received = expectation(description: "captured request")
        var decoder = HelperWire.Decoder()
        replay.start(
            receive: { bytes in
                do {
                    try decoder.feed(bytes) { message in
                        XCTAssertEqual(message, input.message)
                        replay.send(output.wire)
                        received.fulfill()
                    }
                } catch {
                    XCTFail(String(describing: error))
                    received.fulfill()
                }
            }, closed: { _ in })
        defer {
            client.close()
            replay.close()
        }
        do {
            let _: String = try await client.request(request.method, params: request.params)
            XCTFail("captured response was an error")
        } catch let error as HelperFailure {
            XCTAssertEqual(error, expected)
        }
        await fulfillment(of: [received], timeout: 5)
    }

    func testRealNotificationsCancelAndSuccessThroughAsyncTransport() async throws {
        struct Key: Codable, Sendable { let mux: UInt64; let key: String }
        struct Nonce: Codable, Equatable, Sendable { let nonce: UInt64 }
        struct Request<P: Decodable>: Decodable {
            let method: String
            let params: P
        }
        struct Response<R: Decodable>: Decodable { let result: R }
        struct Notification: Equatable, Sendable {
            let method: String
            let params: Data
        }
        let frames = try Self.fixture("live-tmux").frames
        let inputs = frames["read"]!
        let outputs = frames["write"]!
        let open = try Self.decode(Request<Key>.self, inputs[0].body)
        let echo = try Self.decode(Request<Nonce>.self, inputs[2].body)
        let expected = try outputs.filter { $0.kind == HelperWire.Kind.notify.rawValue }.map {
            frame in
            let object = try Self.object(frame.body) as! [String: Any]
            return Notification(
                method: object["method"] as! String,
                params: try JSONSerialization.data(
                    withJSONObject: object["params"]!,
                    options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]))
        }
        let incoming = Pipe()
        let outgoing = Pipe()
        let client = HelperConnection(
            read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        let replay = HelperTransport(
            read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        let received = expectation(description: "all captured requests")
        let canceled = expectation(description: "subscription ended once")
        var decoder = HelperWire.Decoder()
        var index = 0
        replay.start(
            receive: { bytes in
                do {
                    try decoder.feed(bytes) { message in
                        guard index < inputs.count else {
                            XCTFail("unexpected request")
                            return
                        }
                        XCTAssertEqual(message, inputs[index].message)
                        index += 1
                        for frame in outputs
                        where frame.id == message.id && message.kind == .request {
                            replay.send(frame.wire)
                        }
                        if index == inputs.count { received.fulfill() }
                    }
                } catch {
                    XCTFail(String(describing: error))
                    received.fulfill()
                }
            }, closed: { _ in })
        defer {
            client.close()
            replay.close()
        }
        let (stream, continuation) = AsyncStream<Notification>.makeStream(
            bufferingPolicy: .bufferingNewest(expected.count))
        let id = try await client.subscribe(
            open.method, params: open.params,
            notify: { method, params in
                continuation.yield(Notification(method: method, params: params))
            },
            ended: { result in
                if case .failure(let error) = result {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTFail("expected cancellation")
                }
                continuation.finish()
                canceled.fulfill()
            })
        XCTAssertEqual(id, inputs[0].id)
        var iterator = stream.makeAsyncIterator()
        var notifications: [Notification] = []
        for _ in expected { if let item = await iterator.next() { notifications.append(item) } }
        XCTAssertEqual(notifications, expected)
        client.cancel(id)
        let result: Nonce = try await client.request(echo.method, params: echo.params)
        XCTAssertEqual(
            result, try Self.decode(Response<Nonce>.self, outputs.last!.body).result)
        await fulfillment(of: [received, canceled], timeout: 5)
    }
}
