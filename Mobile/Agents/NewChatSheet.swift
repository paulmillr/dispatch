import SwiftUI

/// A space a new chat can start in: a workspace (herdr workspace, tmux session) on a connected host, by its topology
/// key, which outlives the connection (its node id does not: `start` looks the id up when it runs).
struct ChatSpaceChoice: Identifiable, Hashable {
    let host: UUID
    let hostName: String
    /// The workspace's topology key.
    let key: String
    let name: String
    var id: String { host.uuidString + ":" + key }
}

extension ChatConversations {
    /// Every space on a connected host, by host then name.
    var spaces: [ChatSpaceChoice] {
        hosts.values.filter { $0.client != nil }.flatMap { host in
            (host.topology?.nodes ?? []).filter { $0.kind == .workspace && !$0.detached }
                .map { ChatSpaceChoice(host: host.id, hostName: host.name, key: $0.key, name: $0.name) }
        }
        .sorted { ($0.hostName, $0.name) < ($1.hostName, $1.name) }
    }

    /// The space's node id on the host's current connection, nil when it is gone.
    func node(of space: ChatSpaceChoice) -> UInt64? {
        hosts[space.host]?.topology?.nodes.first { $0.key == space.key && $0.kind == .workspace && !$0.detached }?.id
    }

    /// Starts `launch` in a new tab of `space` (`terminals.create` with `launch`) and returns the conversation once the
    /// topology shows its terminal. Optional integrations (Pi's extension) are enabled on this connection first: the
    /// helper keeps that choice in memory per connection (docs/ios.md, Helper contract).
    func start(_ launch: HelperClient.Launch, in space: ChatSpaceChoice,
               settings: (model: String, effort: String?)?) async throws -> ChatConversationKey {
        guard let client = hosts[space.host]?.client else {
            throw HelperFailure(code: "connection_closed", message: "\(space.hostName) is not connected.")
        }
        if let audit: HelperChat.Installation = try? await client.connection.request(
            "installation.audit", params: HelperChat.Setup(launch: launch.launch, enabled: nil, terminal: nil)),
           audit.optional == true, audit.installed != true {
            let _: HelperChat.Installation = try await client.connection.request(
                "installation.install", params: HelperChat.Setup(launch: launch.launch, enabled: true, terminal: nil))
        }
        // The id on this connection, read now: the sheet keeps the space by key across reconnects.
        guard let parent = node(of: space) else {
            throw HelperFailure(code: "not_found", message: "\(space.name) is no longer on \(space.hostName).")
        }
        let terminal = try await client.create(.init(parent: parent, beside: nil, cwd: nil, launch: launch.launch))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let key = key(host: space.host, terminal: terminal) {
                if let settings { session(for: key).pendingSettings = settings }
                return key
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HelperFailure(code: "timeout", message: "The chat started, but its tab has not appeared on \(space.hostName) yet.")
    }
}

/// What Tabs lends New chat to make a space (it owns New space, M7a): the form, and the quick menu's places and maker.
/// A space made here becomes the chat's, rather than opening in Terminal as it does from Spaces.
struct NewChatSpaceMaker {
    /// The quick menu's places: every connected host's multiplexers (`NewSpaceDestination.all`).
    var destinations: @MainActor () -> [NewSpaceDestination]
    /// A space with New space's defaults there (`SpacesNavigator.makeSpace`): its host and key.
    var quick: @MainActor (NewSpaceDestination) async throws -> SpaceRef
    /// New space's form over New chat; `created` gets the space made with it.
    var form: @MainActor (_ created: @escaping (SpaceRef) -> Void) -> AnyView
}

/// M9a: New chat, from the New button on Agents (`MobileSheet.newChat`). Space is a pull-down of existing spaces with
/// "New space…" at the end (the form over this sheet) and, as holding New space does in Spaces, a "New space on" menu
/// of hosts and multiplexers that makes one at once with the form's defaults (a pull-down's items cannot be held, so
/// the quick menu is a submenu here). Either way the new space becomes the chat's, its field showing the making in
/// place of a name until the space is listed. Agent, model and effort follow, defaulting to the last used. Start opens
/// the thread in Chat with the keyboard up.
struct NewChatSheet: View {
    let conversations: ChatConversations
    var memory: ChatModelMemory = .shared
    var look = ChatHostLook()
    /// Tabs' New space; nil (the Chat demo): "New space…" does nothing and there is no quick menu.
    var spaceMaker: NewChatSpaceMaker?
    /// The conversation started: open its thread with the keyboard up.
    var started: (ChatConversationKey) -> Void

