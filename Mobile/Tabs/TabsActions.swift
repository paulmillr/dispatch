import SwiftUI

/// The Tabs screens' shared actions and their dialogs: rename, Close, Detach, Terminate (with the Mac's confirmation),
/// and the alert for a failed request. Attached once to the Tabs navigation stack. A plain host's shells close on the
/// phone (`MobileTabs.closeShell`): Close tab at once, Close space after asking while a shell is live.
@MainActor @Observable
final class TabsActions {
    enum Target: Hashable {
        case tab(TabRef)
        case space(SpaceRef)
    }

    var renaming: Target?
    var name = ""
    var terminating: Target?
    /// M4d's Close space: the dialog with Detach and Terminate…, the Mac's space menu.
    var closingSpace: SpaceRef?
    /// Close space of a Shell space with live shells: the dialog that ends them.
    var closingShells: SpaceRef?
    var failure: String?

    @ObservationIgnored let model: MobileTabs
    /// A target that closed (or is closing): the stack pops what showed it.
    @ObservationIgnored var closed: (Target) -> Void = { _ in }

    init(model: MobileTabs) { self.model = model }

    func title(_ target: Target) -> String? {
        switch target {
        case .tab(let ref): model.tab(ref)?.name
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

    /// Terminate asks first, with the Mac's words; Close and Detach act at once (the work of a busy tab keeps running).
    /// A shell tab closes at once whichever way (nothing keeps a plain shell); a Shell space asks first while one of
    /// its shells is live.
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
        run(target, how)
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

/// A tab's menu (long press on a row): the Mac's tab menu, with Rename; a shell tab's is Close Tab alone.
struct TabsTabMenu: View {
    let actions: TabsActions
    let tab: TabRef

    var body: some View {
        if TabsTabMenu.isShell(tab) {
            Button("Close Tab", systemImage: "xmark") { actions.close(.tab(tab), .close) }
        } else {
            multiplexerItems
        }
    }

    static func isShell(_ tab: TabRef) -> Bool { ShellSessions.isKey(tab.key) }

    @ViewBuilder private var multiplexerItems: some View {
        Button("Rename…", systemImage: "pencil") { actions.rename(.tab(tab)) }
        Divider()
        Button("Close Tab", systemImage: "xmark") { actions.close(.tab(tab), .close) }
        Button("Detach", systemImage: "eject") { actions.close(.tab(tab), .detach) }
        Button("Terminate…", systemImage: "xmark.octagon", role: .destructive) { actions.close(.tab(tab), .terminate) }
    }
}
