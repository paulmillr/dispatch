import AppKit
import SwiftUI

/// The updater's sheet over the main window (mockups U1–U4), in the setup sheet's style: Dispatch › Check for Updates…
/// opens it as it checks and it follows the updater (checking, then up to date, or downloading, verifying and ready);
/// the daily check opens it once its download is ready, in place of the alert that asked before. A tile names the
/// step (a ring fills round it as the update downloads, an arc circles it while it checks or verifies, a check once
/// ready), the title and a line under it the version and progress, then the release's notes (`UpdateChanges`) once
/// read. The footer's top edge is the progress line; Release notes opens the release's page; Cancel stops the check or
/// download, Later keeps a ready update for Settings › Updates, Restart and install quits to install it. The sheet
/// closes itself when the updater goes idle (cancelled) or installs.
@MainActor
enum UpdateSheet {
    static let width: CGFloat = 480

    /// What the sheet shows for the updater's state; nil closes it.
    enum Phase: Equatable {
        case checking
        /// The fraction downloaded, nil until the size is known.
        case downloading(Double?)
        case verifying
        case ready
        case upToDate
        /// A newer release this copy can't install itself (`AppUpdater.available`).
        case available
        case failed
    }

    static func phase(_ updater: AppUpdater) -> Phase? {
        switch updater.state {
        case .idle, .installing: nil
        case .checking: .checking
        case .downloading:
            if let progress = updater.progress, progress.expected > 0 {
                .downloading(min(1, Double(progress.received) / Double(progress.expected)))
            } else {
                .downloading(nil)
            }
        case .verifying: .verifying
        case .ready: .ready
        case .upToDate: .upToDate
        case .failed: updater.available != nil ? .available : .failed
        }
    }

    /// Shows the sheet over `window`, unless one is there already.
    @discardableResult
    static func present(over window: NSWindow, updater: AppUpdater) -> Panel? {
        if let shown = window.attachedSheet as? Panel { return shown }
        guard window.attachedSheet == nil, phase(updater) != nil else { return nil }
        let panel = Panel(updater: updater)
        window.beginSheet(panel)
        return panel
    }

    final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }

        init(updater: AppUpdater) {
            super.init(contentRect: NSRect(x: 0, y: 0, width: UpdateSheet.width, height: 200), styleMask: [.borderless],
                       backing: .buffered, defer: false)
            isReleasedWhenClosed = false
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            appearance = NSAppearance(named: Chrome.palette.isDark ? .darkAqua : .aqua)
            title = "Software Update"
            let host = NSHostingController(rootView: UpdateSheetView(updater: updater) { [weak self] in self?.dismiss() })
            host.sizingOptions = [.preferredContentSize]
            contentViewController = host
            setAccessibilityIdentifier("update-sheet")
        }

        /// Escape: Cancel or Later, whichever the sheet offers.
        override func cancelOperation(_ sender: Any?) {
            (contentViewController as? NSHostingController<UpdateSheetView>)?.rootView.escape()
        }

        func dismiss() {
            if let parent = sheetParent { parent.endSheet(self) } else { orderOut(nil) }
        }
    }
}

/// The sheet's content (`UpdateSheet`).
struct UpdateSheetView: View {
    let updater: AppUpdater
    let close: () -> Void
    private static let inner = UpdateSheet.width - 40

