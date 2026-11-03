import Foundation

struct UpdateFailure: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The same version, DMG and digest Homebrew installs. Read the cask as data; never evaluate Ruby.
struct UpdateRelease: Equatable, Sendable {
    static let feed = URL(string: "https://raw.githubusercontent.com/paulmillr/homebrew-tap/HEAD/Casks/dispatch.rb")!
    let version: String
    let sha256: String
    var url: URL { URL(string: "https://github.com/paulmillr/dispatch/releases/download/\(version)/Dispatch-\(version).dmg")! }

    init(cask: String) throws {
        func field(_ key: String) throws -> String {
            let pattern = "(?m)^\\s*" + key + "[ \\t]+\"([^\"\\r\\n]+)\"[ \\t]*$"
            let matches = try NSRegularExpression(pattern: pattern).matches(in: cask, range: NSRange(cask.startIndex..., in: cask))
            guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: cask) else {
                throw UpdateFailure("The update feed has an unsupported format.")
            }
            return String(cask[range])
        }
        version = try field("version")
        sha256 = try field("sha256").lowercased()
        guard Self.components(version) != nil,
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              try field("url") == "https://github.com/paulmillr/dispatch/releases/download/#{version}/Dispatch-#{version}.dmg" else {
            throw UpdateFailure("The update feed has an invalid version, checksum or download address.")
        }
    }

    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy({ "0123456789".contains($0) }) }) else { return nil }
        return parts.compactMap { Int($0) }
    }

    static func compare(_ lhs: String, _ rhs: String) throws -> ComparisonResult {
        guard var left = components(lhs), var right = components(rhs) else { throw UpdateFailure("The app has an unsupported version number.") }
        let length = max(left.count, right.count)
        left += Array(repeating: 0, count: length - left.count)
        right += Array(repeating: 0, count: length - right.count)
        return left == right ? .orderedSame : left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
    }
}

/// Trust belongs to the installed, signed app, never the network feed. A bridge release can authorize a new team
/// and bundle ID before distribution moves to that account. Certificate renewal within a team needs no change.
struct UpdateIdentity: Codable, Equatable, Sendable {
    let team: String
    let bundle: String

    var valid: Bool {
        team.count == 10 && team.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".contains($0) }
            && !bundle.isEmpty && bundle.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }
    }

    static func requirement(_ identities: [Self]) throws -> String {
        guard !identities.isEmpty, identities.allSatisfy(\.valid) else { throw UpdateFailure("The app’s trusted update identities are invalid.") }
        let choices = identities.map { "(certificate leaf[subject.OU] = \"\($0.team)\" and identifier \"\($0.bundle)\")" }
        return "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and (" + choices.joined(separator: " or ") + ")"
    }
}
