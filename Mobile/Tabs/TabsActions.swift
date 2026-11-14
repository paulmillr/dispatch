import SwiftUI

/// The Tabs screens' shared actions and their dialogs: rename, Close, Detach, Terminate (with the Mac's confirmation),
/// and the alert for a failed request. Attached once to the Tabs navigation stack. Close of a tab ends it: at once when
/// its agents' turns are over or the helper verifies it idle, else after asking (`closing`). A plain host's shells close
/// on the phone (`MobileTabs.closeShell`): Close tab at once, Close space after asking while a shell is live.
@MainActor @Observable
final class TabsActions {
    enum Target: Hashable {
        case tab(TabRef)
        case space(SpaceRef)
    }

    var renaming: Target?
    var name = ""
    var terminating: Target?
    /// Close of a tab that runs work: the question naming it, then Terminate.
    var closing: TabRef?
    /// Close space of a Shell space with live shells: the dialog that ends them.
    var closingShells: SpaceRef?
    var failure: String?

    @ObservationIgnored let model: MobileTabs
    /// A target that closed (or is closing): the stack pops what showed it.
    @ObservationIgnored var closed: (Target) -> Void = { _ in }

    init(model: MobileTabs) { self.model = model }

    func title(_ target: Target) -> String? {
        switch target {
        // What the tab shows, not the multiplexer's name for it (`MobileTabs.ownTitle`).
        case .tab(let ref): model.tab(ref).map { model.ownTitle(of: $0) }
        case .space(let ref): model.space(ref)?.name
        }
    }

    func rename(_ target: Target) {
        name = title(target) ?? ""
        renaming = target
    }

    func commitRename() {
        guard let target = renaming else { return }
        renaming = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != title(target) else { return }
        perform(target) { workspace in
            switch target {
            case .tab(let ref): if let tab = workspace.tab(ref.key) { try await workspace.rename(tab: tab, to: name) }
            case .space(let ref): if let space = workspace.space(ref.key) { try await workspace.rename(space: space, to: name) }
            }
        }
    }

    /// Move to's spaces for a tab: its host's other multiplexer spaces while connected (`MobileWorkspace.moveTargets`).
    func moveTargets(_ ref: TabRef) -> [MobileSpace] {
        guard let workspace = model.workspace(ref.host), let tab = workspace.tab(ref.key),
              let space = workspace.space(of: tab) else { return [] }
        return workspace.moveTargets(from: space)
    }

    /// Move to: the tab goes to `target` on the server (`MobileWorkspace.move(tab:to:)`); the topology brings it there,
    /// and a refusal shows as other failures do.
    func move(_ ref: TabRef, to target: MobileSpace) {
        perform(.tab(ref)) { workspace in
            if let tab = workspace.tab(ref.key) { try await workspace.move(tab: tab, to: target) }
        }
    }

    /// Terminate asks first, with the Mac's words; Detach acts at once. Close of a tab ends it at once when nothing would
    /// be lost (`closeTab`), else asks; Close of a space detaches it. A shell tab closes at once whichever way (nothing
    /// keeps a plain shell); a Shell space asks first while one of its shells is live.
    func close(_ target: Target, _ how: TabsClose) {
        switch target {
        case .tab(let ref) where model.tab(ref)?.isShell == true:
            closed(target)
            model.closeShell(ref)
            return
        case .space(let ref) where model.space(ref)?.kind == .plainShell:
            if model.space(ref)?.tabs.contains(where: { $0.shell == .live }) == true {
                closingShells = ref
            } else {
                closeShells(ref)
            }
            return
        default: break
        }
        if how == .terminate {
            terminating = target
            return
        }
        if how == .close, case .tab(let ref) = target {
            closeTab(ref)
            return
        }
        run(target, how)
    }

    /// Close of a multiplexer's tab. Its agents' turns are over (`MobileTabs.agentsFinished`): terminated at once, the
    /// conversation stays in the agent's history. Else the helper checks it (nothing changes, the row stays meanwhile):
    /// verified idle, it is terminated; busy, or not inspectable, the user is asked.
    private func closeTab(_ ref: TabRef) {
        let target = Target.tab(ref)
        guard let tab = model.tab(ref) else { return }
        if model.agentsFinished(tab) {
            run(target, .terminate)
            return
        }
        perform(target) { [weak self] workspace in
            guard let tab = workspace.tab(ref.key) else { return }
            guard try await workspace.idle(tab: tab) else {
                self?.closing = ref
                return
            }
            guard let self else { return }
            self.model.noteUserClose(target)
            self.closed(target)
            if try await workspace.close(tab: tab, .close) == .busy { self.closing = ref }
        }
    }

    /// The confirmed Close of a busy tab.
    func confirmClose(_ ref: TabRef) {
        closing = nil
        run(.tab(ref), .terminate)
    }

    /// The confirmed Close space of a Shell space: every shell of the host ends.
    func closeShells(_ ref: SpaceRef) {
        closingShells = nil
        closed(.space(ref))
        model.closeShells(host: ref.host)
    }

    /// The confirmed Terminate.
    func terminate(_ target: Target) {
        terminating = nil
        run(target, .terminate)
    }

