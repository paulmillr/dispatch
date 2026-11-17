/// Server-supplied text made safe to show or log: a DISCONNECT description, a channel open failure's message.
/// Decoded as UTF-8 with invalid sequences replaced, control and format characters (line breaks, escapes,
/// bidirectional overrides, zero-width characters) turned into spaces, runs of spaces collapsed, and cut to `limit`
/// Unicode scalars with an ellipsis. Never used for anything the engine acts on.
public enum DisplayText {
  public static func sanitize(_ bytes: [UInt8], limit: Int = Limits.displayTextCharacters) -> String {
    let decoded = String(decoding: bytes, as: UTF8.self)
    var result = ""
    var count = 0
    var pendingSpace = false
    for scalar in decoded.unicodeScalars {
      let category = scalar.properties.generalCategory
      let blank = category == .control || category == .format || category == .lineSeparator
        || category == .paragraphSeparator || category == .spaceSeparator || scalar == "\u{FFFD}"
      if blank {
        pendingSpace = !result.isEmpty
        continue
      }
      if pendingSpace {
        guard count < limit else { return result + "…" }
        result.unicodeScalars.append(" ")
        count += 1
        pendingSpace = false
      }
      guard count < limit else { return result + "…" }
      result.unicodeScalars.append(scalar)
      count += 1
    }
    return result
  }
}
