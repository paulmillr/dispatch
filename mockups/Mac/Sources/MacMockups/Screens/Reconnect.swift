import SwiftUI

// Reconnect without a new space or a window sheet (exploration, 2026-11-07). The strip (SSHReconnectOverlay) carries
// the whole login: ssh's prompts come to it through SSH_ASKPASS (SSH_ASKPASS_REQUIRE=force), answered in a secure
// field in the strip; Yes/No for a confirmation, a notice for a security key's touch. The login's log opens on demand
// under the strip, in that pane only. The tab's old content stays shown, scrollable and selectable under it; other tabs,
// spaces and hosts are untouched. Hosts, accounts and keys are fictional.

enum ReconnectScreens {
    static let screens: [Screen] = [
        Screen("N1-strip-states", group: "reconnect", "The strip in every state of a login") {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(ReconnectPhase.catalog.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.caption).font(.system(size: 12, weight: .semibold)).foregroundStyle(Chrome.palette.secondary)
                        VStack(spacing: 0) {
                            ReconnectStrip(phase: entry.phase)
                            TerminalScreen(lines: [Sample.restored[Sample.restored.count - 2], Sample.restored.last!],
                                           cursor: false).frame(height: 44, alignment: .top).clipped()
                        }
                        .background(TerminalScheme.current.background)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: 860)
                    }
                }
            }
        },
        Screen("N2-restored-space", group: "reconnect", "After a relaunch: the saved space as it was, no Reconnect space") {
            window(phase: .disconnected(info: ["14:02", "restored at launch"]), callouts: [
                (1, "No “Reconnect” space; the selection stays", CGPoint(x: 20, y: 300)),
                (2, "Saved output stays: scroll, select, search", CGPoint(x: 300, y: 480)),
            ])
        },
        Screen("N3-password", group: "reconnect", "ssh asks for a password: the field is in the strip") {
            window(phase: .secret(prompt: "dev@build-box's password:", typed: 9), callouts: [
                (1, "ssh's own prompt, answered here: ⏎ sends, esc cancels", CGPoint(x: 300, y: 480)),
                (2, "Other tabs, spaces and windows stay usable", CGPoint(x: 20, y: 300)),
            ])
        },
        Screen("N4-log", group: "reconnect", "Log on demand: wrong password, the login's output under the strip") {
            window(phase: .secret(prompt: "dev@build-box's password:", typed: 0, retry: true), log: true, callouts: [
                (1, "Opens and closes from Log; resizable; this pane only", CGPoint(x: 700, y: 92)),
            ])
        },
        Screen("N5-chat-split", group: "reconnect", "Two tabs of the host: chat keeps its transcript, one login for both") {
            DispatchWindow(sidebar: sidebar) {
                Split(fraction: 0.52) {
                    Pane(strip: StripModel(tabs: [TabItem(title: "Fix the invoice rounding", activity: .finished, selected: true)],
                                           mode: .chat, agent: true, layout: .columns, paneBadge: 1, host: Hosts.buildBox)) {
                        VStack(spacing: 0) {
                            ReconnectStrip(phase: .secret(prompt: "dev@build-box's password:", typed: 4), compact: true)
                            ChatPane(items: Sample.chat, composer: ComposerModel(draft: "Also cover the zero-amount case"))
                        }
                    }
                } second: {
                    Pane(strip: StripModel(tabs: [TabItem(title: "e2e", selected: true)], layout: .columns, paneBadge: 2,
                                           focused: false, host: Hosts.buildBox)) {
                        VStack(spacing: 0) {
                            ReconnectStrip(phase: .secret(prompt: "dev@build-box's password:", typed: 4, focused: false), compact: true)
                            TerminalScreen(lines: Sample.restored, focused: false).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Callout(number: 1, note: "Transcript scrolls; the draft stays, sending waits").offset(x: 300, y: 230)
                    Callout(number: 2, note: "Same login in every build-box tab; focused where you asked").offset(x: 760, y: 520)
                }
            }
        },
    ]

    private static let offline = MockHost(name: "build-box", system: .debian, color: .cyan, offline: true)
    private static let sidebar = SidebarModel(spaces: [
        SpaceItem(name: "app", activity: .finished, shortcut: 1),
        SpaceItem(name: "docs", shortcut: 2),
        SpaceItem(name: "billing", host: offline, activity: .offline, shortcut: 3),
        SpaceItem(name: "e2e", host: offline, activity: .offline, shortcut: 4, selected: true),
        SpaceItem(name: "release", host: Hosts.studio, shortcut: 5),
    ])

    private static func window(phase: ReconnectPhase, log: Bool = false, callouts: [(Int, String, CGPoint)]) -> some View {
        DispatchWindow(sidebar: sidebar) {
            Pane(strip: StripModel(tabs: [
                TabItem(title: "e2e", activity: .offline, shortcut: 1, selected: true),
                TabItem(title: "server", activity: .offline, shortcut: 2),
            ], host: Hosts.buildBox)) {
                VStack(spacing: 0) {
                    ReconnectStrip(phase: phase, logOpen: log)
                    if log { ReconnectLog(lines: Sample.loginLog) }
                    TerminalScreen(lines: Sample.restored, focused: false)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(callouts, id: \.0) { callout in
                    Callout(number: callout.0, note: callout.1).offset(x: callout.2.x, y: callout.2.y)
                }
            }
        }
    }
}

/// What the strip shows. The SSH_ASKPASS_PROMPT kinds map to `secret` (none given: a password, passphrase or code),
/// `confirm` ("confirm") and `touch` ("none", a notice that goes when the key answers).
enum ReconnectPhase {
    case disconnected(info: [String])
    case reconnecting(step: String)
    case secret(prompt: String, typed: Int, retry: Bool = false, reveal: Bool = false, focused: Bool = true)
    case touch(prompt: String)
    case confirm(question: String)
    /// An ssh too old for SSH_ASKPASS_REQUIRE: its prompt went to the login's terminal, which the log shows.
    case inLog
    /// The tab's terminal is gone from the server: read-only, Close tab only.
    case gone
    case connected

    static let catalog: [(caption: String, phase: ReconnectPhase)] = [
        ("Disconnected (as now, plus Log)", .disconnected(info: ["14:02", "Connection reset by 10.0.4.12 port 22"])),
        ("Reconnecting: the step it is on", .reconnecting(step: "checking the SSH configuration")),
        ("Password: ssh's prompt and a secure field, focused", .secret(prompt: "dev@build-box's password:", typed: 9)),
        ("Wrong password: ssh asks again; the field shakes and empties", .secret(prompt: "dev@build-box's password:", typed: 0, retry: true)),
        ("Key passphrase: a long prompt truncates in the middle", .secret(prompt: "Enter passphrase for key '/Users/dev/.ssh/id_ed25519_build':", typed: 14)),
        ("One-time code (keyboard-interactive): Show reveals what is typed", .secret(prompt: "Verification code:", typed: 6, reveal: true)),
        ("Security key: a notice, gone when the key answers", .touch(prompt: "Confirm user presence for key ED25519-SK SHA256:3kF9q2…")),
        ("Confirmation: Yes or No", .confirm(question: "Allow use of key /Users/dev/.ssh/id_ecdsa_sk? Fingerprint SHA256:Vb1x…")),
        ("Old ssh without SSH_ASKPASS_REQUIRE: answer in the log, which opens", .inLog),
        ("Tab gone from the server: what it showed stays, read-only; Close tab only", .gone),
        ("Connected (as now)", .connected),
    ]

    var reconnecting: Bool {
        switch self { case .disconnected, .gone, .connected: false; default: true }
    }
    var connected: Bool { if case .connected = self { true } else { false } }
}

/// SSHReconnectOverlay redrawn with the login in it: on glass the strip's track tinted amber, flat the full-width bar.
/// Reconnect leads while offered; the status mark and the label; the prompt's control; Log; Cancel or Close tab.
struct ReconnectStrip: View {
    let phase: ReconnectPhase
    var logOpen = false
    var host = "build-box"
    /// A narrow pane (a split): Log and Cancel as icons, the field gives way before ssh's prompt does.
    var compact = false
    private var t: AppTypography { Mock.typography }
    static let amber = Color(red: 217/255, green: 179/255, blue: 106/255)
    static let green = Color(red: 127/255, green: 211/255, blue: 161/255)
    static let ink = Color(red: 19/255, green: 19/255, blue: 21/255)
    static let grey = Color(red: 142/255, green: 142/255, blue: 150/255)
    private var color: Color { phase.connected ? Self.green : isGone ? Self.grey : Self.amber }

    var body: some View {
        let track = StripTab.glassTrackHeight(t)
        if Mock.glass {
            let margin = (t.expanded(38) - track) / 2
            row.frame(height: track)
                .background(Capsule().fill(color.opacity(0.1)))
                .background(Capsule().fill(GlassTone.track))
                .overlay(Capsule().strokeBorder(GlassTone.trackEdge, lineWidth: 0.5))
                .shadow(color: GlassTone.shadow, radius: 2, y: 1)
                .padding(.horizontal, Chrome.stripInset).padding(.top, margin)
                .frame(height: margin + track, alignment: .bottom)
        } else {
            row.padding(.horizontal, 6).frame(height: t.expanded(34))
                .background(ChatColors.current.window.mix(with: color, by: 0.09))
                .overlay(alignment: .bottom) { Rectangle().fill(color.opacity(0.3)).frame(height: 1) }
        }
    }

    private var icon: Font { .system(size: t.tabSize - 1, weight: .semibold) }

    private var row: some View {
        HStack(spacing: 8) {
            if offersReconnect {
                pill("Reconnect", symbol: "arrow.clockwise", key: "⏎")
            }
            Indicator(color: color, sweeping: phase.reconnecting)
                .padding(.leading, offersReconnect ? 0 : (Mock.glass ? 11 : 7))
            content
            Spacer(minLength: 0)
            if !phase.connected {
                if compact {
                    action(nil, symbol: "text.alignleft", lit: logOpen || isInLog)
                    action(nil, symbol: phase.reconnecting ? "stop.fill" : "xmark")
                } else {
                    if !isGone { action("Log", symbol: logOpen ? "chevron.up" : "chevron.down", lit: logOpen || isInLog, trailingSymbol: true) }
                    action(phase.reconnecting ? "Cancel" : "Close tab", symbol: phase.reconnecting ? "stop.fill" : "xmark")
                }
            }
        }
        .font(t.font(.label))
        .lineLimit(1)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .disconnected(let info):
            Text("\(host) disconnected").foregroundStyle(color).layoutPriority(1)
            Text(info.joined(separator: " · ")).foregroundStyle(Chrome.muted)
        case .reconnecting(let step):
            Text("reconnecting to \(host)").foregroundStyle(color).layoutPriority(1)
            Text(step).foregroundStyle(Chrome.muted)
        case .secret(let prompt, let typed, let retry, let reveal, let focused):
            Text(prompt).foregroundStyle(color).truncationMode(.middle).layoutPriority(2)
            SecretField(typed: typed, reveal: reveal, focused: focused, retry: retry, color: color)
            if retry { Text(compact ? "try again" : "Not accepted, try again").foregroundStyle(ChatColors.current.red) }
            else if focused && !compact { Text("⏎").foregroundStyle(Chrome.muted) }
        case .touch(let prompt):
            Image(systemName: "key.radiowaves.forward").font(icon).foregroundStyle(color)
            Text("Touch your security key").foregroundStyle(color).layoutPriority(1)
            Text(prompt).foregroundStyle(Chrome.muted).truncationMode(.middle)
        case .confirm(let question):
            Text(question).foregroundStyle(color).truncationMode(.middle).layoutPriority(1)
            pill("Yes", symbol: nil, key: "⏎")
            action("No", symbol: nil)
        case .inLog:
            Text("ssh is asking in the log").foregroundStyle(color).layoutPriority(1)
            Text("this ssh can't ask Dispatch").foregroundStyle(Chrome.muted)
        case .gone:
            Text("no longer on \(host)").foregroundStyle(color).layoutPriority(1)
            Text("its terminal ended there; what it showed stays here, read-only").foregroundStyle(Chrome.muted)
        case .connected:
            Text("connected").foregroundStyle(color)
            Text("session resumed").foregroundStyle(Chrome.muted)
        }
    }

    private var offersReconnect: Bool {
        switch phase { case .disconnected: true; default: false }
    }
    private var isGone: Bool { if case .gone = phase { true } else { false } }
    private var isInLog: Bool { if case .inLog = phase { true } else { false } }

    /// The primary action: on glass a tinted pill inside the track, flat a filled amber button.
    private func pill(_ title: String, symbol: String?, key: String?) -> some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(icon) }
            Text(title)
            if let key { Text(key).opacity(0.6) }
        }
        .foregroundStyle(Self.ink)
        .padding(.horizontal, 12)
        .frame(maxHeight: Mock.glass ? .infinity : t.expanded(22))
        .background(Capsule().inset(by: Mock.glass ? 2 : 0).fill(color))
        .fixedSize(horizontal: true, vertical: false)
    }

    /// A secondary action on the track's glass (flat: a bordered button), muted; lit in the accent while its panel shows.
    private func action(_ title: String?, symbol: String?, lit: Bool = false, trailingSymbol: Bool = false) -> some View {
        HStack(spacing: 5) {
            if let symbol, !trailingSymbol { Image(systemName: symbol).font(icon) }
            if let title { Text(title) }
            if let symbol, trailingSymbol { Image(systemName: symbol).font(.system(size: t.tabSize - 3, weight: .semibold)) }
        }
        .foregroundStyle(lit ? color : Chrome.muted)
        .padding(.horizontal, 10)
        .frame(maxHeight: Mock.glass ? .infinity : t.expanded(22))
        .background {
            if lit { Capsule().inset(by: Mock.glass ? 3 : 0).fill(color.opacity(0.14)) }
            else if !Mock.glass { RoundedRectangle(cornerRadius: 5).strokeBorder(ChatColors.current.border) }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// NSSecureTextField's look in the strip: a capsule inset in the track, the typed characters as dots, the caret and the
/// accent ring while focused; Show swaps the dots for the text (a one-time code).
private struct SecretField: View {
    let typed: Int
    var reveal = false
    var focused = true
    var retry = false
    let color: Color
    private var t: AppTypography { Mock.typography }
    var body: some View {
        HStack(spacing: 4) {
            if reveal {
                Text(String("482913".prefix(typed))).font(AppFont.code(size: t.tabSize)).foregroundStyle(Chrome.ink)
            } else {
                HStack(spacing: 3) {
                    ForEach(0..<typed, id: \.self) { _ in Circle().fill(Chrome.ink).frame(width: 5.5, height: 5.5) }
                }
            }
            if focused { Rectangle().fill(Chrome.accent).frame(width: 1.5, height: t.tabSize + 2) }
            Spacer(minLength: 0)
            Image(systemName: reveal ? "eye" : "eye.slash").font(.system(size: t.tabSize - 2)).foregroundStyle(Chrome.muted)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 80, idealWidth: 200, maxWidth: 200)
        .frame(maxHeight: Mock.glass ? .infinity : t.expanded(22))
        .background {
            let shape = Capsule().inset(by: Mock.glass ? 3 : 0)
            shape.fill(Chrome.palette.isDark ? Color.black.opacity(0.35) : Color.white.opacity(0.8))
                .overlay(shape.stroke(retry ? ChatColors.current.red : focused ? Chrome.accent.opacity(0.7) : ChatColors.current.border,
                                      lineWidth: focused || retry ? 1.5 : 1))
        }
        .offset(x: retry ? -3 : 0)
    }
}

/// The status mark: filled while offline or connected, a three-quarter ring while a login runs.
private struct Indicator: View {
    let color: Color
    let sweeping: Bool
    var body: some View {
        Group {
            if sweeping { Circle().trim(from: 0.125, to: 0.875).stroke(color, lineWidth: 1.5).rotationEffect(.degrees(40)) }
            else { Circle().fill(color) }
        }
        .frame(width: 8, height: 8).padding(1)
    }
}

/// The login's log under the strip: what Dispatch did (muted, with times) between ssh's own output (the login's
/// terminal, stderr and prompts), Source Code Pro. Copy at its top; the grabber resizes it, up to 40% of the pane.
struct ReconnectLog: View {
    let lines: [(time: String?, text: String, kind: Kind)]
    enum Kind { case step, ssh, problem, prompt }
    private var t: AppTypography { Mock.typography }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Login log · build-box").font(t, .caption, weight: .medium).foregroundStyle(Chrome.muted)
                Spacer()
                Text("Copy").font(t.font(.caption)).foregroundStyle(Chrome.muted)
            }
            .padding(.bottom, 6)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.time ?? "").foregroundStyle(Chrome.muted.opacity(0.7)).frame(width: 64, alignment: .leading)
                    Text(line.text).foregroundStyle(style(line.kind))
                }
                .font(AppFont.code(size: 12.5))
                .frame(height: 17, alignment: .leading)
            }
            Capsule().fill(Chrome.muted.opacity(0.5)).frame(width: 36, height: 4).frame(maxWidth: .infinity).padding(.top, 8)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        .background {
            RoundedRectangle(cornerRadius: Mock.glass ? 14 : 0)
                .fill(Mock.glass ? GlassTone.track : ChatColors.current.window)
                .overlay(RoundedRectangle(cornerRadius: Mock.glass ? 14 : 0).strokeBorder(GlassTone.trackEdge, lineWidth: Mock.glass ? 0.5 : 0))
                .shadow(color: GlassTone.shadow, radius: 4, y: 2)
        }
        .padding(.horizontal, Mock.glass ? Chrome.stripInset : 0).padding(.top, Mock.glass ? 6 : 0).padding(.bottom, 8)
    }
    private func style(_ kind: Kind) -> Color {
        switch kind {
        case .step: Chrome.muted
        case .ssh: Chrome.ink
        case .problem: ChatColors.current.red
        case .prompt: ReconnectStrip.amber
        }
    }
}

