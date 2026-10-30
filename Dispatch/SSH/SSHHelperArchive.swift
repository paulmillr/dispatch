import Foundation

/// The Mac bundles the Linux helpers gzipped (`helper/<name>.gz`, written by scripts/build-ssh-helper.py): a host with
/// `gzip` gets them as they are and expands them itself (`SSHBootstrapScript.upload(compressed:)`); the app expands them
/// only for a host without it, and for the helper's identity (size and SHA-256 are always the expanded file's).
enum SSHHelperArchive {
    /// The helpers bundled gzipped: the ones only ever uploaded. `darwin-arm64` is also the app's own helper, kept as is.
    static let compressed: Set<String> = ["linux-aarch64", "linux-x86_64"]

    /// The helper in the gzip file `gzip` (`GzipMember`); a file that does not expand is a permanent setup failure.
    static func expand(_ gzip: Data) throws -> Data {
        do { return try GzipMember.expand(gzip) } catch { throw failure(error.reason) }
    }

    private static func failure(_ reason: String) -> SSHSetupFailure {
        .permanent("SSH helper is missing or invalid.", reason: "the bundled helper archive: " + reason)
    }
}
