import SwiftUI

/// The Tabs screens' shared actions and their dialogs: rename, Close, Detach, Terminate (with the Mac's confirmation),
/// and the alert for a failed request. Attached once to the Tabs navigation stack.
@MainActor @Observable
final class TabsActions {
    enum Target: Hashable {
        case tab(TabRef)
        case space(SpaceRef)
    }

    var renaming: Target?
    var name = ""
    var terminating: Target?
    /// M4d's Close space: the dialog with Close Space, Detach and Terminate….
    var closingSpace: SpaceRef?
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
    func close(_ target: Target, _ how: TabsClose) {
        if how == .terminate {
            terminating = target
            return
        }
        run(target, how)
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

/// A tab's menu (long press on a row): the Mac's tab menu, with Rename.
struct TabsTabMenu: View {
    let actions: TabsActions
    let tab: TabRef

    var body: some View {
        Button("Rename…", systemImage: "pencil") { actions.rename(.tab(tab)) }
        Divider()
        Button("Close Tab", systemImage: "xmark") { actions.close(.tab(tab), .close) }
        Button("Detach", systemImage: "eject") { actions.close(.tab(tab), .detach) }
        Button("Terminate…", systemImage: "xmark.octagon", role: .destructive) { actions.close(.tab(tab), .terminate) }
    }
}
