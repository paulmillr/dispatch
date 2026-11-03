import Foundation

/// A signature verdict, signer, and key, apart from each platform's badge presentation.
enum GitSignatureExplanation {
    /// The help: "Sam Example <sam@example.com> · GPG key ID: 01234567…" for a good certified signature, the verdict
    /// first for any other ("Bad GPG signature · …").
    static func detail(_ check: GitSignatureCheck?, kind: GitSignatureKind) -> String {
        guard let check else { return "Checking the \(kind.title) signature…" }
        let kind = check.kind ?? kind
        let name = kind.title
        let verdict: String? = switch check.verdict {
        case .good(true): nil
        case .good(false): "Good \(name) signature, key not certified"
        case .bad: "Bad \(name) signature"
        case .unknownKey: kind == .ssh ? "\(name) signature from a key not in your allowed signers"
                                       : "\(name) signature from a key not in your keyring"
        case .expiredSignature: "Expired \(name) signature"
        case .expiredKey: "\(name) signature from an expired key"
        case .revokedKey: "\(name) signature from a revoked key"
        case .unsigned: "Not signed"
        case .unchecked(let reason): "Signed with \(name) · couldn’t check: \(reason)"
        }
        let key = check.key.map { kind == .ssh ? "SSH key: \($0)" : "\(name) key ID: \($0)" }
        let parts = [verdict, check.signer, key].compactMap { $0 }
        return parts.isEmpty ? "Good \(name) signature" : parts.joined(separator: " · ")
    }
}
