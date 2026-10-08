import SwiftUI

struct ChatView: View {
    private var theme: ChatTheme { ChatThemeStore.shared.current }
    @Bindable var session: ChatSession
    let coordinator: ChatCoordinator
    let focused: Bool
    let floatingSwitch: Bool
    var workspace: Workspace?
    /// A glass tab strip over the pane's top: the transcript scrolls under it, other content starts below it.
    var topInset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var availableChatHeight: CGFloat = 800
    @State private var optionHeld = false
    @State private var queueTipPresented = false
    @State private var floatingInputHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if session.search.visible {
                HStack { Spacer(minLength: 0); ContentSearchBar(search: session.search, focused: focused) }
                    .padding(.top, topInset)
            }
            if session.hasConversation {
                // The transcript keeps one place in the tree in both modes: toggling Liquid Glass must not remount it,
                // or it would come back scrolled to its first message. Only the input moves.
                let glass = LiquidGlassStore.shared.active
                // Glass needs something behind it: the transcript scrolls under the floating input.
                transcript(bottomInset: glass ? floatingInputHeight : 0)
                    .overlay(alignment: .bottom) {
                        if glass {
                            input.background {
                                // Unfocused while the agent works, the composer hides its glass pill and the bare
                                // activity row would float over the transcript: back the input with the pane's own
                                // color, nearly opaque, as without glass.
                                theme.terminal.opacity(!focused && AgentWorkingState.isWorking(session) ? 0.92 : 0)
                                    .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.18), value: focused)
                            }
                            .background(GeometryReader { proxy in
                                Color.clear.onAppear { floatingInputHeight = proxy.size.height }
                                    .onChange(of: proxy.size.height) { _, height in floatingInputHeight = height }
                            })
                        }
                    }
                if !glass { input }
            } else {
                ContentUnavailableView("Agent chat", systemImage: "text.bubble", description:
                    Text("Enable Agent chat in Settings, start \(coordinator.agents) in this terminal, and finish any startup menus. Then select Chat to send your first message."))
                    .task { coordinator.loadLaunches() }
                    .padding(.top, topInset)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(GeometryReader { geometry in
            Color.clear.onAppear { availableChatHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in availableChatHeight = height }
        })
        .background(theme.terminal)
        .foregroundStyle(theme.ink).tint(theme.blue)
        .environment(\.chatTheme, theme)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .font(theme.typography.body)
        .environment(\.sshSource, session.helper?.endpoint.connection.map { id in
                SSHSourceContext(id: id) { try await $0.source(in: $1, endpoint: .remote(id)) }
            })
        .onTapGesture { (workspace ?? TerminalRuntime.shared.workspace)?.selectSurface(session.id) }
        .onChange(of: session.showChat) { _, visible in
            if !visible { session.modelPicker?.abandon(); session.modelPicker = nil; session.shortcutsPresented = false }
        }
        .onChange(of: focused) { _, focused in if !focused { session.shortcutsPresented = false } }
        .onChange(of: session.search.visible) { _, visible in
            if !visible, focused { session.focusRequest = UUID() }
        }
        .onChange(of: session.shortcutsPresented) { _, shown in if !shown { session.focusRequest = UUID() } }
        .onChange(of: session.queuedMessages.count) { old, count in
            if count > old && !coordinator.queueTipShown { queueTipPresented = true; coordinator.queueTipShown = true }
        }
        .onAppear { optionHeld = NSEvent.modifierFlags.contains(.option) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in optionHeld = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in optionHeld = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            optionHeld = NSEvent.modifierFlags.contains(.option)
        }
        .accessibilityIdentifier("chat-\(session.id)")
        .transaction { transaction in
            if #available(macOS 15, *) {
                // ChatScrollPosition owns the visible message's pixel offset.
                // Include parent layout and later lazy-row updates, not only
                // the transaction that inserts older history.
                transaction.scrollContentOffsetAdjustmentBehavior = .disabled
            }
        }
    }

    private func transcript(bottomInset: CGFloat) -> some View {
        ChatTranscriptView(session: session, coordinator: coordinator, topContentInset: (floatingSwitch ? 38 : 0) + (session.search.visible ? 0 : topInset),
                           bottomContentInset: bottomInset, fadeTopInset: session.search.visible ? 0 : topInset)
            .opacity(session.sideConversation == nil ? 1 : 0.38)
            .animation(InterfaceMotion.animation(reduce: reduceMotion), value: session.sideConversation?.id)
    }

    private var canSubmit: Bool {
        if !session.draftIsCommand || session.busy || session.editingQueuedID != nil {
            return coordinator.enabled && session.active && session.supportsQueue && !session.inputBlocked
                && session.helper != nil
                && session.drafts.shape.hasText
                && (session.queuedMessages.count < 50 || session.editingQueuedID != nil)
        }
        return session.active && session.submissionID == nil && session.modelPicker == nil && session.command == nil
            && !session.nativeInputInFlight && session.nativePrompt == nil && session.commandEditor == nil && !session.inputBlocked && !session.loadingHistory
            && session.activityCheck == nil && (!session.busy || session.drafts.shape.commandAllowsBusy) && session.drafts.shape.hasText
            && !session.approvals.contains(where: \.pending)
    }

    @ViewBuilder private var input: some View {
        let content = inputContent
            .animation(InterfaceMotion.animation(reduce: reduceMotion), value: session.sideConversation?.id)
        if LiquidGlassStore.shared.active {
            // No panel around the whole input: the composer's own frame is the glass (ChatComposerFocusChrome),
            // so its working border runs on the glass edge, and bare rows above it carry their own small panels.
            // No GlassEffectContainer: it would draw the composer's background glass over the editor's text.
            // The bottom matches the glass sidebar's inset, so the composer and the sidebar panel end level.
            content
                .padding(.horizontal, Chrome.paneContentInset).padding(.top, 10).padding(.bottom, SpaceSidebar.glassInset)
                .frame(maxWidth: .infinity)
        } else {
            content.padding(.horizontal, Chrome.paneContentInset).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
        }
    }

    private var inputContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.sideConversation == nil && (!session.questions.isEmpty || session.command != nil || session.commandEditor != nil || session.nativePrompt != nil || session.commandResult != nil) {
                ChatCommandControls(session: session, coordinator: coordinator)
            }
            if session.sideConversation != nil || session.loadingHistory {
                AgentWorkingIndicator(session: session, canStop: coordinator.canInterrupt(session)) {
                    coordinator.interrupt(session)
                }.floatingGlassPanel()
            }
            if let status = session.status, TerminalRuntime.shared.hosts.reconnect.state(for: session.id) == nil {
                HStack {
                    Text(status).font(theme.typography.detail).foregroundStyle(theme.muted)
                    Spacer(minLength: 4)
                    if session.terminalAttention != nil {
                        Button("Retry chat") { coordinator.retryChat(session) }
                    }
                    Button("Open in terminal") { coordinator.chooseChat(false, session: session) }
                }.floatingGlassPanel()
            }
            if let side = session.sideConversation {
                ChatSideSheet(side: side, close: { coordinator.closeSideConversation(session) }, maximumHeight: availableChatHeight * 0.55,
                              shortcutsEnabled: focused && session.showChat)
                    .transition(reduceMotion ? .opacity : .offset(y: 10).combined(with: .opacity))
            } else {
                if !session.queuedMessages.isEmpty {
                    ChatQueueView(session: session, coordinator: coordinator,
                                  maximumHeight: session.queuedMessages.count == 1
                                      ? availableChatHeight * 0.55 : min(180, availableChatHeight * 0.3))
                        .floatingGlassPanel()
                }
                if !matchingCommands.isEmpty { commands }
                if queueTipPresented {
                    HStack(alignment: .top, spacing: 8) {
                        Text("Queued messages run after this turn. Use ⌥⏎ to steer: interrupt and redirect the current turn.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button { queueTipPresented = false } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss queue tip")
                    }.font(theme.typography.detail).foregroundStyle(theme.muted)
                        .modifier(QueueTipSurface()).accessibilityIdentifier("chat-queue-tip")
                }
                VStack(spacing: 6) {
                    // Unfocused, only the footer's activity can stay (agentWorking); the editor and details hide.
                    Group {
                        if let id = session.editingQueuedID, let index = session.queuedMessages.firstIndex(where: { $0.id == id }) {
                            HStack {
                                Text("editing queued \(index + 1)")
                                Spacer()
                                Button("cancel") { coordinator.cancelQueuedEdit(session) }.buttonStyle(.plain)
                            }.font(theme.typography.detail).foregroundStyle(theme.muted).padding(.horizontal, 12).padding(.top, 6)
                        }
                        ChatComposer(session: session, focused: focused && session.showChat, submit: { coordinator.sendFromComposer(session) },
                            interrupt: {
                                if session.editingQueuedID != nil { coordinator.cancelQueuedEdit(session); return true }
                                return coordinator.interrupt(session)
                            },
                            exitChat: { coordinator.quitFromChat(session) },
                            exitPrompt: {
                                coordinator.quitCommand(session) == nil ? "Press Ctrl+D again to show Terminal"
                                    : "Press Ctrl+D again to quit \(session.agentTitle)"
                            },
                            pickModel: { coordinator.openModelPicker(session, column: $0, cycle: $1) }, workspace: workspace,
                            sendNow: { coordinator.sendNow(session) },
                            queueAction: { id, action in
                                switch action {
                                case "send": coordinator.sendNow(session, queuedID: id)
                                case "edit": coordinator.editQueued(id, in: session)
                                default: coordinator.removeQueued(id, from: session)
                                }
                            }, optionChanged: { optionHeld = $0 }, showShortcuts: { session.shortcutsPresented.toggle() })
                            .frame(height: min(max(theme.typography.replyLineHeight + 10, session.composerHeight), max(theme.typography.replyLineHeight + 10, min(320, availableChatHeight * 0.4) - theme.typography.detailLineHeight - 26)))
                            .overlay(alignment: .topTrailing) {
                                if session.drafts.shape.multiline {
                                    Text("editor")
                                        .font(theme.typography.detail)
                                        .foregroundStyle(theme.terminal)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(theme.accent, in: RoundedRectangle(cornerRadius: 4))
                                        .padding(.trailing, 12).padding(.top, 5)
                                        .allowsHitTesting(false)
                                        .accessibilityIdentifier("chat-editor-mode")
                                }
                            }
                        composerDetails
                    }
                    .opacity(focused ? 1 : 0).allowsHitTesting(focused)
                    composerFooter.font(theme.typography.detail)
                        .padding(.horizontal, 12).padding(.top, 8)
                        .padding(.bottom, 9)
                        // While the agent works, an unfocused pane keeps "thinking" exactly where the focused footer
                        // shows it, so moving focus never moves it.
                        .opacity(focused || agentWorking ? 1 : 0)
                        .offset(y: focused || agentWorking || reduceMotion ? 0 : 6)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18).delay(focused ? 0.1 : 0), value: focused)
                }.padding(.top, 4)
                    .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.14), value: focused)
                    .allowsHitTesting(focused || agentWorking)
                    .accessibilityHidden(!focused && !agentWorking)
                    .background {
                        ChatComposerFocusChrome(session: session, focused: focused,
                                                lineHeight: theme.typography.replyLineHeight + 14, buttonInset: replyButtonInset)
                    }
                    .overlay(alignment: .topLeading) {
                        if !focused { inactiveComposer.transition(.identity) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !focused && !agentWorking && LiquidGlassStore.shared.active {
                            glassReplyButton.padding(.trailing, replyButtonInset.width).padding(.bottom, replyButtonInset.height)
                                .transition(.identity)
                        }
                    }
            }
        }
    }

    // Reserve the mounted editor's footprint so focusing another pane neither
    // shifts the Reply baseline nor moves the transcript being read.
    /// Whether the agent's activity shows in the composer footer, which an unfocused pane keeps in place.
    private var agentWorking: Bool { AgentWorkingState.isWorking(session) }

    @ViewBuilder private var inactiveComposer: some View {
        if agentWorking {
            // The footer below shows the activity in place; the Reply line stays empty meanwhile.
        } else if LiquidGlassStore.shared.active {
            // On glass the reply button sits bottom-trailing instead (glassReplyButton); the Reply line stays empty.
        } else {
            inactiveRow
        }
    }

    /// On glass, the unfocused reply button: centered on the footer row where Send sits, on the same row as the
    /// working activity. Its glass (ChatComposerFocusChrome) grows from this corner into the composer on focus,
    /// and the rest of the input lets clicks through to the transcript.
    private var glassReplyButton: some View {
        let size = theme.typography.replyLineHeight + 14
        return Button {
            (workspace ?? TerminalRuntime.shared.workspace)?.selectSurface(session.id)
            session.focusRequest = UUID()
        } label: {
            Image(systemName: "arrowshape.turn.up.left").font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(theme.muted)
                .frame(width: size, height: size).contentShape(Circle())
        }.buttonStyle(.plain).help("Reply").accessibilityLabel("Reply in this pane")
            .accessibilityIdentifier("chat-inactive-composer")
    }

    /// From the composer's bottom-trailing corner to the reply button: past the composer's inset to the tab strip's,
    /// so it lines up with the strip's trailing button above, and centered on the footer row (its bottom padding
    /// plus half its height).
    private var replyButtonInset: CGSize {
        let size = theme.typography.replyLineHeight + 14
        let rowCenter = 9 + max(24, theme.typography.detailLineHeight) / 2
        return CGSize(width: Chrome.stripInset - Chrome.paneContentInset, height: max(0, rowCenter - size / 2))
    }

    private var inactiveRow: some View {
        Button {
            (workspace ?? TerminalRuntime.shared.workspace)?.selectSurface(session.id)
            session.focusRequest = UUID()
        } label: {
            Text("Reply…").font(Font(theme.typography.reply))
                .foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Reply in this pane")
        .padding(.horizontal, 12)
        .frame(height: theme.typography.replyLineHeight + 10)
        .padding(.top, 4)
        .accessibilityIdentifier("chat-inactive-composer")
    }

    private var composerFooter: some View {
        let hasActivity = agentWorking
        return ViewThatFits(in: .horizontal) {
            composerFooterRow(compactEffort: false)
            if hasActivity {
                composerFooterRow(compactEffort: true)
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            modelControls(compactEffort: hasActivity).fixedSize().focusedOnly(focused)
                            ChatComposerActivity(session: session, active: focused || agentWorking).fixedSize()
                        }
                    }.scrollIndicators(.hidden).frame(height: max(24, theme.typography.detailLineHeight))
                    composerStop
                }
                HStack(spacing: 12) {
                    savedDraftControls
                    Spacer(minLength: 0)
                    replyActions
                }.focusedOnly(focused)
            }
        }
    }

    private func composerFooterRow(compactEffort: Bool) -> some View {
        HStack(spacing: 12) {
            modelControls(compactEffort: compactEffort).fixedSize().focusedOnly(focused)
            composerActivity.fixedSize()
            savedDraftControls.focusedOnly(focused)
            Spacer(minLength: 0)
            replyActions.focusedOnly(focused)
        }
    }

    @ViewBuilder private var savedDraftControls: some View {
        if session.drafts.shape.hasSaved || !session.drafts.recoverable.isEmpty {
            ChatDraftControls(session: session).frame(maxWidth: 220, alignment: .leading)
        }
    }

    private func modelControls(compactEffort: Bool) -> some View {
        HStack(spacing: 7) {
            ChatModelControls(session: session, coordinator: coordinator, focused: focused && session.showChat && !session.drafts.shape.multiline,
                              compactEffort: compactEffort)
            if session.goal != nil {
                Text("·").accessibilityHidden(true)
                ChatGoalControls(session: session, coordinator: coordinator)
            }
        }.lineLimit(1).truncationMode(.middle)
            .foregroundStyle(theme.muted.opacity(0.65))
    }

    private var composerActivity: some View {
        HStack(spacing: 8) {
            ChatComposerActivity(session: session, active: focused || agentWorking)
            composerStop
        }
    }

    @ViewBuilder private var composerStop: some View {
        if agentWorking {
            Button { coordinator.interrupt(session) } label: {
                Image(systemName: "stop.fill").font(.system(size: 7))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(theme.muted)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.border))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!coordinator.canInterrupt(session))
                .help(session.interruptionID == nil ? "Stop agent · ⎋ · Draft kept" : "Stopping…")
                .accessibilityLabel("Stop agent").accessibilityIdentifier("chat-stop")
        }
    }

    private var replyActions: some View {
        HStack(spacing: 8) {
            ChatComposerShortcuts(session: session, presented: $session.shortcutsPresented)
            ChatReplyButton(canSubmit: canSubmit, optionHeld: optionHeld, busy: session.busy,
                            editingQueued: session.editingQueuedID != nil, multiline: session.drafts.shape.multiline,
                            command: session.draftIsCommand) {
                if optionHeld { coordinator.sendNow(session) }
                else { coordinator.sendFromComposer(session) }
            }
        }
    }

    @ViewBuilder private var composerDetails: some View {
        if session.drafts.repository.error != nil || session.collaborationMode == "plan"
            || session.serviceTier == "priority"
            || (session.activityCheck != nil && session.status == nil) {
            VStack(alignment: .leading, spacing: 8) {
                if let error = session.drafts.repository.error {
                    HStack {
                        Text(error).font(theme.typography.detail).foregroundStyle(theme.red)
                        Button("Retry saving") { session.drafts.persist(flush: true) }
                    }
                }
                sessionReadout.font(theme.typography.detail).foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 12)
        }
    }

    private var sessionReadout: some View {
        HStack(spacing: 8) {
            if session.collaborationMode == "plan" { Text("Plan mode").foregroundStyle(theme.blue) }
            if session.serviceTier == "priority" { Text("Fast").foregroundStyle(theme.blue) }
            if session.activityCheck != nil && session.status == nil { Text("Checking \(session.agentTitle) activity…") }
        }
    }

    private var matchingCommands: [String] { session.matchingCommands }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.active ? "\(session.agentTitle) commands" : "Local command")
                .font(theme.typography.detail).foregroundStyle(theme.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(matchingCommands, id: \.self) { command in
                        Button { session.commandSelection = matchingCommands.firstIndex(of: command) ?? 0; session.completeCommand() } label: {
                            HStack(spacing: 12) {
                                Text(command).frame(width: 106, alignment: .leading)
                                Text(commandDescription(command)).foregroundStyle(theme.muted)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 8).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(matchingCommands.firstIndex(of: command) == min(session.commandSelection, matchingCommands.count - 1) ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: min(220, CGFloat(matchingCommands.count) * 32))
        }.padding(6).frame(maxWidth: .infinity, alignment: .leading).chatPanel()
    }
    private func commandDescription(_ command: String) -> String {
        switch command {
        case "/btw": "ask a read-only side question · kept out of this thread"
        case "/side": "open a side conversation · full permissions"
        case "/terminal": "show the live terminal"
        case "/model": "switch model or effort"
        case "/hooks": "review configured hooks"
        case "/permissions": "configure agent permissions"
        case "/resume": "resume a saved conversation"
        case "/compact": "summarize context"
        case "/status": "view session information"
        case "/fast": "toggle Fast mode"
        case "/rename": "rename this conversation"
        case "/init": "create repository instructions"
        case "/review": "review changes"
        case "/stop": "stop background terminals"
        case "/copy": "copy the latest response"
        case "/plan": "plan before implementing"
        case "/goal": "view or set a persistent goal"
        case "/clear", "/new": "start a fresh conversation"
        case "/fork": "continue in a copy of this conversation"
        case "/pwd": "show the working directory"
        case "/ps": "list background terminals"
        case "/mcp": "list MCP tools"
        case "/recap": "summarize this conversation"
        case "/help": "show available commands"
        default: "open in terminal"
        }
    }
}

