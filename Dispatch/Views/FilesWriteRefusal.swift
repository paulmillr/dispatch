import SwiftUI

/// Over the list of a host whose grant has Files without Copy files in, while a drop or paste is being refused: what
/// is off, and where to turn it on; or, for rows dragged within their own list, that Files copies only, with ⌥. It
/// takes no clicks, so the drag beneath it still ends where it is.
struct FilesWriteRefusal: View {
    let session: FilesSession
    @Environment(\.appTypography) private var typography
    /// Refused attempts stop arriving for this long before the notice goes.
    static let linger: Duration = .milliseconds(1500)

    var body: some View {
        ZStack {
            if let host = session.writeRefusal {
                notice(host)
                    .transition(.opacity)
            } else if session.moveRefused {
                notice(title: "Hold ⌥ to copy here",
                       detail: "Files copies and never moves: ⌥-drag makes a copy in this folder.", symbol: "plus.square.on.square",
                       identifier: "files-move-refused")
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: session.writeRefusal)
        .animation(.easeOut(duration: 0.15), value: session.moveRefused)
        .task(id: session.writeRefusal ?? (session.moveRefused ? "move" : nil)) {
            guard session.writeRefusal != nil || session.moveRefused else { return }
            var seen = session.writeRefusals
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.linger)
                guard !Task.isCancelled else { return }
                if session.writeRefusals == seen {
                    session.writeRefusal = nil
                    session.moveRefused = false
                    return
                }
                seen = session.writeRefusals
            }
        }
    }

    private func notice(_ host: String) -> some View {
        notice(title: "Copying in is off for \(host)", detail: "Turn on Copy files in under Settings › Hosts, then reconnect.",
               symbol: "nosign", identifier: "files-write-refused")
    }

    private func notice(title: String, detail: String, symbol: String, identifier: String) -> some View {
        let palette = Chrome.palette
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: typography.size(offset: 2), weight: .semibold))
                .foregroundStyle(palette.warning).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(Chrome.ink)
                Text(detail)
                    .font(typography, .body).foregroundStyle(palette.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(typography, .label)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Chrome.window, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.warning.opacity(0.45)) }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// The header's mark for a host that lists and reads but takes no copies.
struct FilesReadOnlyTag: View {
    @Environment(\.appTypography) private var typography

    var body: some View {
        Text("read-only")
            .font(typography, .caption)
            .foregroundStyle(Chrome.palette.detail)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay { Capsule().strokeBorder(Chrome.palette.detail.opacity(0.5)) }
            .fixedSize()
            .help("Copy files in is off for this host. Turn it on under Settings › Hosts, then reconnect.")
            .accessibilityIdentifier("files-read-only")
    }
}
