import SwiftUI

/// Over the list of a host whose grant has Files without Copy files in, while a drop or paste is being refused: what
/// is off, and where to turn it on. It takes no clicks, so the drag beneath it still ends where it is.
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: session.writeRefusal)
        .task(id: session.writeRefusal) {
            guard session.writeRefusal != nil else { return }
            var seen = session.writeRefusals
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.linger)
                guard !Task.isCancelled else { return }
                if session.writeRefusals == seen { session.writeRefusal = nil; return }
                seen = session.writeRefusals
            }
        }
    }

    private func notice(_ host: String) -> some View {
        let palette = Chrome.palette
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "nosign").font(.system(size: typography.size(offset: 2), weight: .semibold))
                .foregroundStyle(palette.warning).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Copying in is off for \(host)").foregroundStyle(Chrome.ink)
                Text("Turn on Copy files in under Settings › Agents & Hosts, then reconnect.")
                    .font(AppFont.ui(size: typography.size(offset: -1.5))).foregroundStyle(palette.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(AppFont.ui(size: typography.size(offset: -0.5)))
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Chrome.window, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.warning.opacity(0.45)) }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("files-write-refused")
    }
}

/// The header's mark for a host that lists and reads but takes no copies.
struct FilesReadOnlyTag: View {
    @Environment(\.appTypography) private var typography

    var body: some View {
        Text("read-only")
            .font(AppFont.ui(size: typography.size(offset: -2.5)))
            .foregroundStyle(Chrome.palette.detail)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay { Capsule().strokeBorder(Chrome.palette.detail.opacity(0.5)) }
            .fixedSize()
            .help("Copy files in is off for this host. Turn it on under Settings › Agents & Hosts, then reconnect.")
            .accessibilityIdentifier("files-read-only")
    }
}