    @State private var space: ChatSpaceChoice?
    @State private var launches: [HelperClient.Launch] = []
    /// A space being made for the chat: its host, then its key once made, until `spaces` lists it.
    @State private var making: (host: UUID, hostName: String, made: SpaceRef?)?
    @State private var showingForm = false

    /// The first space is chosen before the first frame, so the field never shows "Choose a space" first.
    init(conversations: ChatConversations, memory: ChatModelMemory = .shared, look: ChatHostLook = ChatHostLook(),
         spaceMaker: NewChatSpaceMaker? = nil, started: @escaping (ChatConversationKey) -> Void) {
        self.conversations = conversations
        self.memory = memory
        self.look = look
        self.spaceMaker = spaceMaker
        self.started = started
        _space = State(initialValue: conversations.spaces.first)
    }
    @State private var agent: String?
    @State private var model: String?
    @State private var effort: String?
    @State private var starting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let spaces = conversations.spaces
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
                Button(action: start) {
                    Text("Start").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.onAccent)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.dispatchPink)
                .disabled(space == nil || selectedLaunch == nil || starting || making != nil)
            }
            .overlay {
                Text("New chat").font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 110)
                    .accessibilityAddTraits(.isHeader)
            }
            // The sheet's bar: it grows to xxxLarge, as a navigation bar does, so Start never covers the title.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field("Space", note: "The chat runs as a new tab in this space.") {
                        Menu {
                            ForEach(spaces) { choice in
                                Button("\(choice.name)  \(choice.hostName)") { space = choice }
                            }
                            Divider()
                            Button("New space…", systemImage: "plus") { showingForm = spaceMaker != nil }
                            let destinations = spaceMaker?.destinations() ?? []
                            if !destinations.isEmpty {
                                Menu {
                                    NewSpaceQuickMenu(destinations: destinations, create: quick)
                                } label: {
                                    Label("New space on", systemImage: "plus.square.on.square")
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if let making {
                                    // Being made: no name yet (the server gives it), so none is shown.
                                    hostDisc(making.host)
                                    ProgressView()
                                    Text("New space").foregroundStyle(.secondary)
                                    Text(making.hostName).foregroundStyle(.tertiary)
                                } else if let space {
                                    hostDisc(space.host)
                                    Text(space.name).foregroundStyle(.primary)
                                    Text(space.hostName).foregroundStyle(.tertiary)
                                } else {
                                    Text(spaces.isEmpty ? "No spaces on a connected host" : "Choose a space").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            .font(.body)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .frame(minHeight: 48)
                            .background(Color.bubbleAgent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .tint(.primary)
                        .accessibilityLabel("Space")
                        .accessibilityValue(making.map { "Making a new space on \($0.hostName)" }
                                            ?? space.map { "\($0.name) on \($0.hostName)" } ?? "None")
                        .disabled(making != nil)
                    }
                    if !launches.isEmpty {
                        field("Agent") {
                            Picker("Agent", selection: Binding(get: { agent ?? "" }, set: { choose(agent: $0) })) {
                                ForEach(launches, id: \.key) { Text($0.key).tag($0.key) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    if let agent {
                        let remembered = memory.agent(agent)
                        if !remembered.models.isEmpty || model != nil {
                            field("Model") {
                                Menu {
                                    ForEach(remembered.models) { choice in Button(choice.label) { choose(model: choice.id) } }
                                } label: {
                                    HStack {
                                        Text(remembered.models.first { $0.id == model }?.label ?? model ?? "Default").foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                    }
                                    .font(.body)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .frame(minHeight: 48)
                                    .background(Color.bubbleAgent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .tint(.primary)
                                // "Model, fable-5.1": the field's name, the model id as its value.
                                .accessibilityLabel("Model")
                                .accessibilityValue(remembered.models.first { $0.id == model }?.label ?? model ?? "Default")
                            }
                        }
                        if let model, let efforts = remembered.efforts[model], !efforts.isEmpty {
                            field("Effort") {
                                Picker("Effort", selection: Binding(get: { effort ?? "" }, set: { effort = $0 })) {
                                    ForEach(efforts) { Text($0.label).tag($0.id) }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .tint(Color.dispatchPink)
        // M9a draws the sheet's grabber, as New space's (M7a) does.
        .presentationDragIndicator(.visible)
        .onChange(of: spaces) { _, spaces in
            if let made = making?.made { adopt(made) } else if space == nil { space = spaces.first }
        }
        .sheet(isPresented: $showingForm) {
            spaceMaker?.form { made in
                showingForm = false
                making = (made.host, conversations.hosts[made.host]?.name ?? "", made)
                adopt(made)
                expire(made)
            }
        }
        .task(id: space?.host) { await loadLaunches() }
    }

    private var selectedLaunch: HelperClient.Launch? { launches.first { $0.key == agent } }

    /// The host's glyph on its tinted disc, as the field shows a space's host.
    private func hostDisc(_ host: UUID) -> some View {
        look.glyph(host)
            .accessibilityHidden(true)
            .frame(width: 15, height: 15)
            .foregroundStyle(look.tint(host))
            .frame(width: 28, height: 28)
            .background(look.tint(host).opacity(0.15), in: Circle())
    }

    /// The quick menu's entry: a space with New space's defaults, which becomes the chat's once listed.
    private func quick(_ destination: NewSpaceDestination) {
        guard let spaceMaker, making == nil else { return }
        making = (destination.host, destination.hostName, nil)
        error = nil
        Task {
            do {
                let made = try await spaceMaker.quick(destination)
                making?.made = made
                adopt(made)
                expire(made)
            } catch {
                making = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// The made space as the chat's, once `spaces` lists it (Chat's topology can come a turn after Tabs'); the field
    /// shows the making until then, never the space chosen before.
    private func adopt(_ made: SpaceRef) {
        guard let choice = conversations.spaces.first(where: { $0.host == made.host && $0.key == made.key }) else { return }
        space = choice
        making = nil
    }

    /// A made space Chat never lists (its host dropped meanwhile) stops the making after a while, with a word.
    private func expire(_ made: SpaceRef) {
        guard making != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard making?.made == made else { return }
            making = nil
            error = "The space was made, but \(conversations.hosts[made.host]?.name ?? "its host") has not listed it yet."
        }
    }

    private func field<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.footnote).tracking(0.52).foregroundStyle(.secondary).padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            content()
            if let note { Text(note).font(.footnote).foregroundStyle(.tertiary).padding(.horizontal, 16) }
        }
    }

    private func loadLaunches() async {
        guard let space, let client = conversations.hosts[space.host]?.client else { launches = []; return }
        do {
            launches = try await client.launches()
            error = nil
        } catch is CancellationError {
            // Another space was picked or the sheet went away: that load's answer no longer matters, and the sheet
            // showed "The operation couldn't be completed. (Swift.CancellationError error 1.)" at rest.
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        if agent == nil || !launches.contains(where: { $0.key == agent }) {
            choose(agent: launches.first { $0.key == memory.lastAgent }?.key ?? launches.first?.key ?? "")
        }
    }

    private func choose(agent key: String) {
        agent = key.isEmpty ? nil : key
        let remembered = memory.agent(key)
        model = remembered.model
        effort = remembered.effort
    }

    private func choose(model id: String) {
        model = id
        let efforts = memory.agent(agent ?? "").efforts[id] ?? []
        if !efforts.contains(where: { $0.id == effort }) { effort = efforts.last?.id }
    }

    private func start() {
        guard let space, let launch = selectedLaunch else { return }
        starting = true; error = nil
        Task {
            defer { starting = false }
            do {
                let key = try await conversations.start(launch, in: space, settings: model.map { ($0, effort) })
                memory.remember(agent: launch.key, model: model, effort: effort)
                dismiss()
                started(key)
            } catch { self.error = error.localizedDescription }
        }
    }
}