struct ChatSessionStats: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession

    var body: some View {
        HStack(spacing: 10) {
            if let fraction = session.usage?.contextRemaining {
                HStack(spacing: 6) {
                    GeometryReader { geometry in
                        Capsule().fill(theme.border)
                        Capsule().fill(theme.yellow).frame(width: geometry.size.width * fraction)
                    }.frame(width: 36, height: 4)
                    Text("\(Int(fraction * 100))%").foregroundStyle(theme.yellow)
                }.help("Context window remaining")
                    .accessibilityLabel("\(Int(fraction * 100)) percent context remaining")
            }
            if let usage = session.usage {
                Text("(\(count(usage.input)) in, \(count(usage.output)) out)")
                    .help("Cumulative session tokens")
            } else { Text("Usage unavailable").help("Waiting for agent-reported session usage") }
        }.font(theme.typography.detail).foregroundStyle(theme.muted)
            .fixedSize(horizontal: true, vertical: false).accessibilityIdentifier("chat-session-stats")
    }
    private func count(_ value: Int?) -> String {
        guard let value else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
}

private extension View {
    /// Footer parts that only the focused composer shows; an unfocused pane keeps just the activity.
    func focusedOnly(_ focused: Bool) -> some View { opacity(focused ? 1 : 0).allowsHitTesting(focused) }
}

/// The queue tip floats like the other status rows on glass; otherwise it is the bordered chat panel.
private struct QueueTipSurface: ViewModifier {
    func body(content: Content) -> some View {
        if LiquidGlassStore.shared.active { content.floatingGlassPanel() } else { content.padding(10).chatPanel() }
    }
}
