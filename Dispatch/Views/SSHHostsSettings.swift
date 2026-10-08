import SwiftUI

/// Remote hosts: the policy for new hosts, then each known machine with one
/// line per login showing what its helper may do. A login is keyed by account
/// and SSH configuration, so one machine can have several; logins not yet
/// matched to a machine this launch are listed at the end. Clicking a row
/// edits its logins' helper choices in place.
struct SSHHostsSettings: View {
    typealias Entry = SSHIntegrationPermissions.Entry
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let workspace: Workspace
    let permissions: SSHIntegrationPermissions
    var policy: Binding<NewHostPolicy> = .constant(.ask)
    var clipboard: Binding<Bool> = .constant(false)
    var reconnect: Binding<Bool> = .constant(false)
    var colors: Binding<Bool> = .constant(true)
    var resetting = false
    var forgetAll: () -> Void = {}
    var logins: (HostID) -> [String] = { host in TerminalRuntime.shared.ssh.integrationEntries(for: host).map(\.id) }
    @State private var expanded: String?
    @State private var forgetting: String?
    /// The login each expanded multi-login host is editing.
    @State private var account: [String: String] = [:]
    /// Choices kept while they still match what is saved, so switching the
    /// helper off and on again keeps the features chosen under it.
    @State private var drafts: [String: SSHIntegrationDraft] = [:]

    private var hosts: [HostRecord] {
        workspace.hosts.ordered(Set(workspace.hosts.records.keys)).filter { $0.id != .local }
    }

    private var entries: [Entry] {
        permissions.entries.values.sorted {
            ($0.scope.destination, $0.scope.account, $0.scope.key) < ($1.scope.destination, $1.scope.account, $1.scope.key)
        }
    }

