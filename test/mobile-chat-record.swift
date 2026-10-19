import Foundation

// Records the real helper's `chat.page` replies for transcripts read without a live terminal (the archive read), for
// the iPhone's chat fixtures (Mobile/Tests/Fixtures/Chat, test/mobile-chat-fixtures.py). The production client
// (HelperConnection) drives `dispatch-helper --stdio`; replies are written decoded, as JSON, one page after another.
// Usage: record <helper> <harness key> <transcript> <session> <out.json>
@main
struct MobileChatRecord {
    struct Info: Decodable { let frame_limit: UInt32?; let chunk_kind: UInt8?; let chunk_limit: UInt32? }
    struct Transcript: Encodable {
        let key: String, path: String, session: String, earlier: String?
        enum Keys: String, CodingKey { case key, path, session, earlier }
        /// `earlier` is "string or null" on the wire.
        func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: Keys.self)
            try fields.encode(key, forKey: .key); try fields.encode(path, forKey: .path)
            try fields.encode(session, forKey: .session); try fields.encode(earlier, forKey: .earlier)
        }
    }
    struct Page: Encodable { let transcript: Transcript }

    static func main() async throws {
        let args = CommandLine.arguments
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[1])
        process.arguments = ["--stdio"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        let client = HelperConnection(read: output.fileHandleForReading, write: input.fileHandleForWriting)
        // EOF lets the helper exit normally.
        defer { client.close(); process.waitUntilExit() }
        let info: Info = try await client.request("hello", params: [String: String]())
        try await client.configure(limit: info.frame_limit!, chunkKind: info.chunk_kind!, chunkLimit: info.chunk_limit!)
        var pages: [Any] = [], earlier: String?
        repeat {
            let value: HelperBinary.Value = try await client.request(
                "chat.page", params: Page(transcript: Transcript(key: args[2], path: args[3], session: args[4], earlier: earlier)))
            let page = HelperBinary.foundation(value) as! [String: Any]
            pages.append(page)
            earlier = page["earlier"] as? String
        } while earlier != nil && pages.count < 3
        let data = try JSONSerialization.data(withJSONObject: pages, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: args[5]))
    }
}