extension Sample {
    /// A tmux tab's saved output on build-box: the end-to-end run it was watching when the link dropped.
    static let restored: [TermLine] = [
        .prompt("npm run e2e -- --project=chromium", folder: "web", branch: "checkout-flow"),
        "",
        T("Running ", c(3, "38"), " tests using ", c(3, "4"), " workers"),
        "",
        T(c(2, "  ✓"), c(8, "  1 [chromium] › cart.spec.ts:12:5 › adds an item (1.2s)")),
        T(c(2, "  ✓"), c(8, "  2 [chromium] › cart.spec.ts:31:5 › removes the last item (0.9s)")),
        T(c(2, "  ✓"), c(8, "  3 [chromium] › checkout.spec.ts:8:5 › guest checkout (3.4s)")),
        T(c(1, "  ✘"), c(8, "  4 [chromium] › checkout.spec.ts:44:5 › applies a coupon (5.1s)")),
        T(c(2, "  ✓"), c(8, "  5 [chromium] › invoice.spec.ts:17:5 › rounds once per invoice (1.7s)")),
        T(c(2, "  ✓"), c(8, "  6 [chromium] › invoice.spec.ts:40:5 › zero-amount invoice (0.8s)")),
        "",
        T(c(1, "  1) [chromium] › checkout.spec.ts:44:5 › applies a coupon")),
        "",
        T("    Error: ", c(1, "expect(received).toHaveText(expected)")),
        T("    Expected: ", c(2, "\"Total €36.00\"")),
        T("    Received: ", c(1, "\"Total €40.00\"")),
        "",
        T(c(1, "  1 failed")),
        T(c(2, "  37 passed"), " (41.6s)"),
        .prompt(folder: "web", branch: "checkout-flow"),
    ]

    /// The login's log: Dispatch's steps, then ssh's output with a refused password and its prompt again.
    static let loginLog: [(time: String?, text: String, kind: ReconnectLog.Kind)] = [
        ("14:02:07", "connection lost (no exit status)", .step),
        ("14:31:40", "Reconnect: checking the SSH configuration (ssh -G build-box, 2 invocations)", .step),
        ("14:31:40", "ssh -f -N build-box  ·  master s-7c41d2e9a0f3", .step),
        (nil, "dev@build-box's password:", .prompt),
        (nil, "Permission denied, please try again.", .problem),
        (nil, "dev@build-box's password:", .prompt),
    ]
}