    var body: some View {
        let grouped = hosts.map { host in (host, logins(host.id).compactMap { permissions.entries[$0] }) }
        let matched = Set(grouped.flatMap { $0.1.map(\.id) })
        let other = entries.filter { !matched.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Remote hosts").fontWeight(.semibold).foregroundStyle(SettingsControlStyle.selectedText)
                Spacer(minLength: 0)
                // Always offered: it also clears a stale saved session with nothing listed.
                Button(resetting ? "Resetting…" : "Reset all…", action: forgetAll)
                    .buttonStyle(.plain).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .disabled(resetting)
                    .accessibilityIdentifier("settings-reset-all-host-integrations")
                    .help("Disconnect SSH and forget every host’s saved tabs, helper choices and caches. Global preferences are kept.")
            }.padding(.horizontal, 14).padding(.vertical, 11)
            separator
            policyRow
            separator.padding(.horizontal, 14)
            clipboardRow
            separator.padding(.horizontal, 14)
            reconnectRow
            separator.padding(.horizontal, 14)
            colorsRow
            if !grouped.isEmpty || !other.isEmpty { separator }
            ForEach(grouped, id: \.0.id) { host, logins in
                row(id: host.id.rawValue, host: host, logins: logins)
                if host.id != grouped.last?.0.id { separator.padding(.horizontal, 14) }
            }
            if !other.isEmpty {
                if !grouped.isEmpty { separator }
                Text("OTHER LOGINS").font(typography.font(offset: -2.5)).tracking(1).foregroundStyle(SettingsControlStyle.detail)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                    .help("Saved helper choices for SSH configurations that haven’t connected since Dispatch launched")
                ForEach(other) { entry in
                    row(id: entry.id, host: nil, logins: [entry])
                    if entry.id != other.last?.id { separator.padding(.horizontal, 14) }
                }
            }
        }.background(Chrome.sidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.border) }
            .accessibilityIdentifier("settings-host-integrations")
    }

    private var separator: some View { Rectangle().fill(Chrome.border).frame(height: 1) }

    private var policyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("On new hosts")
                Spacer(minLength: 0)
                Picker("On new hosts", selection: policy) {
                    ForEach(NewHostPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().fixedSize()
                    .accessibilityIdentifier("settings-new-host-policy")
            }
            Text(policyDetail(policy.wrappedValue))
                .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                .fixedSize(horizontal: false, vertical: true)
            // Where an uploaded helper lives, whichever policy put it there (SSHBootstrap, docs/security.md).
            Text("Helper location on hosts: ~/.dispatch/bin/versions/<hash>/dispatch-helper")
                .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var clipboardRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Remote programs can copy")
                Spacer(minLength: 0)
                Toggle("Remote programs can copy", isOn: clipboard).labelsHidden()
                    .toggleStyle(SettingsSwitchStyle(title: "Remote programs can copy", compact: true))
                    .accessibilityIdentifier("settings-remote-clipboard")
            }
            Text("Programs on helper hosts can set this Mac’s clipboard.")
                .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 14).padding(.vertical, 10)
            .help("As with OSC 52 or tmux buffers. Local programs and plain SSH always can.")
    }

    private var reconnectRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Reconnect automatically")
                Spacer(minLength: 0)
                Toggle("Reconnect automatically", isOn: reconnect).labelsHidden()
                    .toggleStyle(SettingsSwitchStyle(title: "Reconnect automatically", compact: true))
                    .accessibilityIdentifier("settings-ssh-auto-reconnect")
            }
            Text("Logs back in with your keys or SSH agent when a connection drops.")
                .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 14).padding(.vertical, 10)
            .help("For connections with the helper, retrying after sleep or a network change. Hosts that ask for a password, connections you disconnect, and hosts reopened at launch wait for Reconnect.")
    }

    private var colorsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Host colors")
                Spacer(minLength: 0)
                Toggle("Host colors", isOn: colors).labelsHidden()
                    .toggleStyle(SettingsSwitchStyle(title: "Host colors", compact: true))
                    .accessibilityIdentifier("settings-host-colors")
            }
            Text("Tints remote tabs, borders and sidebar items in each host’s color. Off, they’re marked in gray.")
                .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func policyDetail(_ policy: NewHostPolicy) -> String {
        switch policy {
        case .ask: "Ask which helper features to allow on each new host."
        case .full: "Installs the helper without asking. It can see processes, files you can read, agent transcripts and Git."
        case .plain: "Plain SSH: no stats, files or remote chat."
        }
    }

    private func address(_ entry: SSHIntegrationPermissions.Entry) -> String {
        let destination = entry.scope.destination.replacingOccurrences(of: "ssh://", with: "")
        return entry.scope.account + "@" + (destination.split(separator: "@").last.map(String.init) ?? destination)
    }

    // MARK: Rows

    /// A host, or a login not yet matched to one: its name and status, then
    /// one line per login with the permissions its helper has.
    private func row(id: String, host: HostRecord?, logins: [Entry]) -> some View {
        let open = expanded == id
        let title = host?.name ?? logins.first.map(address) ?? id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(InterfaceMotion.animation(reduce: reduceMotion)) { expanded = open ? nil : id; forgetting = nil }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Group {
                            if let host {
                                HostGlyph(host: host, size: typography.hostIconSize).foregroundStyle(host.tint?.foreground ?? Chrome.ink)
                            } else {
                                Image(systemName: "key").font(AppFont.ui(size: 10)).foregroundStyle(SettingsControlStyle.detail)
                            }
                        }.frame(width: typography.hostIconSize)
                        Text(title).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                        status(host)
                        Image(systemName: "chevron.right").font(AppFont.ui(size: 9, weight: .semibold))
                            .foregroundStyle(SettingsControlStyle.detail).rotationEffect(.degrees(open ? 90 : 0))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(logins) { entry in
                            HStack(spacing: 10) {
                                if host != nil {
                                    Text(address(entry)).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help("\(address(entry))\nSSH executable: \(entry.scope.executable)\nSaved configuration: \(entry.scope.configurationFingerprint)")
                                }
                                chips(currentDraft(for: entry))
                            }
                        }
                        if logins.isEmpty, let destination = host?.destinations.first {
                            Text(destination.replacingOccurrences(of: "ssh://", with: ""))
                                .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }.padding(.leading, 23)
                }.padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows the helper permissions for \(title)")
                .accessibilityIdentifier("settings-host-\(id)")
            if open { editor(id: id, host: host, logins: logins) }
        }
    }

    @ViewBuilder private func status(_ host: HostRecord?) -> some View {
        if let host {
            let state = workspace.hosts.state(host.id)
            if state == .connected {
                HStack(spacing: 5) {
                    Circle().frame(width: 6, height: 6)
                    Text("connected")
                }.font(typography.font(offset: -1.5)).foregroundStyle(Chrome.palette.green).fixedSize()
            } else {
                Text(state == .disconnected ? "offline" : state.label)
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail).fixedSize()
            }
        } else {
            Text("not seen yet").font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail).fixedSize()
                .help("This SSH configuration hasn’t connected since Dispatch launched")
        }
    }

    /// Solid chips for what the helper may do, struck-through ones for what it may not.
    private func chips(_ draft: SSHIntegrationDraft) -> some View {
        let allowed = SSHIntegrationDraft.Choice.all.filter { draft.checked.contains($0) }.map(\.title)
        let withheld = SSHIntegrationDraft.Choice.all.filter { !draft.checked.contains($0) }.map(\.title)
        return HStack(spacing: 4) {
            if draft.helper {
                ForEach(SSHIntegrationDraft.Choice.all, id: \.self) { choice in
                    chip(Self.chipTitle(choice), on: draft.checked.contains(choice))
                }
            } else {
                Text("plain ssh").font(typography.font(offset: -2)).foregroundStyle(SettingsControlStyle.detail)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(SettingsControlStyle.border) }
            }
        }.fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(!draft.helper ? "Plain SSH, no helper" :
                ["Allowed: " + allowed.joined(separator: ", "), "Not allowed: " + withheld.joined(separator: ", ")]
                    .filter { !$0.hasSuffix(": ") }.joined(separator: ". "))
    }

    private func chip(_ title: String, on: Bool) -> some View {
        Text(title).font(typography.font(offset: -2))
            .strikethrough(!on, color: SettingsControlStyle.detail.opacity(0.6))
            .foregroundStyle(on ? Chrome.ink : SettingsControlStyle.detail)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(on ? Chrome.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .opacity(on ? 1 : 0.75)
    }

    private static func chipTitle(_ choice: SSHIntegrationDraft.Choice) -> String {
        switch choice {
        case .stats: "stats"
        case .files: "files"
        case .agent(let agent): agent.rawValue
        }
    }

    // MARK: Editor

    private func editor(id: String, host: HostRecord?, logins: [Entry]) -> some View {
        let entry = logins.first { $0.id == account[id] } ?? logins.first
        return VStack(alignment: .leading, spacing: 10) {
            if logins.count > 1 { accountPicker(id: id, logins: logins, selected: entry?.id) }
            if let entry {
                let draft = currentDraft(for: entry)
                options(entry, draft)
                reconnectNotice(entry, draft)
                Text("Removals apply now; additions on the next connection.")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Follows “On new hosts” on the next connection.")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                if let entry {
                    actionLink("Use defaults", identifier: "settings-host-defaults-\(entry.id)", disabled: currentDraft(for: entry).isDefault) {
                        update(entry) { $0.useDefaults() }
                    }.help("Allow every helper feature")
                }
                Spacer(minLength: 0)
                forgetControl(id: id, host: host, entry: entry)
            }
        }.padding(.leading, 37).padding(.trailing, 14).padding(.bottom, 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-host-editor-\(id)")
    }

    private func accountPicker(id: String, logins: [Entry], selected: String?) -> some View {
        HStack(spacing: 2) {
            ForEach(logins) { entry in
                let on = entry.id == selected
                Button { account[id] = entry.id } label: {
                    Text(address(entry)).font(typography.font(offset: -1.5)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(on ? Chrome.ink : SettingsControlStyle.detail)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(on ? SettingsControlStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("settings-host-login-\(entry.id)")
            }
        }.padding(2)
            .background(SettingsControlStyle.fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsControlStyle.border) }
    }

    private func options(_ entry: Entry, _ draft: SSHIntegrationDraft) -> some View {
        VStack(spacing: 0) {
            option("Dispatch helper", detail: "includes chat, tmux and herdr · off means plain SSH") {
                switchControl("Dispatch helper", isOn: draft.helper, identifier: "settings-helper-\(entry.id)") {
                    update(entry) { $0.toggleHelper() }
                }
            }.help("Cached on the host in ~/.dispatch")
            Group {
                separator
                ForEach([SSHIntegrationDraft.Choice.stats, .files], id: \.self) { choice in
                    option(choice.title, detail: choice.detail, indented: true) {
                        switchControl(choice.title, isOn: draft.checked.contains(choice),
                                      identifier: "settings-feature-\(Self.chipTitle(choice))-\(entry.id)") {
                            update(entry) { $0.toggle(choice) }
                        }
                    }
                    separator
                }
                option("Agent hooks", detail: "chat hooks · attention", indented: true) {
                    HStack(spacing: 4) {
                        ForEach(SSHHookAgent.allCases, id: \.self) { agent in
                            agentToggle(.agent(agent), on: draft.checked.contains(.agent(agent)), entry: entry)
                        }
                    }
                }
            }.disabled(!draft.helper).opacity(draft.helper ? 1 : 0.4)
        }.background(Chrome.window, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsControlStyle.border) }
    }

    private func option<Control: View>(_ title: String, detail: String, indented: Bool = false,
                                       @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            control()
        }.padding(.leading, indented ? 26 : 12).padding(.trailing, 12).padding(.vertical, 8)
    }

    private func switchControl(_ title: String, isOn: Bool, identifier: String, toggle: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { _ in toggle() })).labelsHidden()
            .toggleStyle(SettingsSwitchStyle(title: title, compact: true))
            .accessibilityIdentifier(identifier)
    }

    private func agentToggle(_ choice: SSHIntegrationDraft.Choice, on: Bool, entry: Entry) -> some View {
        Button { update(entry) { $0.toggle(choice) } } label: {
            Text(choice.title).font(typography.font(offset: -1.5))
                .foregroundStyle(on ? Chrome.ink : SettingsControlStyle.detail)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(on ? Chrome.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(on ? Chrome.accent.opacity(0.45) : SettingsControlStyle.border)
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(choice.title) Chat hooks")
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityIdentifier("settings-feature-\(Self.chipTitle(choice))-\(entry.id)")
            .help("Install \(choice.title) Chat hooks in this account’s configuration when it starts")
    }

    /// Additions reach a live helper only after reconnecting; say which, and offer it.
    @ViewBuilder private func reconnectNotice(_ entry: Entry, _ draft: SSHIntegrationDraft) -> some View {
        let state = TerminalRuntime.shared.ssh.integrationConnectionState(entry.scope)
        if draft.needsReconnect(state.grants) {
            let ready = state.requirements.isSubset(of: draft.features)
            HStack(spacing: 10) {
                Text(Self.pendingAdditions(draft, live: state.grants))
                    .font(typography.font(offset: -1.5)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { TerminalRuntime.shared.ssh.reconnectIntegration(entry.scope) } label: {
                    Text("Reconnect").font(typography.font(offset: -1.5)).foregroundStyle(Chrome.window)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Chrome.accent, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).disabled(!ready).opacity(ready ? 1 : 0.4)
                    .help(ready ? "Reconnect this login’s SSH sessions with the new permissions"
                        : "Reconnecting existing native sessions requires their helper features.")
                    .accessibilityIdentifier("settings-host-reconnect-\(entry.id)")
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .background(Chrome.palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private static func pendingAdditions(_ draft: SSHIntegrationDraft, live: [SSHIntegrationGrant]) -> String {
        if live.contains(where: { $0.profile == .ordinary }) { return "The helper starts after reconnecting." }
        let missing = draft.features.filter { feature in live.contains { !$0.selectedFeatures.contains(feature) } }
        // Git metadata arrives with file access; name it once.
        let names = SSHIntegrationFeature.allCases.filter { missing.contains($0) && !($0 == .git && missing.contains(.files)) }.map(\.title)
        return names.isEmpty ? "These changes start after reconnecting."
            : "\(names.formatted(.list(type: .and))) start\(names.count == 1 ? "s" : "") after reconnecting."
    }

    @ViewBuilder private func forgetControl(id: String, host: HostRecord?, entry: Entry?) -> some View {
        if let host {
            if forgetting == id {
                HStack(spacing: 10) {
                    Text("Forget \(host.name)? Its tabs, helper choices and caches are removed; remote tmux, herdr and programs keep running.")
                        .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                        .fixedSize(horizontal: false, vertical: true)
                    actionLink("Cancel", identifier: "settings-reset-host-cancel-\(id)") { forgetting = nil }
                    Button("Forget") {
                        TerminalRuntime.shared.hosts.reset(host.id)
                        forgetting = nil; expanded = nil
                    }.buttonStyle(.plain).font(typography.font(offset: -1, weight: .semibold)).foregroundStyle(.red)
                        .accessibilityIdentifier("settings-reset-host-confirm-\(id)")
                }
            } else {
                actionLink("Forget host…", identifier: "settings-reset-host-\(id)", destructive: true,
                           disabled: !TerminalRuntime.shared.hosts.canReset(host.id)) { forgetting = id }
                    .help("Disconnect and remove this host’s saved tabs, helper choices and caches")
            }
        } else if let entry {
            actionLink("Forget choice", identifier: "settings-reset-host-integration-\(entry.id)", destructive: true) {
                permissions.reset(entry.scope); expanded = nil
            }.help("The next connection asks again")
        }
    }

    private func actionLink(_ title: String, identifier: String, destructive: Bool = false, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain)
            .font(typography.font(offset: -1.5))
            .foregroundStyle(disabled ? SettingsControlStyle.detail.opacity(0.6) : destructive ? Color.red : Chrome.accent)
            .disabled(disabled).accessibilityIdentifier(identifier)
    }

    // MARK: Saving

    private func currentDraft(for entry: Entry) -> SSHIntegrationDraft {
        if let draft = drafts[entry.id], draft.grant == entry.grant { return draft }
        return SSHIntegrationDraft(current: entry.grant, agents: permissions.agentHooks(entry.scope))
    }

    /// Every change saves at once: reductions reach live helpers immediately,
    /// additions wait for a reconnect.
    private func update(_ entry: Entry, _ change: (inout SSHIntegrationDraft) -> Void) {
        var value = currentDraft(for: entry)
        change(&value)
        drafts[entry.id] = value
        permissions.save(value.selection, for: entry.scope)
    }
}
