import Foundation

/// Real Unix FD supplied by the test launcher; all wire IO uses the production client.
@main
struct HelperClientProbe {
    struct Route: Codable { let mux: UInt64; let key: String }
    struct Nonce: Codable, Equatable { let nonce: UInt64 }

    static func main() async throws {
        let args = CommandLine.arguments
        if args[1] == "--stdio" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[2])
            process.arguments = ["--stdio"]
            let session = try await HelperSession(process: process)
            defer { session.close() }
            struct Launch: Codable { let launch: UInt64; let key: String; let label: String; let program: String? }
            let launches: [Launch] = try await session.connection.request(
                "launches.list", params: [String: String]())
            struct Result: Encodable {
                let hello: HelperSession.Info
                let launches: [Launch]
            }
            try JSONEncoder().encode(Result(hello: session.info, launches: launches)).write(
                to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
            session.close()
            for await status in session.exited {
                print("Helper exited with status \(status)")
            }
            return
        }
        let handle = FileHandle(fileDescriptor: Int32(args[1])!, closeOnDealloc: false)
        let client = HelperConnection(read: handle, write: handle)
        defer { client.close() }
        let (stream, continuation) = AsyncThrowingStream<HelperTopology, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let id = try await client.subscribe(
            "backends.open", params: Route(mux: UInt64(args[4])!, key: args[2]),
            notify: { method, data in
                guard method == "topology" else { return }
                do {
                    continuation.yield(try JSONDecoder().decode(HelperTopology.self, from: data))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            },
            ended: { result in
                if case .failure(let error) = result { continuation.finish(throwing: error) }
            })
        var topology: HelperTopology?
        for try await data in stream { topology = data }
        guard let topology else {
            throw HelperFailure(code: "topology", message: "No topology notification.")
        }
        client.cancel(id)
        let nonce = Nonce(nonce: DispatchTime.now().uptimeNanoseconds)
        let echo: Nonce = try await client.request("echo", params: nonce)
        guard nonce == echo else {
            throw HelperFailure(code: "echo", message: "Echo changed the nonce.")
        }
        try JSONEncoder().encode(topology).write(
            to: URL(fileURLWithPath: args[3]), options: .withoutOverwriting)
    }
}
