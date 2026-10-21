import SwiftUI

/// Host detail (M1f), pushed from Spaces (Info in edit mode, or a host section's long-press menu): identity and live
/// status, Connection (what the user entered, editable), the multiplexer, the host's spaces (their header marks the
/// multiplexer they come from), and Remove host last, in red. The spaces rows come from Tabs (`spaces`); without them the topology's workspaces are listed.
struct HostDetail<Spaces: View>: View {
    let hostID: UUID
    /// The rows of the Spaces section, for this session.
    let spaces: (HostSession) -> Spaces
    @Environment(HostSessions.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    /// The name in the host's tint on dark (M1f); on the light canvas the pale tints would not read, so the label.
    @Environment(\.colorScheme) private var scheme
    @State private var editing = false
    @State private var confirmingRemoval = false
    /// Removal waits for the pop to finish, so the screen sliding away still shows the host.
    @State private var removing = false

    init(hostID: UUID, @ViewBuilder spaces: @escaping (HostSession) -> Spaces) {
        self.hostID = hostID
        self.spaces = spaces
    }

    var body: some View {
        if let session = sessions.session(hostID) {
            content(session)
        } else {
            // Removed elsewhere while open: nothing rather than a broken host.
            Color.clear
        }
    }

    private func content(_ session: HostSession) -> some View {
        let summary = HostSummary(session: session)
        let host = session.host
        return List {
            Section {
                header(session, summary: summary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                LabeledContent("Address") { Text(host.address).monospaced() }
                LabeledContent("Port") { Text(String(host.port)).monospaced() }
                LabeledContent("User") { Text(host.user).monospaced() }
                LabeledContent("Key") { Text(keyName(host)).monospaced() }
                multiplexer(session)
            } header: {
                MobileSectionHeader("Connection")
            }

            let count = summary.spaces.count
            if count > 0 {
                Section { spaces(session) } header: {
                    // The multiplexer they come from, as Spaces' host header marks it.
                    HStack(spacing: 8) {
                        MobileSectionHeader("Spaces · \(count)")
                        if let multiplexer = session.spacesMultiplexer { MultiplexerMark(name: multiplexer) }
                    }
                }
            }

            Section {
                Button(role: .destructive) { confirmingRemoval = true } label: {
                    Text("Remove host").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .tint(.red)
                // Anchored to the button, so the dialog rises from it.
                .confirmationDialog("Remove \(host.name)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                    Button("Remove host", role: .destructive) {
                        removing = true
                        dismiss()
                    }
                } message: {
                    Text(HostSessions.removalMessage)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .listStyle(.insetGrouped)
        // The identity sits right under the bar, as in M1f (the list's own top margin pushed it 36 points down).
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true }.tint(Color.dispatchPink) }
        }
        .onDisappear {
            if removing { sessions.remove(hostID) }
        }
        .sheet(isPresented: $editing) {
            NewHostSheet(editing: host).tint(.dispatchPink)
        }
    }

    private func header(_ session: HostSession, summary: HostSummary) -> some View {
        VStack(spacing: 10) {
            HostGlyph(host: session.host, size: 44)
                .foregroundStyle(summary.tint)
                .frame(width: 84, height: 84)
                .background(summary.tint.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            Text(session.host.name)
                .font(.title2.bold())
                .foregroundStyle(scheme == .dark ? summary.tint : Color.primary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 7) {
                Circle().fill(summary.statusColor).frame(width: 8, height: 8)
                Text(summary.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            if let problem = summary.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
            if let os = summary.osLabel {
                Text(os).font(.footnote).foregroundStyle(.tertiary)
            }
            if !session.link.isConnected, !session.link.isPending, session.hostKeyMismatch == nil {
                Button("Connect") { session.retryNow() }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func keyName(_ host: HostRecord) -> String {
        switch host.auth {
        case .password: "Password"
        case .key(let id): sessions.keys.key(id)?.label ?? "Missing key"
        }
    }

    /// "herdr 0.9.3", "tmux 3.7" or "none", with the per-host choice. None leads to the install hint.
    @ViewBuilder private func multiplexer(_ session: HostSession) -> some View {
        let line = session.multiplexerLine
        if line == "none" {
            NavigationLink {
                MultiplexerHint(hostID: session.id)
            } label: {
                LabeledContent("Multiplexer") { Text("none").monospaced() }
            }
        } else {
            HostMultiplexerPicker(session: session)
        }
    }
}

/// The host's multiplexer choice (Automatic, herdr, tmux) with the one in use: host detail (M1f) and Settings. A new
/// choice is saved at once and followed on the live connection (no reconnect).
struct HostMultiplexerPicker: View {
    let session: HostSession
    @Environment(HostSessions.self) private var sessions

    var body: some View {
        Menu {
            Picker("Multiplexer", selection: Binding(get: { session.host.multiplexer }, set: { choice in
                var host = session.host
                host.multiplexer = choice
                sessions.update(host)
            })) {
                ForEach(HostRecord.MultiplexerPreference.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            HStack {
                // Explicit colours: a menu label otherwise draws in the tint.
                Text("Multiplexer").foregroundStyle(Color(uiColor: .label))
                Spacer()
                Text(session.multiplexerLine ?? session.host.multiplexer.title).monospaced()
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
        }
    }
}

extension HostDetail where Spaces == HostSpacesList {
    /// With the topology's workspaces as the Spaces rows (previews, and until Tabs injects its own).
    init(hostID: UUID) {
        self.init(hostID: hostID) { HostSpacesList(session: $0) }
    }
}

/// A host's spaces from its topology: glyph, name and folder; a chevron when `HostSpaceOpening` is set.
struct HostSpacesList: View {
    let session: HostSession
    @Environment(\.hostSpaceOpening) private var spaceOpening

    var body: some View {
        ForEach(HostSummary(session: session).spaces) { space in
            if let spaceOpening {
                Button { spaceOpening.open(host: session.id, space: space.id) } label: {
                    HStack {
                        row(space)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
            } else {
                row(space)
            }
        }
    }

    private func row(_ space: HostSummary.Space) -> some View {
        HStack(spacing: 12) {
            HostGlyph(host: session.host, size: 16)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            Text(space.name).font(.headline)
            if let folder = space.folder {
                Text(folder).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
    }
}