    private var phase: UpdateSheet.Phase { UpdateSheet.phase(updater) ?? .checking }
    private var installed: String { updater.installed }
    /// The newer release found: the one downloading or ready, or one this copy can't install itself.
    private var found: UpdateRelease? { updater.release ?? updater.available }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    UpdateTile(phase: phase)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Onboarding.sheetFont(13, bold: true)).foregroundStyle(Chrome.ink)
                            .accessibilityIdentifier("update-title")
                        Text(detail).font(Onboarding.sheetFont(11)).monospacedDigit().foregroundStyle(Onboarding.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("update-detail")
                    }
                    .padding(.top, 2)
                    Spacer(minLength: 0)
                }
                if let notes = updater.notes, notes.version == found?.version, !notes.changes.isEmpty, phase != .upToDate {
                    UpdateChanges(notes: notes, width: Self.inner)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
            footer
        }
        .frame(width: UpdateSheet.width)
        .background(Chrome.window)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Chrome.border))
        // Cancelled or installing: the sheet goes, after this update.
        .onChange(of: UpdateSheet.phase(updater) == nil, initial: true) { _, gone in
            if gone { DispatchQueue.main.async { close() } }
        }
    }

    private var title: String {
        let version = found?.version ?? ""
        return switch phase {
        case .checking: "Checking for updates…"
        case .downloading: "Downloading Dispatch \(version)"
        case .verifying: "Verifying Dispatch \(version)"
        case .ready: "Dispatch \(version) is ready"
        case .upToDate: "Dispatch is up to date"
        case .available: "Dispatch \(version) is available"
        case .failed: "The update didn’t finish"
        }
    }

    private var detail: String {
        let from = "from \(installed)"
        switch phase {
        case .checking: return "Dispatch \(installed) · asking GitHub for the newest release"
        case .downloading:
            guard let progress = updater.progress, progress.received > 0 else { return from }
            let received = AppUpdater.size(progress.received)
            return progress.expected > 0 ? "\(from) · \(received) of \(AppUpdater.size(progress.expected))" : "\(from) · \(received)"
        case .verifying: return "\(from) · checking the signature and notarization"
        case .ready: return "\(from) · downloaded and verified"
        case .upToDate: return "\(installed) is the newest release."
        case .available, .failed: return updater.status
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let found {
                Button { NSWorkspace.shared.open(UpdateNotes.page(found.version)) } label: {
                    HStack(spacing: 4) {
                        Text("Release notes")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(Onboarding.sheetFont(11.5)).foregroundStyle(Onboarding.muted)
                }
                .buttonStyle(.plain)
                .help("Open the release on GitHub")
                .accessibilityIdentifier("update-release-notes")
            }
            Spacer(minLength: 8)
            switch phase {
            case .checking, .downloading, .verifying:
                secondary("Cancel", identifier: "update-cancel", shortcut: .cancelAction) { updater.cancel() }
                if phase != .checking { primary("Restart and install", identifier: "update-install", enabled: false) {} }
            case .ready:
                secondary("Later", identifier: "update-later", shortcut: .cancelAction, action: close)
                primary("Restart and install", identifier: "update-install") { updater.restart() }
            case .upToDate:
                primary("OK", identifier: "update-ok", action: close)
            case .available:
                secondary("Close", identifier: "update-close", shortcut: .cancelAction, action: close)
                primary("Download…", identifier: "update-download") {
                    if let available = updater.available { NSWorkspace.shared.open(available.url) }
                    close()
                }
            case .failed:
                secondary("Close", identifier: "update-close", shortcut: .cancelAction, action: close)
                primary("Try Again", identifier: "update-retry") { updater.check() }
            }
        }
        .padding(.horizontal, 14).frame(height: 54)
        .background(Chrome.sidebar)
        .overlay(alignment: .top) { UpdateEdge(phase: phase) }
    }

    /// Escape: what the footer's secondary button does.
    func escape() {
        switch UpdateSheet.phase(updater) {
        case .checking, .downloading, .verifying: updater.cancel()
        default: close()
        }
    }

    private func secondary(_ title: String, identifier: String, shortcut: KeyboardShortcut? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Onboarding.sheetFont(12.5)).foregroundStyle(Chrome.ink.opacity(0.8))
                .padding(.horizontal, 14).frame(height: 30)
                .background(Chrome.ink.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .accessibilityIdentifier(identifier)
    }

    private func primary(_ title: String, identifier: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Onboarding.sheetFont(12.5, bold: true))
                .foregroundStyle(enabled ? Chrome.window : Chrome.ink.opacity(0.35))
                .padding(.horizontal, 14).frame(height: 30)
                .background(enabled ? Chrome.accent : Chrome.ink.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(enabled ? .defaultAction : nil)
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }
}

