/// Keyboard-interactive texts made safe to show (RFC 4256 §3.3: clients should filter control characters): already
/// read leniently (`readDisplayText`, bounded by `Limits.authenticationTextBytes`), then every control and format
/// character (escapes, bidirectional overrides, zero-width characters) is dropped, a tab becomes a space, and line
/// breaks are kept only in `multiline` text (the instruction), as "\n"; elsewhere they become a space. Spaces are
/// kept as sent ("Password: "), unlike `DisplayText.sanitize`, and nothing is cut: the app lays the texts out.
enum PromptText {
  static func sanitize(_ text: String, multiline: Bool) -> String {
    var result = String.UnicodeScalarView()
    var previousWasCR = false
    for scalar in text.unicodeScalars {
      defer { previousWasCR = scalar == "\r" }
      let category = scalar.properties.generalCategory
      let lineBreak = scalar == "\n" || scalar == "\r" || category == .lineSeparator || category == .paragraphSeparator
      if lineBreak {
        // CR LF is one break.
        if scalar == "\n" && previousWasCR { continue }
        result.append(multiline ? "\n" : " ")
      } else if scalar == "\t" {
        result.append(" ")
      } else if category == .control || category == .format {
        // U+FFFD (an invalid sequence, a Latin-1 byte) is kept: the user sees something was there.
        continue
      } else {
        result.append(scalar)
      }
    }
    return String(result)
  }
}
