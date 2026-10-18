import SwiftUI

/// M7a: New space. Name, the host as a pull-down (its tinted disc and up/down chevrons; the known hosts with the
/// current one ticked, then New host… which opens M8a and comes back with the new host selected), the directory (home
/// by default, or Other folder…). Create makes the space on the host's multiplexer and opens it in the terminal.
///
/// Between Home and Other folder… the host's recent project folders from agent history, one tap each, with the
/// footnote "Recent on <host>, from agent history": `projects.recent`, when the host's helper accepted that feature;
/// without it the card is Home and Other folder…, whose field completes typed paths from the directories the host's
/// open tabs are in.
struct NewSpaceSheet: View {
    let model: MobileTabs
    /// Host detail pre-selects its host; New tab's picker passes the recent space's.
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
    @State private var addingHost = false
    @State private var creating = false
    @State private var failure: String?
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
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Name") {
                        TextField("", text: $name, prompt: Text("Space name"))
                            .font(.body)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focus, equals: .name)
                            .onSubmit { focus = other ? .directory : nil }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6).frame(minHeight: 48)
                            .background(Self.field, in: RoundedRectangle(cornerRadius: 12))
                    }
                    section("Host") { hostPicker }
                    VStack(alignment: .leading, spacing: 7) {
                        section("Directory") { directoryField }
                        if !shownRecents.isEmpty, let host = workspace?.host {
                            Text("Recent on \(host.name), from agent history")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 16)
                        }
                    }
                    if let warning = workspace?.choice?.warning {
                        Text(warning)
                            .font(.footnote)
                            .foregroundStyle(Color.caution)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .secondarySystemBackground))
        .onAppear { focus = .name }
        .task(id: workspace?.id) {
            recent = nil
            await workspace?.recentProjects()
        }
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

    private static let field = Color(uiColor: .tertiarySystemBackground)

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
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var canCreate: Bool {
        !creating && workspace?.client != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .textCase(.uppercase)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            content()
        }
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
            HStack(spacing: 10) {
                if let host = workspace?.host {
                    TabsHostDisc(host: host, size: 28, glyph: 15)
                    Text(host.name).font(.body).foregroundStyle(.primary)
                    if workspace?.client == nil {
                        Text("offline").font(.footnote).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("No host").font(.body).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6).frame(minHeight: 48)
            .background(Self.field, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var suggestions: [String] {
        guard let workspace, focus == .directory else { return [] }
        return Self.complete(directory, in: workspace)
    }

    /// Home, ticked by default, and Other folder…, which becomes a typed path with completions.
    private var directoryField: some View {
        VStack(spacing: 0) {
            Button {
                other = false
                recent = nil
                directory = "~"
                focus = nil
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(workspace?.host.tint ?? .accentColor)
                        .opacity(other || recent != nil ? 0 : 1)
                        .frame(width: 16)
                    Text("~").font(.subheadline.monospaced())
                    Spacer()
                    Text("Home").font(.footnote).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6).frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 42)
            ForEach(shownRecents, id: \.path) { project in
                Button {
                    other = false
                    recent = project.path
                    focus = nil
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(workspace?.host.tint ?? .accentColor)
                            .opacity(recent == project.path && !other ? 1 : 0)
                            .frame(width: 16)
                        Text(workspace?.host.abbreviate(project.path) ?? project.path)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(recent == project.path && !other ? .primary : .secondary)
                            .fittingLine()
                        Spacer(minLength: 8)
                        if let label = TabsTime.ago(project.time) {
                            Text(label).font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6).frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 42)
            }
            if other {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(workspace?.host.tint ?? .accentColor)
                        .frame(width: 16)
                    TextField("", text: $directory, prompt: Text("~/src/project"))
                        .font(.subheadline.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($focus, equals: .directory)
                        .onSubmit(create)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6).frame(minHeight: 48)
                ForEach(suggestions, id: \.self) { path in
                    Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 42)
                    Button { directory = path } label: {
                        Text(path)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .fittingLine()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 42)
                            .padding(.trailing, 16)
                            .padding(.vertical, 6).frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button {
                    other = true
                    recent = nil
                    directory = ""
                    focus = .directory
                } label: {
                    HStack {
                        Text("Other folder…").font(.body).foregroundStyle(Color.dispatchPink)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 42)
                    .padding(.trailing, 16)
                    .padding(.vertical, 6).frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Self.field, in: RoundedRectangle(cornerRadius: 12))
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
        Task {
            defer { creating = false }
            do {
                if workspace.choice == nil { try await workspace.detect() }
                let tab = try await workspace.createSpace(name: name, directory: directory.isEmpty ? nil : directory)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.workspaces.filter { $0.client != nil && !$0.spaces.isEmpty }) { workspace in
                    Section(workspace.host.name) {
                        ForEach(workspace.spaces) { space in
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
                    Button("New space…", systemImage: "plus") { newSpace() }
                        .foregroundStyle(Color.dispatchPink)
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
        .presentationDetents([.medium, .large])
    }
}
