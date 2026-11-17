/// The identification exchange (RFC 4253 §4.2). The client sends its line first; the server may send other lines
/// before its own (at most `Limits.preVersionLines`, each at most `Limits.versionLineBytes` with its line end), and
/// its identification line must be `SSH-2.0-` or `SSH-1.99-` (§5.1: a server that also speaks 2.0) followed by a
/// software version. Lines end with CR LF; a bare LF is taken too, as OpenSSH does. The line as hashed (`V_S`) has no
/// line end.
enum VersionExchange {
  enum Line: Equatable {
    /// A whole line without its LF (a CR before it is still there).
    case line([UInt8])
    case needMore
  }

  /// Takes one line from the front of `bytes`, at most `Limits.versionLineBytes` long with its LF.
  static func takeLine(_ bytes: ArraySlice<UInt8>) throws(SSHError) -> (Line, consumed: Int) {
    let window = bytes.prefix(Limits.versionLineBytes)
    if let end = window.firstIndex(of: 0x0A) {
      let line = Array(bytes[bytes.startIndex..<end])
      return (.line(line), end - bytes.startIndex + 1)
    }
    guard window.count < Limits.versionLineBytes else { throw .protocolViolation(.version(.lineTooLong)) }
    return (.needMore, 0)
  }

  /// The identification line without its line end, or nil for a line that is not one (it may precede it).
  static func identification(_ rawLine: [UInt8]) throws(SSHError) -> [UInt8]? {
    let line = rawLine.last == 0x0D ? Array(rawLine.dropLast()) : rawLine
    guard line.starts(with: Array("SSH-".utf8)) else { return nil }
    guard let prefix = ["SSH-2.0-", "SSH-1.99-"].map({ Array($0.utf8) }).first(where: { line.starts(with: $0) }) else {
      throw .protocolViolation(.version(.notSSH2))
    }
    // Printable US-ASCII and spaces only (no CR, NUL or controls inside), and a software version after the prefix.
    guard line.count > prefix.count, line[prefix.count] != 0x20,
      line.allSatisfy({ (0x20...0x7E).contains($0) })
    else { throw .protocolViolation(.version(.malformedLine)) }
    return line
  }
}
