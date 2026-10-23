import SwiftUI

/// Host detail (M1f, W4), pushed from Spaces (Info in edit mode, or a host section's long-press menu): identity and live
/// status (its disc opens the stats sheet), the stat strip and 15-minute sparkline (`HostStatistics`, not for a plain
/// SSH host), Connection (what the user entered, as fact rows), the multiplexer, the host's spaces (their header marks
/// the multiplexer they come from), and Remove host last, in red. The spaces rows come from Tabs (`spaces`); without them the topology's workspaces are listed.
/// The Helper switch and Chat sit under the multiplexer; a plain SSH host (docs/ios.md) says so there, with the reason
/// the helper could not start and "Use plain SSH for this host" when that was a fallback.
struct HostDetail<Spaces: View>: View {
    let hostID: UUID
    /// The rows of the Spaces section, for this session.
    let spaces: (HostSession) -> Spaces
    /// How many rows `spaces` lists (Tabs' workspace: a plain host's Shell space has no topology); nil counts the
    /// topology's workspaces (`HostSummary.spaces`).
    let count: ((HostSession) -> Int)?
    @Environment(HostSessions.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    /// The name in the host's tint on dark (M1f); on the light canvas the pale tints would not read, so the label.
    @Environment(\.colorScheme) private var scheme
    @State private var editing = false
    @State private var confirmingRemoval = false
    /// The stats sheet (W1), from the disc.
    @State private var statsHost: UUID?
    @State private var metric = HostStatistics.Metric.cpu
    @State private var scrub: Int?
    /// Removal waits for the pop to finish, so the screen sliding away still shows the host.
    @State private var removing = false

    init(hostID: UUID, count: ((HostSession) -> Int)? = nil, @ViewBuilder spaces: @escaping (HostSession) -> Spaces) {
        self.hostID = hostID
        self.count = count
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

            // W4: the stats block between the header and Connection; a host without its helper has none.
            if !session.plainSSH {
                Section {
                    StatStripCard(stats: session.stats, metric: $metric, tint: host.tint.color,
                                  dimmed: !session.stats.live, scrub: $scrub)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                Group {
                    FactRow(label: "Address", value: host.address)
                    FactRow(label: "Port", value: String(host.port))
                    FactRow(label: "User", value: host.user)
                    FactRow(label: "Key", value: sessions.keyName(host))
                    if host.helper { multiplexer(session) }
                }
                // The fact rows carry their own 7 points above and below (W4).
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                HostHelperRows(session: session)
            } header: {
                MobileSectionHeader("Connection")
            }

            let count = count?(session) ?? summary.spaces.count
            if count > 0 {
                Section { spaces(session) } header: {
                    // The multiplexer they come from, as Spaces' host header marks it.
                    HStack(spacing: 8) {
                        MobileSectionHeader("Spaces · \(count)")
                        if session.isPlain {
                            PlainSSHMark()
                        } else if let multiplexer = session.spacesMultiplexer {
                            MultiplexerMark(name: multiplexer)
                        }
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
        // W4's fact rows are tighter than a list's 44 points.
        .environment(\.defaultMinListRowHeight, 36)
        .listSectionSpacing(18)
        .hostStatsSheet(host: $statsHost)
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
            Button { statsHost = session.id } label: {
                HostGlyph(host: session.host, size: 44)
                    .foregroundStyle(summary.tint)
                    .frame(width: 84, height: 84)
                    .background(summary.tint.opacity(0.15), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(session.host.name) stats")
            .accessibilityHint("Shows CPU, memory, disk and processes")
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
                Button("Connect") { session.connectByUser() }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// "herdr 0.9.3", "tmux 3.7" or "none", with the per-host choice. None leads to the install hint.
    @ViewBuilder private func multiplexer(_ session: HostSession) -> some View {
        let line = session.multiplexerLine
        if line == "none" {
            NavigationLink {
                MultiplexerHint(hostID: session.id)
            } label: {
                FactRow(label: "Multiplexer", value: "none")
            }
        } else {
            Menu {
                HostMultiplexerPicker.choices(session: session, sessions: sessions)
            } label: {
                FactRow(label: "Multiplexer", value: line ?? session.host.multiplexer.title, chevron: true)
                    .foregroundStyle(Color(uiColor: .label))
            }
            .accessibilityLabel("Multiplexer")
            .accessibilityValue(line ?? session.host.multiplexer.title)
        }
    }
}

/// Host detail's Helper switch, Chat with the helper, and the Plain SSH line (`HostSummary.plainLine`) with "Use plain
/// SSH for this host" when the connection fell back (`HostSummary.offersPlainSSH`).
struct HostHelperRows: View {
    let session: HostSession
    @Environment(HostSessions.self) private var sessions

    static let usePlainSSH = "Use plain SSH for this host"

    var body: some View {
        let summary = HostSummary(session: session)
        Toggle("Helper", isOn: Binding(get: { session.host.helper }, set: { sessions.setHelper($0, host: session.id) }))
            .accessibilityHint(NewHostSheet.helperHint)
        if session.host.helper {
            Toggle("Chat", isOn: Binding(get: { session.host.chat }, set: { chat in
                var host = session.host
                host.chat = chat
                sessions.update(host)
            }))
            HostFilesSwitch(session: session)
        }
        if let line = summary.plainLine {
            Text(line)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if summary.offersPlainSSH {
            Button(Self.usePlainSSH) { sessions.setHelper(false, host: session.id) }
                .accessibilityHint("Turns the helper off: \(session.host.name) connects with plain SSH from now on")
        }
    }
}

extension HostSessions {
    /// The Helper switch (host detail; "Use plain SSH for this host" turns it off), saved at once: the session reconnects
    /// with the new choice (`update`). Off turns Chat and Files & git off with it (`HostRecord.helper`); on turns them on
    /// again, as New host does (`HostFeatureDraft`), and the switches beside it turn them off.
    func setHelper(_ helper: Bool, host id: UUID) {
        guard var record = store.record(id), record.helper != helper else { return }
        record.helper = helper
        if helper {
            record.chat = true
            record.files = true
        }
        update(record)
    }
}

/// The Files & git switch (host detail, a host's Settings): the helper may read files and git in the tabs' folders
/// (`HostRecord.files`, `HelperGrant`). Saved at once; on reconnects, off narrows the running helper's grant.
struct HostFilesSwitch: View {
    let session: HostSession
    @Environment(HostSessions.self) private var sessions

    static let title = "Files & git"

    var body: some View {
        Toggle(Self.title, isOn: Binding(get: { session.host.files }, set: { files in
            var host = session.host
            host.files = files
            sessions.update(host)
        }))
        .disabled(!session.host.helper)
        .accessibilityHint("Lets the helper list and read files and run read-only git commands on \(session.host.name)")
    }
}

/// The host's multiplexer choice (Automatic, herdr, tmux) with the one in use: host detail (M1f) and Settings. A new
/// choice is saved at once and followed on the live connection (no reconnect).
struct HostMultiplexerPicker: View {
    let session: HostSession
    @Environment(HostSessions.self) private var sessions

    /// The choices: Automatic, herdr, tmux, saved at once.
    static func choices(session: HostSession, sessions: HostSessions) -> some View {
        Picker("Multiplexer", selection: Binding(get: { session.host.multiplexer }, set: { choice in
            var host = session.host
            host.multiplexer = choice
            sessions.update(host)
        })) {
            ForEach(HostRecord.MultiplexerPreference.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }

    var body: some View {
        Menu {
            Self.choices(session: session, sessions: sessions)
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
        self.init(hostID: hostID, count: nil) { HostSpacesList(session: $0) }
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
