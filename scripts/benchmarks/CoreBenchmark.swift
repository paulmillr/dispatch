import Foundation

// The standalone harness links the production buffer and protocol implementations.
struct HerdrFailure: Error { let message: String; init(_ message: String) { self.message = message } }

@main
struct CoreBenchmark {
    struct Report: Codable {
        let name: String
        let seconds: [Double]
        let bytesPerSample: Int
    }

    static func main() throws {
        var reports: [Report] = []
        func measure(_ name: String, bytes: Int, expected: Int, _ body: () throws -> Int) throws {
            // Validate every iteration, including warmups: lost output is a failure.
            var samples: [Double] = []
            for iteration in 0..<12 {
                let start = ContinuousClock.now
                let result = try body()
                let elapsed = start.duration(to: .now).components
                guard result == expected else { throw HerdrFailure("Incorrect output: \(name)") }
                if iteration >= 2 {
                    samples.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                }
            }
            reports.append(Report(name: name, seconds: samples, bytesPerSample: bytes))
        }
        for size in [64 * 1024, 2 * 1024 * 1024] {
            let chunk = Data(repeating: 120, count: 16 * 1024)
            try measure("herdr-line-\(size)", bytes: size, expected: size) {
                var buffer = HerdrLineBuffer()
                for _ in 0..<(size / chunk.count) {
                    try buffer.append(chunk)
                    guard buffer.next() == nil else { throw HerdrFailure("Premature line") }
                }
                try buffer.append([10])
                let count = buffer.next()?.count ?? -1
                guard buffer.count == 0 else { throw HerdrFailure("Undrained line") }
                return count
            }
            let plain = Data(repeating: 120, count: size)
            try measure("tmux-unescape-\(size)", bytes: size, expected: size) {
                let result = try TmuxProtocol.unescape(plain)
                guard result == plain else { throw HerdrFailure("Corrupt decoded output") }
                return result.count
            }
        }
        let colored = Data(String(repeating: "output \u{1b}[31mred\u{1b}[0m\r\n", count: 16_384).utf8)
        try measure("tmux-colored-filter", bytes: colored.count, expected: colored.count) {
            var filter = TmuxOutputFilter()
            let result = try filter.feed(colored)
            guard result == colored else { throw HerdrFailure("Corrupt filtered output") }
            return result.count
        }
        let stream = Data(String(repeating: "%output %1 hello\\015\\012\n", count: 16_384).utf8)
        for chunkSize in [1024, 65_536] {
            let chunks = stride(from: 0, to: stream.count, by: chunkSize).map {
                Data(stream[$0..<min($0 + chunkSize, stream.count)])
            }
            try measure("tmux-frames-chunk-\(chunkSize)", bytes: stream.count, expected: 16_384) {
                var parser = TmuxProtocol(), count = 0
                for chunk in chunks {
                    for event in try parser.feed(chunk) {
                        guard event == .output(pane: 1, bytes: Data("hello\r\n".utf8)) else {
                            throw HerdrFailure("Corrupt frame")
                        }
                        count += 1
                    }
                }
                return count
            }
        }
        let data = try JSONEncoder().encode(reports)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
