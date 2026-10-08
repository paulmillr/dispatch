import Foundation

/// Display-only decoding of Codex FunctionCallOutputBody and MCP content.
/// Decode each text item before joining: separate items can each contain JSON.
struct ToolOutput: Sendable {
    struct Block: Sendable {
        enum Kind: Sendable { case code(String), markdown, attachment }
        let kind: Kind
        let text: String
    }
    var blocks: [Block] = []
    var code: Int?
    var failed = false
    var running = false
    var text: String { blocks.map(\.text).joined(separator: "\n\n") }

    private mutating func append(_ result: Self) {
        blocks += result.blocks
        if code == nil || code == 0 { code = result.code ?? code }
        failed = failed || result.failed
        running = running || result.running
    }

    static func decode(_ raw: String, depth: Int = 0, prose: Bool = false) -> Self {
        let value = ToolPresentation.json(raw)
        func fallback() -> Self {
            Self(blocks: raw.isEmpty ? [] : [.init(kind: value != nil ? .code("json") : (prose ? .markdown : .code("text")), text: raw)])
        }
        guard depth < 6 else { return fallback() }
        if let object = value as? [String: Any] {
            if let output = object["output"] as? String,
               object["exit_code"] != nil || object["chunk_id"] != nil || object["wall_time_seconds"] != nil || object["session_id"] is Int {
                var result = decode(output, depth: depth + 1)
                result.code = object["exit_code"] as? Int ?? result.code
                result.failed = result.failed || result.code.map { $0 != 0 } == true
                result.running = result.running || (object["session_id"] is Int && object["exit_code"] as? Int == nil)
                return result
            }
            if let content = object["content"] as? [[String: Any]],
               content.contains(where: { Content($0) != nil }) || object["structuredContent"] != nil || object["isError"] is Bool {
                var result = contentItems(content, depth: depth)
                result.failed = result.failed || object["isError"] as? Bool == true
                // Structured data can add information absent from the text.
                if let structured = object["structuredContent"], !(structured is NSNull) {
                    result.blocks.append(.init(kind: .code("json"), text: TranscriptParser.printable(structured)))
                }
                return result
            }
        }
        if let items = value as? [[String: Any]], !items.isEmpty {
            if items.allSatisfy({ $0["type"] is String }), items.contains(where: { Content($0) != nil }) { return contentItems(items, depth: depth) }
            if items.allSatisfy({ ($0["status"] as? String == "fulfilled" && $0["value"] != nil) || ($0["status"] as? String == "rejected" && $0["reason"] != nil) }) {
                var result = Self()
                for item in items {
                    if item["status"] as? String == "rejected" {
                        result.failed = true
                        result.blocks.append(.init(kind: .code("text"), text: "Request failed: " + TranscriptParser.printable(item["reason"])))
                    } else { result.append(decode(TranscriptParser.printable(item["value"]), depth: depth + 1)) }
                }
                return result
            }
        }
        // Exact observed transport headers only. A program's arbitrary Output:
        // line, or JSON containing an output field, is not a transport envelope.
        if raw.hasPrefix("Chunk ID:"), let boundary = raw.range(of: "\nOutput:\n") {
            let header = String(raw[..<boundary.lowerBound])
            let code = header.components(separatedBy: "\n").first { $0.hasPrefix("Process exited with code ") }
                .flatMap { Int($0.dropFirst("Process exited with code ".count)) }
            var result = decode(String(raw[boundary.upperBound...]), depth: depth + 1)
            result.code = code ?? result.code; result.failed = result.failed || code.map { $0 != 0 } == true
            result.running = result.running || (code == nil && header.contains("\nProcess running with session ID "))
            return result
        }
        // Code Mode prepends a distinct InputText with status + time; MCP adds
        // a time-only header. They may also be combined with the following text.
        let scriptHeader = #"\A(Script completed|Script failed|Script terminated|Script running with cell ID [^\n]+)\nWall time [0-9]+(?:\.[0-9]+)? seconds\nOutput:\n"#
        let mcpHeader = #"\AWall time: [0-9]+(?:\.[0-9]+)? seconds\nOutput:(?:\n|\z)"#
        if let range = raw.range(of: scriptHeader, options: .regularExpression) ?? raw.range(of: mcpHeader, options: .regularExpression) {
            var result = decode(String(raw[range.upperBound...]), depth: depth + 1, prose: prose)
            if raw.hasPrefix("Script failed\n") { result.failed = true }
            if raw.hasPrefix("Script running ") {
                result.running = true
                result.blocks.insert(.init(kind: .attachment, text: "Tools are still running…"), at: 0)
            }
            if raw.hasPrefix("Script terminated\n") { result.blocks.insert(.init(kind: .attachment, text: "Tool activity stopped"), at: 0) }
            return result
        }
        return fallback()
    }

    /// Recognition and rendering share the same field validation, so malformed
    /// content cannot be accepted as an envelope and then silently discarded.
    private enum Content {
        case text(String), attachment(String)

        init?(_ item: [String: Any]) {
            let type = item["type"] as? String
            switch type {
            case "input_text", "output_text", "text":
                guard let text = item["text"] as? String else { return nil }
                self = .text(text)
            case "input_image", "image":
                guard item[type == "input_image" ? "image_url" : "data"] is String else { return nil }
                self = .attachment("Image · available in Tool details")
            case "input_audio", "audio":
                guard item[type == "input_audio" ? "audio_url" : "data"] is String else { return nil }
                self = .attachment("Audio · available in Tool details")
            case "encrypted_content":
                guard item["encrypted_content"] is String else { return nil }
                self = .attachment("Encrypted content")
            default: return nil
            }
        }
    }

    private static func contentItems(_ items: [[String: Any]], depth: Int) -> Self {
        var result = Self()
        for item in items {
            switch Content(item) {
            case .text(let text):
                result.append(decode(text, depth: depth + 1, prose: true))
            case .attachment(let text):
                result.blocks.append(.init(kind: .attachment, text: text))
            case nil:
                // Future or malformed items stay visible; do not discard them
                // simply because a sibling is a recognized text/media block.
                result.blocks.append(.init(kind: .code("json"), text: TranscriptParser.printable(item)))
            }
        }
        return result
    }
}
