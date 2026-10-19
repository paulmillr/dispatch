import SwiftUI

/// Files on a tab that cannot list them (F2e): what it needs and the one thing that fixes it.
struct FilesUnavailableView: View {
    let session: FilesSession
    @Environment(\.appTypography) private var typography
    @Environment(\.chatTheme) private var theme

    var body: some View {
        switch session.availability {
        case .plainSSH(let host):
            message(Text("Files need dispatch-helper on ") + Text(host).foregroundStyle(theme.blue),
                    detail: "This tab connected as plain SSH. The helper lists, reads and copies files; it opens no ports.") {
                Button("Install helper…") { openIntegration(nil) }
                    .buttonStyle(FilesButtonStyle(primary: true))
                    .help("Choose Full features for this host; the helper starts with its next connection")
                    .accessibilityIdentifier("files-install-helper")
                notNow
            }
        case .notGranted(let host, let scope):
            message(Text("Files are off for ") + Text(host).foregroundStyle(theme.blue),
                    detail: "This connection’s helper may not list, read or copy files. Turn Files on in its integration to use them here.") {
                Button("Change integration…") { openIntegration(scope) }
                    .buttonStyle(FilesButtonStyle(primary: true))
                    .accessibilityIdentifier("files-change-integration")
                notNow
            }
        case .unavailable(let reason):
            message(Text("Files are unavailable"), detail: reason) { notNow }
        case .loading, .available, .offline:
            EmptyView()
        }
    }

    private var notNow: some View {
        Button("Not now") { TerminalRuntime.shared.files.switchMode(session.id, to: .terminal) }
            .buttonStyle(FilesButtonStyle())
            .help("Show the terminal")
            .accessibilityIdentifier("files-not-now")
    }

    private func message(_ title: Text, detail: String, @ViewBuilder actions: () -> some View) -> some View {
        let palette = Chrome.palette
        return VStack(spacing: 10) {
            title.foregroundStyle(palette.secondary)
                .font(AppFont.ui(size: typography.size(offset: -0.5)))
            Text(detail)
                .font(AppFont.ui(size: typography.size(offset: -1.5)))
                .foregroundStyle(palette.detail)
                .lineSpacing(3)
            HStack(spacing: 8) { actions() }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: typography.expanded(420))
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-unavailable")
    }

    /// The integration sheet of this tab's login, else Settings, where Agents & Hosts lists every host.
    private func openIntegration(_ scope: SSHIntegrationScope?) {
        let ssh = TerminalRuntime.shared.ssh
        if let scope {
            ssh.editIntegration(scope)
        } else if let host = TerminalRuntime.shared.workspace?.hosts.terminals[session.id]?.host,
                  let entry = ssh.integrationEntries(for: host).first {
            ssh.editIntegration(entry.scope)
        } else {
            (NSApp.delegate as? AppDelegate)?.showSettings()
        }
    }
}

/// The amber bar over the dimmed last listing while the host is offline (F2e): never a stale list shown as live.
/// Its colours are the reconnect bar's (`SSHReconnectControl`): amber, 9 % into the window colour.
struct FilesOfflineBar: View {
    let session: FilesSession
    let host: String
    let since: Date?
    @Environment(\.appTypography) private var typography
    @Environment(\.chatTheme) private var theme

    var body: some View {
        let amber = SSHReconnectControl.stateColor(connected: false)
        let controller = TerminalRuntime.shared.hosts.reconnect
        let hostID = TerminalRuntime.shared.workspace?.hosts.terminals[session.id]?.host
        let reconnecting = controller.presentationState(for: session.id)?.reconnecting == true
        HStack(spacing: 10) {
            Text("◆").foregroundStyle(Color(nsColor: amber))
            // The age moves on by the minute without a listing to refresh it.
            TimelineView(.everyMinute) { _ in
                Text(label(at: System.date()))
                    .foregroundStyle(Color(nsColor: amber.blended(withFraction: 0.35, of: NSColor(Chrome.ink)) ?? amber))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(reconnecting ? "Reconnecting…" : "Reconnect") {
                if let hostID { controller.reconnect(hostID: hostID, sourceSurfaceID: session.id) }
            }
            .buttonStyle(FilesButtonStyle(tint: Color(nsColor: amber)))
            .disabled(hostID == nil || reconnecting)
            .help("Reconnect to \(host)")
            .accessibilityIdentifier("files-reconnect")
        }
        .font(AppFont.ui(size: typography.size(offset: -1.5)))
        .padding(.horizontal, 12)
        .frame(height: typography.expanded(34))
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: NSColor(Chrome.window).blended(withFraction: 0.09, of: amber) ?? NSColor(Chrome.window)))
        .overlay(alignment: .bottom) { Color(nsColor: amber).opacity(0.3).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-offline-bar")
    }

    private func label(at now: Date) -> String {
        guard let since = since ?? session.staleSince else { return "\(host) offline" }
        return "\(host) offline · \(FilesFormatting.staleness(since: since, at: now))"
    }
}

/// Nothing for the first 300 ms, then a muted "Loading…": a fast listing never flashes it.
struct FilesLoadingView: View {
    @Environment(\.appTypography) private var typography
    @State private var shown = false

    var body: some View {
        Text("Loading…")
            .font(AppFont.ui(size: typography.size(offset: -1)))
            .foregroundStyle(Chrome.palette.detail)
            .opacity(shown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                // Wall time, not System.sleep: the delay only keeps a quick load from flashing the label, and it starts
                // when SwiftUI first draws this view, which a replay cannot place among the recorded events.
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                shown = true
            }
            .accessibilityHidden(!shown)
            .accessibilityIdentifier("files-loading")
    }
}

/// The mockup's `.btn` and `.btn.pri`: 22 pt, a faint wash, or the accent for the action that fixes things.
struct FilesButtonStyle: ButtonStyle {
    var primary = false
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        FilesButton(configuration: configuration, primary: primary, tint: tint)
    }

    private struct FilesButton: View {
        let configuration: Configuration
        let primary: Bool
        let tint: Color?
        @Environment(\.appTypography) private var typography
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let palette = Chrome.palette
            let fill: Color = if let tint { tint.opacity(0.18) } else if primary { palette.accent } else { palette.ink.opacity(0.07) }
            let ink: Color = if let tint { tint } else if primary { Color(nsColor: SSHReconnectControl.actionInk) }
                else { palette.secondary }
            configuration.label
                .font(AppFont.ui(size: typography.size(offset: -1.5)))
                .lineLimit(1)
                .foregroundStyle(ink)
                .padding(.horizontal, 10)
                .frame(height: typography.expanded(22))
                .background(RoundedRectangle(cornerRadius: 5).fill(fill))
                .opacity(configuration.isPressed ? 0.75 : enabled ? 1 : 0.5)
                .contentShape(Rectangle())
        }
    }
}
