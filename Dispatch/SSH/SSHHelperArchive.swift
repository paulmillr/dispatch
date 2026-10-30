import Compression
import Foundation

/// The Mac bundles the Linux helpers gzipped (`helper/<name>.gz`, written by scripts/build-ssh-helper.py): a host with
/// `gzip` gets them as they are and expands them itself (`SSHBootstrapScript.upload(compressed:)`); the app expands them
/// only for a host without it, and for the helper's identity (size and SHA-256 are always the expanded file's).
enum SSHHelperArchive {
    /// The helpers bundled gzipped: the ones only ever uploaded. `darwin-arm64` is also the app's own helper, kept as is.
    static let compressed: Set<String> = ["linux-aarch64", "linux-x86_64"]

    /// What a single-member gzip file (RFC 1952) holds: the header (with any optional fields), the raw DEFLATE stream,
    /// then CRC-32 and the length. The length decides the output size; the CRC is left to the SHA-256 the host checks.
    static func expand(_ gzip: Data) throws -> Data {
        let bytes = [UInt8](gzip)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw failure("not a gzip file") }
        let flags = bytes[3]
        var start = 10
        if flags & 0x04 != 0 {
            guard start + 2 <= bytes.count else { throw failure("truncated header") }
            start += 2 + Int(bytes[start]) | Int(bytes[start + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            guard let end = bytes[min(start, bytes.count)...].firstIndex(of: 0) else { throw failure("truncated header") }
            start = end + 1
        }
        if flags & 0x02 != 0 { start += 2 }
        let trailer = bytes.count - 8
        guard start < trailer else { throw failure("truncated file") }
        let size = Int(bytes[trailer + 4]) | Int(bytes[trailer + 5]) << 8 | Int(bytes[trailer + 6]) << 16 | Int(bytes[trailer + 7]) << 24
        guard size > 0, size <= SSHBootstrapScript.maximumSize else { throw failure("bad length") }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBufferPointer { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
                                          source.baseAddress! + start, trailer - start, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw failure("does not expand to its length") }
        return output
    }

    private static func failure(_ reason: String) -> SSHSetupFailure {
        .permanent("SSH helper is missing or invalid.", reason: "the bundled helper archive: " + reason)
    }
}
