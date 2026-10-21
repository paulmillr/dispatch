import SwiftUI

/// The hint for a host with neither tmux nor herdr (plan 3.2): spaces are their sessions, so the host needs one.
/// The app never installs anything but its helper; these are the commands to run on the host
/// (docs/integrations.md, tmux and herdr).
struct MultiplexerHint: View {
    let hostID: UUID
    @Environment(HostSessions.self) private var sessions

    struct Command: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

    static let herdr = [
        Command(title: "macOS", text: "mkdir -p ~/.local/bin && curl -fL -o ~/.local/bin/herdr https://github.com/herdrdev/herdr/releases/download/v0.9.3/herdr-macos-$(uname -m | sed s/arm64/aarch64/) && chmod +x ~/.local/bin/herdr"),
        Command(title: "Linux", text: "mkdir -p ~/.local/bin && curl -fL -o ~/.local/bin/herdr https://github.com/herdrdev/herdr/releases/download/v0.9.3/herdr-linux-$(uname -m) && chmod +x ~/.local/bin/herdr"),
    ]
    static let tmux = [
        Command(title: "macOS (Homebrew)", text: "brew install tmux"),
        Command(title: "Debian, Ubuntu", text: "sudo apt install tmux"),
        Command(title: "Fedora", text: "sudo dnf install tmux"),
    ]

    var body: some View {
        let name = sessions.session(hostID)?.host.name ?? "this host"
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                        .frame(width: 84, height: 84)
                        .background(Color.faintFill, in: Circle())
                    Text("No tmux or herdr").font(.title2.bold())
                    Text("Dispatch shows the herdr workspaces or tmux sessions on \(name) as spaces, and keeps them running while your \(MobileDevice.name) is away. Install one of them on \(name), then reconnect.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            Section {
                ForEach(Self.herdr) { CommandRow(command: $0) }
            } header: {
                Text("herdr")
            } footer: {
                Text("Preferred when both are installed. Dispatch is validated with herdr 0.9.3.")
            }
            Section {
                ForEach(Self.tmux) { CommandRow(command: $0) }
            } header: {
                Text("tmux")
            } footer: {
                Text("tmux 3.7 or newer lets Dispatch check that an agent is ready before it pastes.")
            }
            if let session = sessions.session(hostID) {
                Section {
                    Button("Reconnect") {
                        session.disconnect()
                        session.connect()
                    }
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CommandRow: View {
    let command: MultiplexerHint.Command
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(command.title).font(.subheadline.weight(.semibold))
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = command.text
                    copied = true
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Copy \(command.title) command")
            }
            Text(command.text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
