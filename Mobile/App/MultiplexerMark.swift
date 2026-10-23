import SwiftUI

/// Which multiplexer a host's spaces come from: "tmux" or "herdr" in a small grey chip, in the caption's monospaced face
/// (the names are commands; neither project has a mark of its own to draw). Spaces' host headers, host detail's Spaces
/// header and New space's host field show it. A host shows one multiplexer's spaces at a time; while that is unknown
/// (none followed yet, a switch on its way: `HostSession.spacesMultiplexer`) the views draw no chip.
struct MultiplexerMark: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.chipFill, in: Capsule())
            .accessibilityLabel(name)
    }
}

/// A plain SSH host (docs/ios.md, Plain SSH: no helper, so no multiplexer's spaces) where `MultiplexerMark` goes, in
/// the same chip: Spaces' host headers and host detail's Spaces header.
struct PlainSSHMark: View {
    var body: some View { MultiplexerMark(name: HostSummary.plainSSH) }
}
