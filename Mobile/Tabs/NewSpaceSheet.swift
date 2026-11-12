import SwiftUI

/// M7a: New space, a compact card sized to its content (the phone's sheet is as tall as the card, not the screen):
/// Name (empty: named after its folder and following it until renamed, as the Mac names new spaces; the field's
/// placeholder shows that name), the host as a pull-down (its tinted disc and up/down chevrons; the known hosts with the
/// current one ticked, then New host… which opens M8a and comes back with the new host selected), and the folder, one
/// row whose pull-down holds Home (the default), the host's recent project folders from agent history
/// (`projects.recent`, when the host's helper accepted that feature) and Other folder…, which turns the row into a
/// typed path with completions from the directories the host's open tabs are in. Create makes the space on the host's
/// multiplexer and opens it in the terminal. The host row marks the multiplexer the host shows (`MultiplexerMark`), as
/// Spaces' host header does.
///
/// Not in the mockup: Multiplexer, the host's installed ones (herdr, tmux; never the helper's native one, whose sessions
/// end with the connection) under the card when there are two, the one the host shows picked. A host shows one
/// multiplexer's spaces at a time, so another one becomes the host's on Create (its footnote says so), as Multiplexer in
/// Edit host would.
struct NewSpaceSheet: View {
    let model: MobileTabs
    /// A host's New space pre-selects it; New tab's picker passes the recent space's.
    var host: UUID?
    let hostViews: SpacesHostViews
    let created: (MobileTab) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: UUID?
    @State private var directory = "~"
    /// Other folder…: the typed path instead of home.
    @State private var other = false
    /// A recent project folder picked instead of home (its absolute path).
    @State private var recent: String?
    /// The multiplexer picked by name; nil: the one the host shows.
    @State private var multiplexer: String?
    @State private var addingHost = false
    @State private var creating = false
    @State private var failure: String?
    /// The card's height: the phone's sheet takes it (`presentationDetents`).
    @State private var height: CGFloat = 300
    @FocusState private var focus: Field?

    private enum Field { case name, directory }

    /// The host is chosen before the first frame (the one asked for while it is listed, else the first connected).
    init(model: MobileTabs, host: UUID? = nil, hostViews: SpacesHostViews, created: @escaping (MobileTab) -> Void) {
        self.model = model
        self.host = host
        self.hostViews = hostViews
        self.created = created
        _selected = State(initialValue: Self.initialHost(model.workspaces, asked: host))
    }

    static func initialHost(_ hosts: [MobileWorkspace], asked: UUID?) -> UUID? {
        asked.flatMap { id in hosts.contains { $0.id == id } ? id : nil }
            ?? (hosts.first { $0.client != nil } ?? hosts.first)?.id
    }

    /// The known hosts; a space can only be made on a connected one.
    private var hosts: [MobileWorkspace] { model.workspaces }
    private var workspace: MobileWorkspace? { hosts.first { $0.id == selected } ?? hosts.first { $0.client != nil } ?? hosts.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                VStack(spacing: 0) {
                    nameField
                    divider
                    hostPicker
                    divider
                    directoryField
                }
                .background(Self.field, in: RoundedRectangle(cornerRadius: 14))
                if let workspace, options.choices.count > 1 {
                    multiplexerPicker
                    if let note = options.note(for: chosen, host: workspace.host.name) { footnote(note) }
                }
                if let warning = chosen?.warning {
                    footnote(warning).foregroundStyle(Color.caution)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .secondarySystemBackground))
        .mobileSheetGrabber()
        .mobilePhoneDetents([.height(height)])
        .presentationBackground(Color(uiColor: .secondarySystemBackground))
        .onAppear { focus = .name }
        .task(id: workspace?.id) {
            recent = nil
            await workspace?.recentProjects()
        }
        .onChange(of: workspace?.id) { multiplexer = nil }
        .sheet(isPresented: $addingHost) {
            hostViews.newHost { id in
                addingHost = false
                if let id { selected = id }
            }
        }
        .alert("Couldn’t create the space", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var divider: some View {
        Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 54)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A card row: the leading glyph in a 28 point column, then the content.
    private func row(@ViewBuilder leading: () -> some View, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            leading().frame(width: 28)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4).frame(minHeight: 48)
    }

