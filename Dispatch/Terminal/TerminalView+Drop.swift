import AppKit

/// Files dropped on a terminal type their paths at the cursor, shell-quoted and space-separated (F2c): Finder's
/// files as this Mac's paths (asking first when the tab's shell runs on another host), rows of a files view as the
/// paths on their host, which is the host the tab's shell usually runs on. Nothing is copied. Finder drops work with
/// Files off; a files view's rows need its drag and drop.
@MainActor enum TerminalDrop {
    static let types: [NSPasteboard.PasteboardType] = [.filesPaths, .fileURL]

    /// Every character outside `[A-Za-z0-9,._+:@%/-]` behind a backslash, as Terminal.app quotes a drop: sh, bash,
    /// zsh and fish all read `\c` as `c`, where single quotes are not safe everywhere (fish treats `\\` and `\'`
    /// inside them as escapes). Only for names without control characters (`text` leaves those out): a backslash
    /// before a newline continues the line instead.
    static func quote(_ path: String) -> String {
        var out = ""
        for scalar in path.unicodeScalars {
            if !plain.contains(scalar) { out.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    private static let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789,._+:@%/-")

    /// A path that would type a control character (CR, LF, ESC, …): it could run a command or drive the
    /// terminal, so it is never typed, quoted or not.
    static func typable(_ path: String) -> Bool {
        !path.unicodeScalars.contains { unsafe.contains($0) }
    }

    /// C0 and C1 controls, DEL, and the Unicode line and paragraph separators. Not all of `controlCharacters`: its
    /// format characters include the joiner inside emoji names.
    private static let unsafe = CharacterSet(charactersIn: Unicode.Scalar(UInt8(0x00))...Unicode.Scalar(UInt8(0x1F)))
        .union(CharacterSet(charactersIn: Unicode.Scalar(UInt8(0x7F))...Unicode.Scalar(UInt8(0x9F))))
        .union(CharacterSet(charactersIn: "\u{2028}\u{2029}"))

    /// What a drop of this pasteboard types, or nil when it carries no path that can be typed. The text has no
    /// control character and no newline, so the paste needs no confirmation: `TerminalBackend.text` pastes it as is
    /// (with bracketed paste when the shell asked for it), the same path every typed-in command takes.
    static func text(_ pasteboard: NSPasteboard) -> String? {
        text(FilesDragPayload.read(pasteboard)?.paths
             ?? FilesDragController.resolve(FilesDragController.droppedFiles(pasteboard)))
    }

    static func text(_ paths: [String]) -> String? {
        let typed = paths.filter(typable)
        guard !typed.isEmpty else { return nil }
        return typed.map(quote).joined(separator: " ")
    }

    /// Whether a drop may type something, decided without the disk while the drag is live: a file reference's
    /// name is known only once it is resolved, after the drop (`FilesDragController.droppedFiles`).
    static func accepts(_ pasteboard: NSPasteboard) -> Bool {
        if let paths = FilesDragPayload.read(pasteboard)?.paths { return paths.contains(where: typable) }
        return FilesDragController.droppedFiles(pasteboard).contains { FilesDragController.plainPath($0).map(typable) ?? true }
    }
}

extension TerminalView {
    func registerDropTypes() {
        registerForDraggedTypes(TerminalDrop.types)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { dropOperation(sender) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard dropOperation(sender) == .copy, let surface else { return false }
        let pasteboard = sender.draggingPasteboard
        if let paths = FilesDragPayload.read(pasteboard)?.paths {
            guard let text = TerminalDrop.text(paths) else { return false }
            surface.text(text)
            return true
        }
        // Finder's files: typed once their paths are resolved, off the main thread and after the drop returned.
        let files = FilesDragController.droppedFiles(pasteboard)
        Task { @MainActor [weak self] in
            let paths = await Task.detached { FilesDragController.resolve(files) }.value
            guard let self, !self.inputParked, self.surface != nil, let text = TerminalDrop.text(paths) else { return }
            // This Mac's paths mean nothing to a shell on another host: say so before typing them there.
            if let host = self.remoteHostName, !self.confirmMacPaths(paths, host: host) { return }
            guard !self.inputParked, let surface = self.surface else { return }
            surface.text(text)
        }
        return true
    }

    /// The host this tab's shell runs on when it is not this Mac (an SSH login or a remote space), by its name.
    var remoteHostName: String? {
        guard let workspace = TerminalRuntime.shared.workspace,
              let space = workspace.spaces.first(where: { $0.tabs.contains { $0.surfaceIDs.contains(id) } }) else { return nil }
        let host = workspace.hosts.terminals[id]?.host ?? space.hostID
        return host == .local ? nil : workspace.hosts.record(host).name
    }

    /// Asks before typing Finder's paths into a shell on `host`; true: type them. Show Files opens the tab's files view,
    /// where a drop copies the files to the host.
    private func confirmMacPaths(_ paths: [String], host: String) -> Bool {
        let alert = NSAlert()
        let name = paths.count == 1 ? "“\((paths[0] as NSString).lastPathComponent)” is" : "These \(paths.count) files are"
        alert.messageText = "Type this Mac's paths on \(host)?"
        alert.informativeText = "\(name) on this Mac. The shell in this tab runs on \(host), where these paths don't exist. To copy files there, drop them on the tab's Files view."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Type Paths")
        let files = TerminalRuntime.shared.files, canShow = files.canShowFiles(id)
        if canShow { alert.addButton(withTitle: "Show Files") }
        switch AppDelegate.runSheet(alert, in: window) {
        case .alertSecondButtonReturn: return true
        case .alertThirdButtonReturn:
            TerminalRuntime.shared.workspace?.selectSurface(id)
            files.showFiles(id, tab: .files)
            return false
        default: return false
        }
    }

    /// A parked terminal (reconnecting, an overlay holding input) takes no typing, so no drop either. Finder's files
    /// always type their paths; a files view's rows need Files' drag and drop, which made them.
    private func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        guard !inputParked, surface != nil, TerminalDrop.accepts(pasteboard),
              FilesDragPayload.read(pasteboard) == nil || FilesTransferSettings.enabled() else { return [] }
        return .copy
    }
}
