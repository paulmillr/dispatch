import Foundation

/// Case-insensitive, non-overlapping text matches in reading order. The caller supplies its result bound; line
/// truncation and attributed highlighting stay with the view that owns them.
enum TextOccurrences {
    struct Match: Equatable {
        let line: Int
        let occurrence: Int
    }

    static func scan<Lines: Sequence>(of query: String, in lines: Lines, limit: Int) -> [Match] where Lines.Element == String {
        guard !query.isEmpty, limit > 0 else { return [] }
        var result: [Match] = []
        for (index, line) in lines.enumerated() {
            var start = line.startIndex, occurrence = 0
            while start < line.endIndex,
                  let range = line.range(of: query, options: .caseInsensitive, range: start..<line.endIndex) {
                guard !range.isEmpty else { break }
                result.append(Match(line: index, occurrence: occurrence))
                if result.count == limit { return result }
                occurrence += 1
                start = range.upperBound
            }
        }
        return result
    }
}