    /// The name; its placeholder is the name the space gets when it stays empty.
    private var nameField: some View {
        row {
            Image(systemName: "character.cursor.ibeam")
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        } content: {
            // The label names the field for VoiceOver; the placeholder is the name it gets when empty.
            TextField("Space name", text: $name, prompt: Text(automaticName ?? "Space name"))
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focus, equals: .name)
                .onSubmit { focus = nil }
                .accessibilityHint("Left empty, it’s named after its folder until you rename it.")
        }
    }

    private static let field = Color(uiColor: .tertiarySystemBackground)

    private var options: NewSpaceMultiplexers { NewSpaceMultiplexers(workspace) }
    /// Where Create makes the space.
    private var chosen: MultiplexerChoice? { options.chosen(multiplexer) }

    /// Two or more: a segmented control (the app's system controls, docs/ios.md). One needs no choice: the host row's
    /// mark names it.
    private var multiplexerPicker: some View {
        Picker("Multiplexer", selection: Binding(get: { chosen?.name ?? "" }, set: { multiplexer = $0 })) {
            ForEach(options.choices, id: \.name) { Text($0.name).tag($0.name) }
        }
        .pickerStyle(.segmented)
    }

    private var header: some View {
        ZStack {
            Text("New space").font(.headline).lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 110)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Cancel")
                Spacer()
                Button(action: create) {
                    Group {
                        if creating { ProgressView().tint(Color.onAccent) } else { Text("Create") }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6).frame(minHeight: 36)
                }
                .buttonStyle(MobileCallToAction())
                .disabled(!canCreate)
                .opacity(canCreate ? 1 : 0.5)
            }
        }
        // The sheet's bar: it grows to xxxLarge, as a navigation bar does, so Create never covers the title.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    /// An empty name is the Mac's: the server names the space after its folder (`NewSpaceName`).
    private var canCreate: Bool { !creating && workspace?.client != nil }

    /// The name the space gets when the field stays empty: the chosen folder's.
    private var automaticName: String? {
        guard let host = workspace?.host else { return nil }
        let folder = other ? directory.trimmingCharacters(in: .whitespaces) : recent ?? "~"
        return NewSpaceName.automatic(folder.isEmpty ? "~" : folder, host: host)
    }

    private var hostPicker: some View {
        Menu {
            Picker("Host", selection: Binding(get: { workspace?.id }, set: { selected = $0 })) {
                ForEach(hosts) { workspace in
                    Label {
                        Text(workspace.host.name)
                    } icon: {
                        HostGlyph(host: workspace.host.glyphRecord, size: 18).foregroundStyle(workspace.host.tint)
                    }
                    .tag(Optional(workspace.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button { addingHost = true } label: { Label { Text("New host…") } icon: { Image("NewHost") } }
        } label: {
            row {
                if let host = workspace?.host { TabsHostDisc(host: host, size: 28, glyph: 15) }
            } content: {
                HStack(spacing: 10) {
                    if let host = workspace?.host {
                        Text(host.name).font(.body).foregroundStyle(.primary).lineLimit(1)
                        if workspace?.isPlain == true {
                            // One synthetic space (Shell): New space is not for this host.
                            Text("plain SSH").font(.footnote).foregroundStyle(.tertiary)
                        } else if workspace?.client == nil {
                            Text("offline").font(.footnote).foregroundStyle(.tertiary)
                        }
                        if let multiplexer = host.multiplexer { MultiplexerMark(name: multiplexer) }
                    } else {
                        Text("No host").font(.body).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Host")
        .accessibilityValue(workspace?.host.name ?? "No host")
    }

    private var suggestions: [String] {
        guard let workspace, focus == .directory else { return [] }
        return Self.complete(directory, in: workspace)
    }

    /// The folder the space opens in, as `~`-abbreviated text.
    private var folderLabel: String {
        if let recent { return workspace?.host.abbreviate(recent) ?? recent }
        return "~"
    }

    /// One row: the folder (Home by default) with a pull-down of Home, the recent folders and Other folder…; Other
    /// folder… makes the row a typed path, its completions under it.
    @ViewBuilder private var directoryField: some View {
        if other {
            row {
                folderGlyph
            } content: {
                HStack(spacing: 8) {
                    TextField("Folder", text: $directory, prompt: Text("~/src/project"))
                        .font(.subheadline.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($focus, equals: .directory)
                        .onSubmit(create)
                    folderMenu {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 36)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Folder choices")
                }
            }
            ForEach(suggestions, id: \.self) { path in
                divider
                Button { directory = path } label: {
                    Text(path)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .fittingLine()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 54)
                        .padding(.trailing, 14)
                        .padding(.vertical, 4).frame(minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            folderMenu {
                row {
                    folderGlyph
                } content: {
                    HStack(spacing: 10) {
                        Text(folderLabel)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.primary)
                            .fittingLine()
                        Spacer(minLength: 8)
                        if recent == nil { Text("Home").font(.footnote).foregroundStyle(.tertiary) }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Folder")
            .accessibilityValue(recent == nil ? "Home" : folderLabel)
        }
    }

    private var folderGlyph: some View {
        Image(systemName: "folder")
            .font(.body)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    /// The folder's pull-down: Home, the host's recent project folders from agent history, Other folder….
    private func folderMenu(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            Button {
                other = false
                recent = nil
                directory = "~"
                focus = nil
            } label: {
                Text("Home"); Text("~")
                if !other && recent == nil { Image(systemName: "checkmark") }
            }
            if !shownRecents.isEmpty {
                Section(workspace.map { "Recent on \($0.host.name), from agent history" } ?? "Recent") {
                    ForEach(shownRecents, id: \.path) { project in
                        Button {
                            other = false
                            recent = project.path
                            focus = nil
                        } label: {
                            Text(workspace?.host.abbreviate(project.path) ?? project.path)
                            if let label = TabsTime.ago(project.time) { Text(label) }
                            if recent == project.path && !other { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Section {
                Button {
                    other = true
                    recent = nil
                    directory = ""
                    focus = .directory
                } label: {
                    Text("Other folder…")
                    if other { Image(systemName: "checkmark") }
                }
            }
        } label: {
            label()
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
    }

    /// The newest few, as the mockup shows them (Home, three or four folders, Other folder…).
    private var shownRecents: [TabsRecentProject] {
        let home = workspace?.host.home
        return Array((workspace?.recents ?? []).filter { $0.path != home }.prefix(4))
    }

    /// Typed-path completion: the directories the host's tabs are in (and their parents) that extend what was typed,
    /// shortest first, at most five.
    static func complete(_ typed: String, in workspace: MobileWorkspace) -> [String] {
        var known = Set<String>()
        for tab in workspace.tabs {
            for pane in tab.panes {
                guard var path = workspace.host.abbreviate(pane.cwd) else { continue }
                while !path.isEmpty, path != "/", path != "~" {
                    known.insert(path)
                    guard let slash = path.lastIndex(of: "/") else { break }
                    path = String(path[..<slash])
                }
            }
        }
        let query = typed.trimmingCharacters(in: .whitespaces)
        return known.filter { $0 != query && (query.isEmpty || $0.hasPrefix(query)) }
            .sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
            .prefix(5)
            .map { $0 }
    }

    private func create() {
        guard canCreate, let workspace else { return }
        creating = true
        let name = name, directory = other ? directory.trimmingCharacters(in: .whitespaces) : recent ?? "~"
        let multiplexer = chosen
        Task {
            defer { creating = false }
            do {
                let tab = try await model.createSpace(on: workspace.id, name: name, directory: directory.isEmpty ? nil : directory,
                                                      multiplexer: multiplexer)
                created(tab)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// New tab's space picker (long-press on New tab, or New with no space yet): every space on the connected hosts, then
/// New space….
struct NewTabPicker: View {
    let model: MobileTabs
    let choose: (MobileSpace) -> Void
    let newSpace: () -> Void
    /// Holding New space…: the quick menu's entry, made without the form.
    var quickSpace: ((NewSpaceDestination) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.workspaces.filter { workspace in workspace.spaces.contains(where: workspace.canAddTab(to:)) }) { workspace in
                    Section(workspace.host.name) {
                        ForEach(workspace.spaces.filter(workspace.canAddTab(to:))) { space in
                            Button { choose(space) } label: {
                                HStack(spacing: 12) {
                                    TabsHostDisc(host: workspace.host, size: 32, glyph: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(space.name).foregroundStyle(.primary)
                                        if let cwd = workspace.host.abbreviate(space.cwd) {
                                            Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }
                }
                Section {
                    let destinations = quickSpace == nil ? [] : NewSpaceDestination.all(model.workspaces)
                    Button("New space…", systemImage: "plus") { newSpace() }
                        .foregroundStyle(Color.dispatchPink)
                        .contextMenu {
                            if let quickSpace { NewSpaceQuickMenu(destinations: destinations, create: quickSpace) }
                        }
                        .accessibilityHint(destinations.isEmpty ? "" : "Hold for a space with the defaults")
                        .accessibilityActions {
                            ForEach(destinations) { destination in
                                Button(destination.spoken(host: nil)) { quickSpace?(destination) }
                            }
                        }
                }
            }
            .navigationTitle("New tab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .mobilePhoneDetents([.medium, .large])
    }
}

/// New space's Multiplexer: the host's installed multiplexers (`MobileWorkspace.multiplexers`), the one the host shows
/// (`choice`) picked until another is.
struct NewSpaceMultiplexers {
    let choices: [MultiplexerChoice]
    /// The one whose spaces the host shows.
    let shown: MultiplexerChoice?

    @MainActor init(_ workspace: MobileWorkspace?) {
        shown = workspace?.choice
        let detected = workspace?.multiplexers ?? []
        choices = detected.isEmpty ? [shown].compactMap { $0 } : detected
    }

    init(choices: [MultiplexerChoice], shown: MultiplexerChoice?) {
        self.choices = choices
        self.shown = shown
    }

    /// The picked one while the host has it, else the shown one, else the first.
    func chosen(_ name: String?) -> MultiplexerChoice? {
        name.flatMap { name in choices.first { $0.name == name } } ?? shown.flatMap { shown in choices.first { $0.name == shown.name } }
            ?? choices.first
    }

    /// The footnote when Create switches the host to another multiplexer.
    func note(for chosen: MultiplexerChoice?, host: String) -> String? {
        guard let chosen, let shown, chosen.name != shown.name else { return nil }
        return "\(host) shows one multiplexer’s spaces at a time. Create switches it from \(shown.name) to \(chosen.name), "
            + "as Multiplexer in its details does."
    }
}

/// A place the quick menu (holding New space) makes a space without the form: a connected host and one of its
/// installed multiplexers, the one the host shows first. Another one becomes the host's (`switches`), as New space's
/// footnote says.
struct NewSpaceDestination: Identifiable, Equatable {
    let host: UUID
    let hostName: String
    let multiplexer: MultiplexerChoice
    /// The host shows another multiplexer's spaces: making a space here switches it to this one.
    let switches: Bool
    var id: String { host.uuidString + ":" + multiplexer.name }

    /// Every connected host's in host order, or only `host`'s.
    @MainActor static func all(_ workspaces: [MobileWorkspace], host: UUID? = nil) -> [NewSpaceDestination] {
        workspaces.filter { $0.client != nil && (host == nil || $0.id == host) }.flatMap { workspace in
            let options = NewSpaceMultiplexers(workspace)
            let shown = options.shown?.name
            let ordered = options.choices.filter { $0.name == shown } + options.choices.filter { $0.name != shown }
            return ordered.map { choice in
                NewSpaceDestination(host: workspace.id, hostName: workspace.host.name, multiplexer: choice,
                                    switches: shown != nil && choice.name != shown)
            }
        }
    }

    /// The menu's line: a host's own menu (`host` given) names the multiplexer, the menu across hosts the host.
    func title(host: UUID?) -> String { host == nil ? hostName : "New \(multiplexer.name) space" }

    /// Under it: what a switch does, else (across hosts) the multiplexer.
    func subtitle(host: UUID?) -> String? {
        if switches { return "Switches \(hostName) to \(multiplexer.name)" }
        return host == nil ? multiplexer.name : nil
    }

    /// The VoiceOver action's name.
    func spoken(host: UUID?) -> String {
        let title = host == nil ? "New space on \(hostName)" : title(host: host)
        return [title, subtitle(host: host)].compactMap { $0 }.joined(separator: ", ")
    }

}

/// A new space's name, by the Mac's rule (`Space.usesDirectoryName`): its folder's last component ("/" for the root),
/// following the folder until the space is renamed. On tmux and herdr the server keeps that rule, so the Mac and the
/// phone show the same name: the helper names a tmux space after its first window's folder while the windows'
/// `@dispatch-window` option says `usesDirectoryName` (`entities.rename` turns it off), and herdr labels a workspace
/// after its pane's folder until it is given a label. Both follow `cd`. So a space made without a name gets none from
/// the phone (no `entities.rename`); this is only what it will be called: New space's placeholder, and the label tmux's
/// `memberships.place` requires (shown only while the folder is unknown).
enum NewSpaceName {
    /// `directory` as typed (`~`, `~/src/app`, absolute) on `host`; nil when it cannot be made absolute (no home known).
    static func automatic(_ directory: String?, host: TabsHost) -> String? {
        let path = host.expand(directory ?? "~")
        guard path.hasPrefix("/") else { return nil }
        if path.allSatisfy({ $0 == "/" }) { return "/" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

/// The quick menu's entries, as system menu items: one per destination, its title and the line under it.
struct NewSpaceQuickMenu: View {
    let destinations: [NewSpaceDestination]
    /// The host whose New space line holds the menu; nil across hosts (New tab's picker).
    var host: UUID? = nil
    let create: (NewSpaceDestination) -> Void

    var body: some View {
        ForEach(destinations) { destination in
            Button { create(destination) } label: {
                Text(destination.title(host: host))
                if let subtitle = destination.subtitle(host: host) { Text(subtitle) }
            }
        }
    }
}
