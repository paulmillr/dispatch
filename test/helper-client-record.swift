import Foundation

// Records real client<->helper exchanges for HelperClientTests: the production HelperConnection
// drives the real helper (--stdio) with the same calls the tests replay, while the helper's own
// DISPATCH_CAPTURE records both directions. Usage: record <helper> <streamed|binary|error> [file]
@main
struct Record {
    struct Info: Decodable { let frame_limit: UInt32?; let chunk_kind: UInt8?; let chunk_limit: UInt32? }
    struct Echo: Codable, Equatable, Sendable { let value: String }
    struct Read: Codable, Sendable { let path: String; let offset: UInt64; let length: UInt64 }
    struct Metadata: Decodable { let size: UInt64 }
    struct Key: Codable, Sendable { let key: String }

    static func main() async throws {
        let args = CommandLine.arguments
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[1])
        process.arguments = ["--stdio"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        let client = HelperConnection(read: output.fileHandleForReading, write: input.fileHandleForWriting)
        // EOF lets the helper exit normally, which flushes its capture (a kill can drop the last records).
        defer { client.close(); process.waitUntilExit() }
        switch args[2] {
        case "error":
            do {
                let _: String = try await client.request("backends.open", params: Key(key: "missing"))
                print("FAILED: expected an error")
            } catch { print("error reply:", error) }
            return
        default: break
        }
        let info: Info = try await client.request("hello", params: [String: String]())
        try await client.configure(limit: info.frame_limit!, chunkKind: info.chunk_kind!, chunkLimit: info.chunk_limit!)
        if args[2] == "binary" {
            let result: (result: Metadata, bytes: Data) = try await client.requestBinary(
                "files.read", params: Read(path: args[3], offset: 0, length: 200_000))
            print("binary reply:", result.bytes.count, "bytes, size", result.result.size)
            return
        }
        let large = Echo(value: String(repeating: "escaped\\n\"héllo", count: 30_000)), small = Echo(value: "small")
        let (ended, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        _ = try await client.subscribe("echo", params: large, notify: { _, _ in }, ended: { result in
            switch result {
            case .success(let data): continuation.yield(data); continuation.finish()
            case .failure(let error): continuation.finish(throwing: error)
            }
        })
        let reply: Echo = try await client.request("echo", params: small)
        for try await data in ended { print("large echo intact:", try JSONDecoder().decode(Echo.self, from: data) == large) }
        print("small echo intact:", reply == small)
    }
}
