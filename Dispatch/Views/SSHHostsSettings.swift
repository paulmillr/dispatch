import Dictation
import SwiftUI

/// Hosts: this Mac's agent hooks and each known remote machine, with one line per
/// login showing what its helper may do. A login
/// is keyed by account and SSH configuration, so one machine can have several;
/// logins not yet matched to a machine this launch are listed at the end. Clicking
/// a row edits its choices in place.
struct SSHHostsSettings: View {
    typealias Entry = SSHIntegrationPermissions.Entry
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let workspace: Workspace
    let permissions: SSHIntegrationPermissions
    var resetting = false
    var forgetAll: () -> Void = {}
    var logins: (HostID) -> [String] = { host in TerminalRuntime.shared.ssh.integrationEntries(for: host).map(\.id) }
    @State private var expanded: String?
    @State private var forgetting: String?
    /// A "Remove Dispatch" waiting for confirmation: which row, where it runs, and its dry run once known.
    private struct Removal {
        let id: String
        let machine: TerminalMachine?
        var preview: DispatchRemoval.Outcome?
        var data = true
    }
    @State private var removal: Removal?
    /// This Mac's agent whose hooks wait for the Install confirmation.
    @State private var installing: HelperClient.Launch?
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
        hostList(grouped: grouped, other: other)
    }

    private func hostList(grouped: [(HostRecord, [Entry])], other: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Hosts").fontWeight(.semibold).foregroundStyle(SettingsControlStyle.selectedText)
                Spacer(minLength: 0)
                // Always offered: it also clears a stale saved session with nothing listed.
                Button(resetting ? "Resetting…" : "Reset all…", action: forgetAll)
                    .buttonStyle(.plain).font(typography, .body).foregroundStyle(SettingsControlStyle.detail)
                    .disabled(resetting)
                    .accessibilityIdentifier("settings-reset-all-host-integrations")
                    .help("Disconnect SSH and forget every host’s saved tabs, helper choices and caches. Global preferences are kept.")
            }.padding(.horizontal, 14).padding(.vertical, 11)
            separator
            localRow
            if !grouped.isEmpty || !other.isEmpty { separator }
            ForEach(grouped, id: \.0.id) { host, logins in
                row(id: host.id.rawValue, host: host, logins: logins)
                if host.id != grouped.last?.0.id { separator.padding(.horizontal, 14) }
            }
            if !other.isEmpty {
                if !grouped.isEmpty { separator }
                Text("Other logins").font(typography, .caption).fontWeight(.semibold).foregroundStyle(SettingsControlStyle.detail)
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
            // A row another place asked for (SettingsNavigation): This Mac from Features, a host from its stats.
            .onChange(of: SettingsNavigation.shared.host, initial: true) { _, host in
                guard let host else { return }
                expanded = host; forgetting = nil
                SettingsNavigation.shared.host = nil
            }
    }

    private var separator: some View { Rectangle().fill(Chrome.border).frame(height: 1) }

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
                                    Text(address(entry)).font(typography, .body).foregroundStyle(SettingsControlStyle.detail)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help("\(address(entry))\nSSH executable: \(entry.scope.executable)\nSaved configuration: \(entry.scope.configurationFingerprint)")
                                }
                                if permissions.unsupported(entry.scope) {
                                    Text("helper not supported here").font(typography, .caption).foregroundStyle(SettingsControlStyle.detail)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(SettingsControlStyle.border) }
                                        .help("This host’s platform has no Dispatch helper: it connects with plain SSH")
                                } else {
                                    chips(currentDraft(for: entry))
                                }
                            }
                        }
                        if logins.isEmpty, let destination = host?.destinations.first {
                            Text(destination.replacingOccurrences(of: "ssh://", with: ""))
                                .font(typography, .body).foregroundStyle(SettingsControlStyle.detail)
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
                    Text(state.shownLabel)
                }.font(typography, .body).foregroundStyle(Chrome.palette.green).fixedSize()
            } else {
                Text(SidebarThemeStore.shared.current == .nautical ? state.portLabel : state == .disconnected ? "offline" : state.label)
                    .font(typography, .body).foregroundStyle(SettingsControlStyle.detail).fixedSize()
            }
        } else {
            Text("not connected yet").font(typography, .body).foregroundStyle(SettingsControlStyle.detail).fixedSize()
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
                    chip(Self.chipLabel(choice), on: draft.checked.contains(choice))
                }
            } else {
                Text("Plain SSH").font(typography, .caption).foregroundStyle(SettingsControlStyle.detail)
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
        Text(title).font(typography, .caption)
            .strikethrough(!on, color: SettingsControlStyle.detail.opacity(0.6))
            .foregroundStyle(on ? Chrome.ink : SettingsControlStyle.detail)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(on ? Chrome.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .opacity(on ? 1 : 0.75)
    }

    /// A chip's words: the choice's title, Copy files in shortened.
    private static func chipLabel(_ choice: SSHIntegrationDraft.Choice) -> String {
        choice == .filesWrite ? "Copy in" : choice.title
    }

    /// A choice in accessibility identifiers.
    private static func chipTitle(_ choice: SSHIntegrationDraft.Choice) -> String {
        switch choice {
        case .stats: "stats"
        case .files: "files"
        case .filesWrite: "copy-in"
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
                if permissions.unsupported(entry.scope) {
                    Text("The Dispatch helper doesn’t run on this host’s platform (it needs Linux on x86-64 or ARM64, or macOS on Apple silicon), so it connects with plain SSH. Change a choice below to try the helper again.")
                        .font(typography, .body).foregroundStyle(Chrome.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-host-unsupported-\(entry.id)")
                }
                options(entry, draft)
                reconnectNotice(entry, draft)
                Text("Removals apply now; additions on the next connection. Agent hooks turned off stop reaching Dispatch at once, but their entries stay in that account’s agent configuration until you remove Dispatch from the host.")
                    .font(typography, .body).foregroundStyle(SettingsControlStyle.detail)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The next connection asks which helper features to allow, or allows them all with Auto-confirm uploads (Features › Remote helper).")
                    .font(typography, .body).foregroundStyle(SettingsControlStyle.detail)
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
                    Text(address(entry)).font(typography, .body).lineLimit(1).truncationMode(.middle)
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
                ForEach([SSHIntegrationDraft.Choice.stats, .files, .filesWrite], id: \.self) { choice in
                    // Copy files in sits under Files and needs it.
                    let nested = choice == .filesWrite
                    option(choice.title, detail: choice.detail, indented: true, nested: nested) {
                        switchControl(choice.title, isOn: draft.checked.contains(choice),
                                      identifier: "settings-feature-\(Self.chipTitle(choice))-\(entry.id)") {
                            update(entry) { $0.toggle(choice) }
                        }
                    }
                    .opacity(nested && !draft.checked.contains(.files) ? 0.5 : 1)
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

    private func option<Control: View>(_ title: String, detail: String, indented: Bool = false, nested: Bool = false,
                                       @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(typography, .body).foregroundStyle(SettingsControlStyle.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            control()
        }.padding(.leading, nested ? 40 : indented ? 26 : 12).padding(.trailing, 12).padding(.vertical, 8)
    }

    private func switchControl(_ title: String, isOn: Bool, identifier: String, toggle: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { _ in toggle() })).labelsHidden()
            .toggleStyle(SettingsSwitchStyle(title: title, compact: true))
            .accessibilityIdentifier(identifier)
    }

    private func agentToggle(_ choice: SSHIntegrationDraft.Choice, on: Bool, entry: Entry) -> some View {
        toggleChip(choice.title, on: on, identifier: "settings-feature-\(Self.chipTitle(choice))-\(entry.id)") {
            update(entry) { $0.toggle(choice) }
        }
    }

    private func toggleChip(_ title: String, on: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(typography, .body)
                .foregroundStyle(on ? Chrome.ink : SettingsControlStyle.detail)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(on ? Chrome.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(on ? Chrome.accent.opacity(0.45) : SettingsControlStyle.border)
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(title) Chat hooks")
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityIdentifier(identifier)
            .help("Install \(title) Chat hooks in this account’s configuration when it starts")
    }

    /// Additions reach a live helper only after reconnecting; say which, and offer it.
    @ViewBuilder private func reconnectNotice(_ entry: Entry, _ draft: SSHIntegrationDraft) -> some View {
        let state = TerminalRuntime.shared.ssh.integrationConnectionState(entry.scope)
        if draft.needsReconnect(state.grants) {
            let ready = state.requirements.isSubset(of: draft.features)
            HStack(spacing: 10) {
                Text(Self.pendingAdditions(draft, live: state.grants))
                    .font(typography, .body).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { TerminalRuntime.shared.ssh.reconnectIntegration(entry.scope) } label: {
                    Text("Reconnect").font(typography, .body).foregroundStyle(Chrome.window)
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
            if removal?.id == id {
                removalConfirmation(host.name, local: false) {
                    let machine = removal?.machine
                    TerminalRuntime.shared.hosts.reset(host.id)
                    removal = nil; expanded = nil
                    guard let machine else { return }
                    Task { DispatchRemoval.report(await DispatchRemoval.run(on: machine, dry: false, attempts: 10), host: host.name) }
                }
            } else if forgetting == id {
                HStack(spacing: 10) {
                    Text("Forget \(host.name)? Its tabs, helper choices and caches are removed; remote tmux, herdr and programs keep running.")
                        .font(typography, .body).foregroundStyle(SettingsControlStyle.detail)
                        .fixedSize(horizontal: false, vertical: true)
                    actionLink("Cancel", identifier: "settings-reset-host-cancel-\(id)") { forgetting = nil }
                    Button("Forget") {
                        TerminalRuntime.shared.hosts.reset(host.id)
                        forgetting = nil; expanded = nil
                    }.buttonStyle(.plain).font(typography, .label, weight: .semibold).foregroundStyle(.red)
                        .accessibilityIdentifier("settings-reset-host-confirm-\(id)")
                }
            } else {
                HStack(spacing: 14) {
                    actionLink("Forget host…", identifier: "settings-reset-host-\(id)", destructive: true,
                               disabled: !TerminalRuntime.shared.hosts.canReset(host.id)) { forgetting = id }
                        .help("Disconnect and remove this host’s saved tabs, helper choices and caches")
                    actionLink("Remove Dispatch…", identifier: "settings-remove-host-\(id)", destructive: true,
                               disabled: !TerminalRuntime.shared.hosts.canReset(host.id)) {
                        let machine = workspace.newSpaceMachine(on: host.id)
                            ?? host.destinations.first.map { .ssh(SSHShell(destination: $0)) }
                        preview(Removal(id: id, machine: machine))
                    }.help("Forget this host, then remove Dispatch’s hooks, Pi extension and helper files from it")
                }
            }
        } else if let entry {
            actionLink("Forget choice", identifier: "settings-reset-host-integration-\(entry.id)", destructive: true) {
                permissions.reset(entry.scope); expanded = nil
            }.help("The next connection asks again")
        }
    }

    /// Starts a removal's confirmation and fills in its dry run.
    private func preview(_ value: Removal) {
        forgetting = nil; removal = value
        guard let machine = value.machine else { return }
        Task {
            let outcome = await DispatchRemoval.run(on: machine, dry: true)
            if removal?.id == value.id { removal?.preview = outcome }
        }
    }

    /// What a removal changes (its dry run) before it is confirmed. This Mac's quits Dispatch and can take its data.
    private func removalConfirmation(_ name: String, local: Bool, remove: @escaping () -> Void) -> some View {
        let small = typography.font(.body)
        return VStack(alignment: .leading, spacing: 8) {
            Text(local ? "Remove Dispatch from this Mac? Dispatch quits, then removes:"
                 : "Remove Dispatch from \(name)? This disconnects and forgets the host, then removes there:")
                .font(small).foregroundStyle(SettingsControlStyle.detail).fixedSize(horizontal: false, vertical: true)
            Group {
                if removal?.machine == nil {
                    Text("No way to reach \(name) is known. Run \(DispatchRemoval.command) there yourself.")
                } else if let preview = removal?.preview {
                    if preview.absent { Text("Nothing: Dispatch isn’t installed there.") }
                    else if preview.cannotRun { Text(DispatchRemoval.cannotRunAdvice) }
                    else if preview.removed { Text(preview.output.isEmpty ? "Nothing to remove." : preview.output) }
                    else {
                        Text("Couldn’t check (\(preview.output.isEmpty ? "status \(preview.status)" : preview.output)). "
                             + "Removing still \(local ? "quits" : "forgets the host"); if it fails, run \(DispatchRemoval.command) there.")
                    }
                } else { Text("Checking…") }
            }.font(typography, .body).foregroundStyle(Chrome.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-removal-preview")
            Text("Codex may ask you to trust your own hooks again in /hooks.")
                .font(small).foregroundStyle(SettingsControlStyle.detail)
            if local {
                // Everything in its support folder goes, the dictation models too, which can be large: named with sizes.
                let models = DictationModel.all.filter { DictationModelStore.shared.state($0) == .installed }
                    .map { "\($0.name) (\($0.sizeLabel))" }
                Toggle("Also delete Dispatch’s data: settings, saved spaces and terminal output, drafts, reviews and saved hosts"
                       + (models.isEmpty ? "" : ", and the dictation models: " + models.formatted(.list(type: .and))),
                       isOn: Binding(get: { removal?.data ?? true }, set: { removal?.data = $0 }))
                    .toggleStyle(.checkbox).font(small).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-removal-data")
                Text("Your color schemes in ~/.config/dispatch/themes are kept, as Reset keeps them.")
                    .font(small).foregroundStyle(SettingsControlStyle.detail)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                actionLink("Cancel", identifier: "settings-removal-cancel") { removal = nil }
                Button(local ? "Remove & Quit" : "Remove", action: remove).buttonStyle(.plain)
                    .font(typography, .label, weight: .semibold).foregroundStyle(.red)
                    .accessibilityIdentifier("settings-removal-confirm")
            }
        }
    }

    private func actionLink(_ title: String, identifier: String, destructive: Bool = false, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain)
            .font(typography, .body)
            .foregroundStyle(disabled ? SettingsControlStyle.detail.opacity(0.6) : destructive ? Color.red : Chrome.accent)
            .disabled(disabled).accessibilityIdentifier(identifier)
    }

    // MARK: This Mac

    /// This Mac's agent hooks: which agents' hooks it installs, and how each stands. Only this Mac reports its
    /// hooks' state; an SSH host shows what it allows.
    private var localRow: some View {
        let open = expanded == Self.localID
        let launches = TerminalRuntime.shared.chat.listedLaunches
        let local = workspace.hosts.record(.local)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(InterfaceMotion.animation(reduce: reduceMotion)) { expanded = open ? nil : Self.localID; forgetting = nil }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        HostGlyph(host: local, size: typography.hostIconSize).foregroundStyle(Chrome.ink)
                            .frame(width: typography.hostIconSize)
                        Text("This Mac").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                        Text("local").font(typography, .body).foregroundStyle(SettingsControlStyle.detail).fixedSize()
                        Image(systemName: "chevron.right").font(AppFont.ui(size: 9, weight: .semibold))
                            .foregroundStyle(SettingsControlStyle.detail).rotationEffect(.degrees(open ? 90 : 0))
                    }
                    localSummary(launches).font(typography, .body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 23)
                }.padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("This Mac")
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows the agent hooks for this Mac")
                .accessibilityIdentifier("settings-host-\(Self.localID)")
            if open { localEditor(launches) }
        }
    }

    private func localEditor(_ launches: [HelperClient.Launch]) -> some View {
        let chat = TerminalRuntime.shared.chat
        return VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(launches, id: \.key) { launch in
                    if launch.key != launches.first?.key { separator }
                    localAgentRow(launch)
                }
            }.background(Chrome.window, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsControlStyle.border) }
            Text("Install adds Dispatch’s hooks to that agent’s own configuration on this Mac, after asking. Remove takes Claude Code’s out of its settings and deletes Pi’s extension; Codex’s entries stay in hooks.json, unused, so its /hooks trust is kept. Features › Chat mode turns an agent off everywhere.")
                .font(typography, .body).foregroundStyle(SettingsControlStyle.detail)
                .fixedSize(horizontal: false, vertical: true)
            if removal?.id == Self.localID {
                removalConfirmation("this Mac", local: true) {
                    let data = removal?.data ?? true
                    // Nothing may install them again while Dispatch quits.
                    for launch in launches { chat.setLocalHooks(launch.key, allowed: false) }
                    (NSApp.delegate as? AppDelegate)?.removalOnQuit = data
                    removal = nil
                    NSApp.terminate(nil)
                }
            } else {
                actionLink("Remove Dispatch from this Mac…", identifier: "settings-remove-local", destructive: true) {
                    preview(Removal(id: Self.localID, machine: .local))
                }.help("Quit Dispatch, then remove its hooks, Pi extension and helper files from this Mac")
            }
        }.padding(.leading, 37).padding(.trailing, 14).padding(.bottom, 12)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-host-editor-\(Self.localID)")
            // Asked each time it opens, so a CLI installed meanwhile gets its Install; a shell that cannot be asked
            // keeps the last answer, or offers Install for every agent.
            .task {
                let found = await LocalAgentsConsent.installedAgents()
                chat.localCLIs = found ?? chat.localCLIs ?? Set(launches.map(\.key))
            }
            .alert(installing.map { "Install \($0.label) hooks on this Mac?" } ?? "",
                   isPresented: Binding(get: { installing != nil }, set: { if !$0 { installing = nil } })) {
                Button("Cancel", role: .cancel) {}
                Button("Install") { if let installing { chat.setLocalHooks(installing.key, allowed: true) } }
                    .keyboardShortcut(.defaultAction)
            } message: {
                Text(installing.map { LocalAgentHooks.installMessage($0.key, label: $0.label) } ?? "")
            }
    }

    /// One agent on one line: its name, how its hooks stand here, and the one action that changes that: Install (asking
    /// first, naming the file), Try Again after a failure, or Remove; the CLI's own install command when this Mac lacks
    /// it, and a spinner while the login shell is asked. An agent off in Chat mode is off everywhere: nothing to do here.
    private func localAgentRow(_ launch: HelperClient.Launch) -> some View {
        let chat = TerminalRuntime.shared.chat
        let inChat = chat.enabled && !chat.disabledIntegrations.contains(launch.key)
        let installed = chat.localHooksAllowed(launch.key) && chat.hookStatus(launch.key) != .off
        let command = inChat && !installed && missingCLI(launch.key) ? LocalAgentsConsent.installs[launch.key] : nil
        let failure = chat.localHooksAllowed(launch.key) ? chat.localInstallationFailure(launch.key) : nil
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(launch.label).fixedSize()
            Group {
                if let command {
                    Text(command).font(typography.code(.body)).foregroundStyle(Chrome.ink)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help("\(launch.label) is not installed on this Mac: run this in a terminal")
                        .accessibilityIdentifier("settings-install-command-\(launch.key)")
                } else if let failure {
                    Text(failure).font(typography, .body).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-install-failure-\(launch.key)")
                } else {
                    Text(localStatus(launch)).font(typography, .body).foregroundStyle(SettingsControlStyle.detail)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-local-status-\(launch.key)")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if inChat {
                if installed {
                    Button("Remove") { chat.setLocalHooks(launch.key, allowed: false) }
                        .accessibilityIdentifier("settings-remove-hooks-\(launch.key)")
                        .help(launch.key == "codex" ? "Stop using \(launch.label)’s hooks on this Mac; its entries stay in hooks.json"
                              : "Take Dispatch’s hooks out of \(launch.label)’s configuration on this Mac")
                } else if chat.localCLIs == nil {
                    // The login shell is being asked which CLIs it runs (up to 30 s).
                    ProgressView().controlSize(.small)
                        .help("Looking for \(launch.label) in your login shell")
                        .accessibilityLabel("Looking for \(launch.label)")
                } else if command == nil {
                    Button(failure == nil ? "Install…" : "Try Again") {
                        if chat.localHooksAllowed(launch.key) { chat.setLocalHooks(launch.key, allowed: true) } else { installing = launch }
                    }.accessibilityIdentifier("settings-install-\(launch.key)")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .opacity(inChat ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-local-agent-\(launch.key)")
    }

    /// The closed row's line: how many agents are ready, which need a step, and which are off here.
    private func localSummary(_ launches: [HelperClient.Launch]) -> Text {
        let chat = TerminalRuntime.shared.chat
        guard chat.enabled else { return Text("Chat mode is off").foregroundColor(SettingsControlStyle.detail) }
        let inChat = launches.filter { !chat.disabledIntegrations.contains($0.key) }
        let on = inChat.filter { chat.localHooksAllowed($0.key) }
        let ready = on.filter { chat.hookStatus($0.key) == .ready }
        let missing = on.filter { chat.hookStatus($0.key) != .ready && missingCLI($0.key) }.map(\.label)
        let pending = on.filter { chat.hookStatus($0.key) != .ready && !missingCLI($0.key) }.map(\.label)
        let unset = inChat.filter { chat.localHooks[$0.key] == nil }.map(\.label)
        let off = launches.filter { chat.disabledIntegrations.contains($0.key) || chat.localHooks[$0.key] == false }.map(\.label)
        var parts: [String] = []
        if !ready.isEmpty { parts.append("\(ready.count) ready") }
        if !pending.isEmpty { parts.append(pending.joined(separator: ", ") + (pending.count == 1 ? " needs setup" : " need setup")) }
        if !missing.isEmpty { parts.append(missing.joined(separator: ", ") + " not installed") }
        if !unset.isEmpty { parts.append(unset.joined(separator: ", ") + " not set up") }
        if !off.isEmpty { parts.append(off.joined(separator: ", ") + " off") }
        return Text(parts.joined(separator: " · ")).foregroundColor(SettingsControlStyle.detail)
    }

    static let localID = "local"

    /// The probe found no CLI for this agent; unknown until This Mac opens.
    private func missingCLI(_ key: String) -> Bool {
        TerminalRuntime.shared.chat.localCLIs.map { !$0.contains(key) } ?? false
    }

    /// How an agent's hooks stand on this Mac, from the local helper's installation facts.
    private func localStatus(_ launch: HelperClient.Launch) -> String {
        let chat = TerminalRuntime.shared.chat, install = chat.helperInstalls[launch.key]
        if !chat.enabled || chat.disabledIntegrations.contains(launch.key) { return "off in Features › Chat mode" }
        if chat.localHooks[launch.key] == false { return "off on this Mac" }
        if !chat.localHooksAllowed(launch.key) { return missingCLI(launch.key) ? "not installed" : "not set up" }
        return Self.status(chat.hookStatus(launch.key), install: install, label: launch.label, missing: missingCLI(launch.key))
    }

    /// An allowed agent's hooks here, worded for its row (and Features' agent rows): ready, the step that finishes
    /// them, or why they aren't installed.
    static func status(_ status: ChatCoordinator.AgentHookStatus, install: HelperChat.Installation?, label: String, missing: Bool) -> String {
        switch status {
        case .ready: return "✓ ready"
        case .restart:
            if let trust = install?.trust { return "restart \(label), then trust Dispatch in \(trust)" }
            if let reload = install?.reload { return "run \(reload) in \(label) to finish" }
            return "restart \(label) to finish"
        case .off:
            if missing { return "not installed" }
            return install?.optional == true ? "needs its extension" : "not set up"
        }
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