/// A release's notes, one change a line (`UpdateNotes`, five at most): the area's dot and name in a gutter, each area
/// in a colour of its own, the text cut to one line with the whole of it as its tooltip. In the sheet and in Settings ›
/// Updates.
struct UpdateChanges: View {
    let notes: UpdateNotes
    var width: CGFloat?
    static let row: CGFloat = 21

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(notes.changes.enumerated()), id: \.offset) { index, change in
                row(change).accessibilityIdentifier("update-change-\(index + 1)")
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .padding(.vertical, 6)
        .background(Chrome.sidebar, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What’s new in Dispatch \(notes.version)")
        .accessibilityIdentifier("update-notes")
    }

    private func row(_ change: UpdateNotes.Change) -> some View {
        let tint = change.area.map(Self.tint) ?? Onboarding.muted
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 5, height: 5)
                if let area = change.area {
                    Text(area).font(Onboarding.sheetFont(10.5, bold: true)).foregroundStyle(tint).lineLimit(1)
                }
            }
            .frame(width: 66, alignment: .leading)
            Text(change.text).font(Onboarding.sheetFont(11.5)).foregroundStyle(Chrome.ink.opacity(0.9))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: Self.row)
        .help(change.text)
        .accessibilityElement(children: .combine)
    }

    /// Each kind of area keeps a colour of the terminal's theme, so a glance tells what a release is about.
    static func tint(_ area: String) -> Color {
        let theme = ChatThemeStore.shared.current
        switch area.lowercased() {
        case "chat", "claude", "codex", "agents": return Chrome.accent
        case "files", "commits", "review", "git": return theme.green
        case "iphone", "ipad", "ios", "watch": return theme.keyword
        case "ssh", "tmux", "herdr", "pi": return theme.yellow
        default: return theme.cyan
        }
    }
}

/// The header's tile: the arrow with a ring filling round it as the update downloads; an arc circling it while it
/// checks, verifies or downloads with no size yet; a check once ready or up to date; a warning when it stopped.
private struct UpdateTile: View {
    let phase: UpdateSheet.Phase
    private static let glyph = Color(.sRGB, red: 126/255, green: 166/255, blue: 201/255)
    private static let tile = Color(.sRGB, red: 0.12, green: 0.17, blue: 0.21)

    var body: some View {
        let shape = UpdateRing(radius: 9)
        ZStack {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(done ? Chrome.accent : phase == .failed ? Chrome.palette.warning : Self.glyph)
                .frame(width: 28, height: 28)
                .background(Self.tile, in: RoundedRectangle(cornerRadius: 7))
            switch phase {
            case .downloading(let fraction?):
                shape.stroke(Chrome.ink.opacity(0.12), lineWidth: 2)
                shape.trim(from: 0, to: fraction).stroke(Chrome.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            case .checking, .verifying, .downloading(nil):
                TimelineView(.animation) { context in
                    let sweep = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    ZStack {
                        shape.stroke(Chrome.accent.opacity(0.3), lineWidth: 2)
                        shape.trim(from: sweep, to: min(1, sweep + 0.22))
                            .stroke(Chrome.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
            case .ready, .upToDate:
                shape.stroke(Chrome.accent.opacity(0.6), lineWidth: 2)
            case .available, .failed:
                shape.stroke(Chrome.ink.opacity(0.12), lineWidth: 2)
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private var done: Bool { phase == .ready || phase == .upToDate }

    private var symbol: String {
        switch phase {
        case .checking, .available: "arrow.down"
        case .downloading: "arrow.down"
        case .verifying: "checkmark.shield"
        case .ready, .upToDate: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// The footer's top edge as the progress line: the download's fraction in the accent with a glint at its end; while
/// checking, verifying or downloading with no size yet, dim and full with a bright segment sweeping along it; else
/// the hairline.
private struct UpdateEdge: View {
    let phase: UpdateSheet.Phase

    var body: some View {
        switch phase {
        case .downloading(let fraction?):
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Chrome.border)
                    Rectangle().fill(Chrome.accent).frame(width: geometry.size.width * fraction)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(LinearGradient(colors: [Chrome.accent.opacity(0), .white.opacity(0.7)],
                                                            startPoint: .leading, endPoint: .trailing))
                                .frame(width: min(40, geometry.size.width * fraction))
                        }
                }
            }
            .frame(height: 2)
        case .checking, .verifying, .downloading(nil):
            GeometryReader { geometry in
                TimelineView(.animation) { context in
                    let sweep = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Chrome.accent.opacity(0.35))
                        Rectangle().fill(LinearGradient(colors: [Chrome.accent.opacity(0), Chrome.accent, Chrome.accent.opacity(0)],
                                                        startPoint: .leading, endPoint: .trailing))
                            .frame(width: 120).offset(x: (geometry.size.width + 120) * sweep - 120)
                    }
                }
            }
            .frame(height: 2).clipped()
        default:
            Rectangle().fill(Chrome.border).frame(height: 1)
        }
    }
}

/// A rounded square traced clockwise from the top's centre, so a trimmed ring fills as a clock does.
private struct UpdateRing: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = radius
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.midX, y: rect.minY), radius: r)
        path.closeSubpath()
        return path
    }
}