    private func run(_ target: Target, _ how: TabsClose) {
        model.noteUserClose(target)
        closed(target)
        perform(target) { workspace in
            switch target {
            case .tab(let ref): if let tab = workspace.tab(ref.key) { try await workspace.close(tab: tab, how) }
            case .space(let ref): if let space = workspace.space(ref.key) { try await workspace.close(space: space, how) }
            }
        }
    }

    private func perform(_ target: Target, _ work: @escaping @MainActor (MobileWorkspace) async throws -> Void) {
        let host = switch target { case .tab(let ref): ref.host; case .space(let ref): ref.host }
        guard let workspace = model.workspace(host) else { return }
        Task {
            do { try await work(workspace) } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

extension View {
    func tabsDialogs(_ actions: TabsActions) -> some View { modifier(TabsDialogs(actions: actions)) }
}

private struct TabsDialogs: ViewModifier {
    @Bindable var actions: TabsActions

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<TabsActions, T?>) -> Binding<Bool> {
        Binding(get: { actions[keyPath: keyPath] != nil }, set: { if !$0 { actions[keyPath: keyPath] = nil } })
    }

    private var renameTitle: String {
        if case .space = actions.renaming { "Rename space" } else { "Rename tab" }
    }

    private var closeTitle: String {
        let model = actions.model
        let name = actions.closing.flatMap { ref in model.tab(ref).map { model.label(of: $0, host: model.workspace(ref.host)?.host) } }
        return TabsCloseCopy.title(tab: name ?? "")
    }

    private var terminateTitle: String {
        switch actions.terminating {
        case .tab(let ref)?: TabsTerminateCopy.title(tab: actions.model.tab(ref)?.name ?? "")
        case .space(let ref)?: TabsTerminateCopy.title(space: actions.model.space(ref)?.name ?? "")
        case nil: ""
        }
    }

    func body(content: Content) -> some View {
        content
            .alert(renameTitle, isPresented: binding(\.renaming)) {
                TextField("Name", text: $actions.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Rename") { actions.commitRename() }
            }
            .alert(TabsShellCopy.closeTitle, isPresented: binding(\.closingShells), presenting: actions.closingShells) { ref in
                Button("Cancel", role: .cancel) {}
                Button(TabsShellCopy.closeConfirm, role: .destructive) { actions.closeShells(ref) }
            } message: { _ in
                Text(TabsShellCopy.closeMessage)
            }
            .alert(closeTitle, isPresented: binding(\.closing), presenting: actions.closing) { ref in
                Button("Cancel", role: .cancel) {}
                Button(TabsCloseCopy.confirm, role: .destructive) { actions.confirmClose(ref) }
            } message: { ref in
                Text(actions.model.tab(ref).map(actions.model.closeMessage) ?? TabsCloseCopy.consequence)
            }
            .alert(terminateTitle, isPresented: binding(\.terminating), presenting: actions.terminating) { target in
                Button("Cancel", role: .cancel) {}
                Button(TabsTerminateCopy.confirm, role: .destructive) { actions.terminate(target) }
            } message: { _ in
                Text(TabsTerminateCopy.message)
            }
            .alert("Couldn’t finish that", isPresented: binding(\.failure)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actions.failure ?? "")
            }
    }
}

/// What closing a Shell space says (plain SSH: the shells are the phone's, nothing on the host keeps them).
enum TabsShellCopy {
    static let closeTitle = "Close all shells?"
    static let closeMessage = "Each shell and the programs running in it end. Nothing on the host keeps them."
    static let closeConfirm = "Close Shells"
}

/// A tab's menu (long press on a row, the tab's header): Rename… (a space's rows: its Edit in that place, which renames
/// there), Move to the host's other spaces under it, then Detach (hidden on this connection, still running; not from the
/// tab's own header) and Close Tab (which asks while work runs); a shell tab's is Close Tab alone.
struct TabsTabMenu: View {
    let actions: TabsActions
    let tab: TabRef
    /// The space's Edit, in Rename…'s place (a space's rows).
    var edit: (() -> Void)? = nil
    /// Detach; the tab's header leaves it to the rows.
    var detach = true

    var body: some View {
        if TabsTabMenu.isShell(tab) {
            Button("Close Tab", systemImage: "xmark") { actions.close(.tab(tab), .close) }
        } else {
            multiplexerItems
        }
    }

    static func isShell(_ tab: TabRef) -> Bool { ShellSessions.isKey(tab.key) }

    @ViewBuilder private var multiplexerItems: some View {
        if let edit {
            Button("Edit", systemImage: "pencil", action: edit)
        } else {
            Button("Rename…", systemImage: "pencil") { actions.rename(.tab(tab)) }
        }
        SpaceMoveMenu(targets: actions.moveTargets(tab)) { actions.move(tab, to: $0) }
        // How it ends, set apart where Detach is offered; the header's Close Tab follows Move to directly.
        if detach {
            Divider()
            Button("Detach", systemImage: "eject") { actions.close(.tab(tab), .detach) }
        }
        Button("Close Tab", systemImage: "xmark") { actions.close(.tab(tab), .close) }
    }
}
