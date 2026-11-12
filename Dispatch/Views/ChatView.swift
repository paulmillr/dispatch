import Dictation
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
    @State private var chatWidth: CGFloat = 0
    @State private var alternateSendHeld = false
    @State private var queueTipPresented = false
    @State private var floatingInputHeight: CGFloat = 0
    /// The footer's activity, shared by every variant of its `ViewThatFits` (`ChatComposerActivityState`).
    @State private var activity = ChatComposerActivityState()

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
                ContentUnavailableView("Chat", systemImage: "text.bubble", description:
                    Text(coordinator.emptyChatHint(local: localTab)))
                    .task { coordinator.loadLaunches() }
                    .padding(.top, topInset)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // Files and images dropped anywhere on the pane attach to the draft, as on the composer; while they are dragged
        // over it the composer grows to the pane's top to take them (ChatComposerDropWell).
        .onDrop(of: [.fileURL, .image], delegate: ChatAttachmentDrop(session: session, coordinator: coordinator))
        .background(GeometryReader { geometry in
            Color.clear.onAppear { availableChatHeight = geometry.size.height; chatWidth = geometry.size.width }
                .onChange(of: geometry.size.height) { _, height in availableChatHeight = height }
                .onChange(of: geometry.size.width) { _, width in chatWidth = width }
        })
        // A sent message flies from the composer to its bubble or queue row over everything else.
        .overlay(alignment: .topLeading) {
            ChatSendFlightLayer(session: session,
                                bubbleWidth: ChatUserMessage.maxWidth(max(0, chatWidth - 44), characterWidth: theme.typography.characterWidth))
        }
        .coordinateSpace(.named(ChatFlightFrames.space))
        .background(ChatFlightCoordinateRoot(frames: session.flightFrames))
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
        .onAppear { activity.bind(session) }
        .onChange(of: session.search.visible) { _, visible in
            if !visible, focused { session.focusRequest = System.uuid() }
        }
        .onChange(of: session.shortcutsPresented) { _, shown in if !shown { session.focusRequest = System.uuid() } }
        .onChange(of: session.queuedMessages.count) { old, count in
            if count > old && !coordinator.queueTipShown { queueTipPresented = true; coordinator.queueTipShown = true }
        }
        .onAppear { alternateSendHeld = ChatEditorTextView.usesAlternateSend(NSEvent.modifierFlags) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in alternateSendHeld = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in alternateSendHeld = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            alternateSendHeld = ChatEditorTextView.usesAlternateSend(NSEvent.modifierFlags)
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
            // Attachments alone make a message; one still uploading would be left out (a command takes none).
            return coordinator.enabled && session.active && session.supportsQueue && !session.inputBlocked
                && session.helper != nil
                && (session.drafts.shape.hasText || session.drafts.shape.hasAttachments)
                && !(session.draftIsCommand && session.drafts.shape.hasAttachments)
                && !session.draftUploads.contains(where: \.uploading)
                && (session.queuedMessages.count < 50 || session.editingQueuedID != nil)
        }
        return session.active && session.submissionID == nil && session.modelPicker == nil && session.command == nil
            && !session.nativeInputInFlight && session.nativePrompt == nil && session.commandEditor == nil && !session.inputBlocked && !session.loadingHistory
            && session.activityCheck == nil && (!session.busy || session.drafts.shape.commandAllowsBusy) && session.drafts.shape.hasText
            && !session.drafts.shape.hasAttachments && !session.approvals.contains(where: \.pending)
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
                // Usually inserted with its first content (a result, a running command), which then can't make its
                // own entrance: the controls make it.
                ChatCommandControls(session: session, coordinator: coordinator)
                    .transition(ChatCommandControls.entrance(reduceMotion))
            }
            if session.sideConversation != nil || session.loadingHistory {
                AgentWorkingIndicator(session: session, canStop: coordinator.canInterrupt(session)) {
                    coordinator.interrupt(session)
                }.floatingGlassPanel()
            }
            if let status = session.status, !TerminalRuntime.shared.hosts.reconnect.showsBar(for: session.id) {
                HStack {
                    // Nautical calls a failure or a pane stuck on its terminal a MAYDAY.
                    if theme.radioLog && (session.terminalAttention != nil || HarbourDistress.isFailure(status)) {
                        ChatRadioLog.tag("MAYDAY", color: theme.red, theme: theme)
                    }
                    Text(status).font(theme.typography.detail).foregroundStyle(theme.muted)
                    Spacer(minLength: 4)
                    if session.terminalAttention != nil {
                        Button("Retry Chat") { coordinator.retryChat(session) }
                    }
                    if session.statusOffersTerminal {
                        Button("Open in Terminal") { coordinator.showTerminal(session) }
                    }
                    // A refused send's reason stays until the next attempt; it can be dismissed sooner.
                    if session.terminalAttention == nil, session.submissionFailure != nil {
                        Button { session.submissionFailure = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(theme.muted).help("Dismiss")
                            .accessibilityLabel("Dismiss message").accessibilityIdentifier("chat-status-dismiss")
                    }
                }.floatingGlassPanel()
            }
            if let notice = session.terminalPromptNotice, !TerminalRuntime.shared.hosts.reconnect.showsBar(for: session.id) {
                HStack {
                    Text(notice).font(theme.typography.detail).foregroundStyle(theme.muted).lineLimit(2)
                    Spacer(minLength: 4)
                    Button("Clear") { coordinator.clearTerminalPrompt(session) }.disabled(session.clearingTerminalPrompt)
                    Button("Open in Terminal") { coordinator.showTerminal(session) }
                }.floatingGlassPanel()
            }
            if let side = session.sideConversation {
                ChatSideSheet(side: side, close: { coordinator.closeSideConversation(session) }, maximumHeight: availableChatHeight * 0.55,
                              shortcutsEnabled: focused && session.showChat)
                    .transition(reduceMotion ? .opacity : .offset(y: 10).combined(with: .opacity))
            } else {
                // The panel opens with the first queued message and folds shut after the last, so the transcript
                // above moves with it instead of jumping.
                ChatInputFold(present: !session.queuedMessages.isEmpty, spacing: 8, reduceMotion: reduceMotion) {
                    // Every message in it flew out to its bubble and is sending: the panel fades rather than
                    // standing empty until the agent confirms.
                    let emptied = session.queuedMessages.allSatisfy {
                        session.queuedSubmissionID == $0.id && session.flownQueuedIDs.contains($0.id)
                    }
                    ChatQueueView(session: session, coordinator: coordinator, maximumHeight: min(180, availableChatHeight * 0.3))
                        .modifier(ChatQueueSurface())
                        .opacity(emptied ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: emptied)
                }
                if !matchingCommands.isEmpty { commands }
                ChatInputFold(present: queueTipPresented, spacing: 8, reduceMotion: reduceMotion) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(coordinator.sendWhileWorking == .steer
                             ? "Queued messages run after this turn. ⏎ steers: it adds your message to the current turn now."
                             : "Queued messages run after this turn. Use ⌥⌘⏎ to steer: add your message to the current turn now.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button { queueTipPresented = false } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss queue tip")
                    }.font(theme.typography.detail).foregroundStyle(theme.muted)
                        .modifier(QueueTipSurface()).accessibilityIdentifier("chat-queue-tip")
                }
                VStack(spacing: 6) {
                    // Unfocused, the editor and details stay only while they hold a draft (composerShown); the footer only its activity.
                    Group {
                        if let id = session.editingQueuedID, let index = session.queuedMessages.firstIndex(where: { $0.id == id }) {
                            HStack {
                                Text("Editing queued message \(index + 1)")
                                Spacer()
                                Button("Cancel") { coordinator.cancelQueuedEdit(session) }.buttonStyle(.plain)
                            }.font(theme.typography.detail).foregroundStyle(theme.muted).padding(.horizontal, 12).padding(.top, 6)
                        }
                        // The first chip opens its row and the last one closes it, the composer growing and shrinking
                        // with it rather than jumping.
                        ChatInputFold(present: attachmentsShown, spacing: 6, reduceMotion: reduceMotion) {
                            ChatComposerAttachments(session: session, coordinator: coordinator)
                        }
                        ChatComposer(session: session, focused: focused && session.showChat, submit: { coordinator.sendFromComposer(session, alternate: false) },
                            interrupt: { time in
                                if session.editingQueuedID != nil { coordinator.cancelQueuedEdit(session); return true }
                                return coordinator.escapeStop(session, at: time)
                            },
                            canStop: { coordinator.canInterrupt(session) },
                            exitChat: { coordinator.quitFromChat(session) },
                            exitPrompt: {
                                coordinator.quitCommand(session) == nil ? "Press Ctrl+D again to show Terminal"
                                    : "Press Ctrl+D again to close tab and quit \(session.agentTitle)"
                            },
                            pickModel: { coordinator.openModelPicker(session, column: $0, cycle: $1) }, workspace: workspace,
                            sendNow: { coordinator.sendFromComposer(session, alternate: true) },
                            queueAction: { id, action in
                                switch action {
                                case "send": coordinator.sendNow(session, queuedID: id)
                                case "edit": coordinator.editQueued(id, in: session)
                                default: coordinator.removeQueued(id, from: session)
                                }
                            }, alternateSendChanged: { alternateSendHeld = $0 }, showShortcuts: { session.shortcutsPresented.toggle() },
                            canAttach: { coordinator.canAttach(session) }, attach: { coordinator.attach($0, to: session) },
                            chooseAttachments: { ChatAttachButton.choose(session: session, coordinator: coordinator, window: $0) })
                            .background(ChatFlightAnchor(place: .composer, frames: session.flightFrames))
                            // The attachment chips share the composer's bound: the editor gives up their height.
                            .frame(height: min(max(theme.typography.replyLineHeight + 10, session.composerHeight), max(theme.typography.replyLineHeight + 10, min(320, availableChatHeight * 0.4) - theme.typography.detailLineHeight - 26
                                - (attachmentsShown ? ChatComposerAttachments.height(session, theme: theme) : 0))))
                            // Emptied (a message sent, the text cleared), the editor gives its lines back smoothly;
                            // typing resizes it at once.
                            .animation(session.drafts.shape.isEmpty ? InterfaceMotion.animation(reduce: reduceMotion, duration: 0.24) : nil,
                                       value: session.composerHeight)
                            .overlay(alignment: .topTrailing) {
                                if session.drafts.shape.multiline {
                                    Text(ChatComposer.badgeTitle)
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
                    .opacity(composerShown ? 1 : 0).allowsHitTesting(focused)
                    .overlay {
                        // A kept draft reads in place; a click on it focuses this pane's composer.
                        if !focused && composerShown {
                            Color.clear.contentShape(Rectangle()).onTapGesture { replyHere() }
                                .accessibilityHidden(true)
                        }
                    }
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
                    .allowsHitTesting(composerShown || agentWorking)
                    .accessibilityHidden(!composerShown && !agentWorking)
                    .modifier(ChatComposerDropWell(drag: session.attachmentDrag, top: topInset + 12, host: dropHost,
                                                   attached: session.drafts.current.attachments.count + session.draftUploads.filter(\.uploading).count) {
                        ChatComposerFocusChrome(session: session, focused: focused, shown: composerShown,
                                                lineHeight: theme.typography.replyLineHeight + 14, buttonInset: replyButtonInset)
                    })
                    .overlay(alignment: .topLeading) {
                        if !composerShown { inactiveComposer.transition(.identity) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !composerShown && !agentWorking && LiquidGlassStore.shared.active {
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

    /// The composer stays open unfocused while it holds a draft (text or attachments), so moving to another split
    /// never hides what was typed; empty, it folds to the Reply line or button. Files dragged over the pane open it too.
    private var composerShown: Bool { focused || session.drafts.shape.hasText || attachmentsShown || session.attachmentDrag?.active == true }

    /// A tab on this Mac, whose agents' hooks Settings › Hosts › This Mac sets up.
    private var localTab: Bool {
        (workspace ?? TerminalRuntime.shared.workspace)?.hosts.terminals[session.id].map { $0.host == .local } ?? true
    }

    /// The remote host a drop is uploaded to, read only while files are dragged over the pane; nil on this Mac.
    private var dropHost: HostRecord? {
        guard session.attachmentDrag != nil, let hosts = (workspace ?? TerminalRuntime.shared.workspace)?.hosts,
              let context = hosts.terminals[session.id], context.host != .local else { return nil }
        return hosts.record(context.host)
    }

    private func replyHere() {
        (workspace ?? TerminalRuntime.shared.workspace)?.selectSurface(session.id)
        session.focusRequest = System.uuid()
    }

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
            session.focusRequest = System.uuid()
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
            session.focusRequest = System.uuid()
        } label: {
            Text(theme.radioLog ? "Transmit on \(HarbourRadio.channel(for: session.id))…" : "Reply…").font(Font(theme.typography.reply))
                .foregroundStyle(theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Reply in this pane")
        .padding(.horizontal, 12)
        .frame(height: theme.typography.replyLineHeight + 10)
        .padding(.top, 4)
        .accessibilityIdentifier("chat-inactive-composer")
    }

    /// One row with everything, or one row with every optional item folded at once; past `.compact` the same items
    /// take two rows. What folds keeps its help and shortcut.
    private enum FooterDensity {
        /// Everything, in words.
        case full
        /// Send without its keycap, no ⌘/ chip (the shortcut still opens its sheet), effort as its meter, the activity
        /// as orbit and time, drafts as an icon and count, and a model name truncated in the middle.
        case compact
    }

    private var composerFooter: some View {
        ViewThatFits(in: .horizontal) {
            composerFooterRow(.full)
            composerFooterRow(.compact)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            modelControls(.compact).fixedSize().focusedOnly(focused)
                            HStack(spacing: 8) { agentStatus(.compact) }.fixedSize()
                        }
                    }
                    // Never, not hidden: with scroll bars shown always (no trackpad) hidden still draws one.
                    .scrollIndicators(.never).frame(height: max(24, theme.typography.detailLineHeight))
                    stopControls
                }
                HStack(spacing: 12) {
                    savedDraftControls(.compact).focusedOnly(focused)
                    Spacer(minLength: 0)
                    trailingControls(.compact)
                }
            }
        }
    }

    /// The spacer alone separates the two ends: as an item of the leading stack it would add the spacing twice.
    private func composerFooterRow(_ density: FooterDensity) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                modelControls(density).fixedSize().focusedOnly(focused)
                // Only with something in it: an empty stack would still take the row's spacing.
                if showsAgentStatus {
                    HStack(spacing: 8) {
                        agentStatus(density)
                        stopControls
                    }.fixedSize()
                }
                savedDraftControls(density).focusedOnly(focused)
            }
            Spacer(minLength: 12)
            trailingControls(density)
        }
    }

    /// The paperclip, microphone and ⌘/ squares pad their glyphs already, so they sit closer than the row's items.
    private func trailingControls(_ density: FooterDensity) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                attachControl
                dictationControl
                if density == .full { shortcutsControl.focusedOnly(focused) }
            }
            replyButton(showsKey: density == .full)
                .background(alignment: .leading) {
                    // Hidden, the chip still anchors the sheet ⌘/ opens.
                    if density == .compact {
                        shortcutsControl.opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .focusedOnly(focused)
        }
    }

    /// Only for a helper that keeps attachments; disabled (with why) for commands and queued edits.
    @ViewBuilder private var attachControl: some View {
        if session.acceptsAttachments && session.sideConversation == nil {
            ChatAttachButton(session: session, coordinator: coordinator).focusedOnly(focused)
        }
    }

    /// The draft's attachment chips (and why an attach was refused) sit above the editor.
    private var attachmentsShown: Bool {
        session.drafts.shape.hasAttachments || !session.draftUploads.isEmpty || session.attachmentError != nil
    }

    /// Shown with the reply actions, and while this chat's dictation listens or says why it failed; never with
    /// Dictation off.
    @ViewBuilder private var dictationControl: some View {
        let dictation = Dictation.shared
        if DictationStore.shared.enabled {
            ChatDictationButton(session: session)
                .focusedOnly(focused || dictation.active(session.id) || dictation.error(for: session.id) != nil)
        }
    }

    @ViewBuilder private func savedDraftControls(_ density: FooterDensity) -> some View {
        if session.drafts.shape.hasSaved || !session.drafts.recoverable.isEmpty {
            ChatDraftControls(session: session, compact: density == .compact)
        }
    }

    private func modelControls(_ density: FooterDensity) -> some View {
        HStack(spacing: 7) {
            ChatModelControls(session: session, coordinator: coordinator, focused: focused && session.showChat && !session.drafts.shape.multiline,
                              compactEffort: density == .compact, modelWidth: density == .compact ? theme.typography.detailSize * 9 : nil)
            if session.goal != nil {
                Text("·").accessibilityHidden(true)
                ChatGoalControls(session: session, coordinator: coordinator)
            }
        }.lineLimit(1).truncationMode(.middle)
            .foregroundStyle(theme.muted.opacity(0.65))
    }

    private var showsAgentStatus: Bool {
        agentWorking || (session.active && !(session.subagents.isEmpty && session.shells.isEmpty))
    }

    @ViewBuilder private func agentStatus(_ density: FooterDensity) -> some View {
        ChatComposerActivity(session: session, activity: activity, active: focused || agentWorking, showsLabel: density == .full)
        ChatComposerAgents(session: session)
        ChatComposerShells(session: session)
    }

    /// Outside the two-row footer's scrolling strip, so neither can scroll out of reach.
    @ViewBuilder private var stopControls: some View {
        if agentWorking, session.stopArmedAt != nil {
            // Esc twice: the first press only arms the stop.
            Text("⎋ again to stop").font(theme.typography.detail).foregroundStyle(theme.muted)
                .accessibilityIdentifier("chat-stop-armed")
        }
        composerStop
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
                .help(coordinator.interruptBlockReason(session)
                      ?? "\(theme.radioLog ? "All stop" : "Stop agent") · ⎋⎋ · Draft kept")
                .accessibilityHint(coordinator.interruptBlockReason(session) ?? "")
                .accessibilityLabel(theme.radioLog ? "All stop" : "Stop agent").accessibilityIdentifier("chat-stop")
        }
    }

    private var shortcutsControl: some View {
        ChatComposerShortcuts(session: session, steers: coordinator.sendWhileWorking == .steer,
                              presented: $session.shortcutsPresented)
    }

    /// Why the button's steer would be refused now (a pending request, the model picker, …): it is disabled and says so.
    private var steerBlocked: String? {
        guard session.busy, session.editingQueuedID == nil, !session.draftIsCommand,
              // The button steers (`sendFromComposer(_:alternate:)`): ⌥⌘ held, or Return steers and ⌥⌘ is not.
              alternateSendHeld != coordinator.returnSteers(session) else { return nil }
        return coordinator.inputBlockReason(session, immediately: true)
    }

    private func replyButton(showsKey: Bool) -> some View {
        ChatReplyButton(canSubmit: canSubmit, alternateSendHeld: alternateSendHeld, busy: session.busy, steers: coordinator.returnSteers(session),
                        editingQueued: session.editingQueuedID != nil, multiline: session.drafts.shape.multiline,
                        command: session.draftIsCommand, showsKey: showsKey, blocked: steerBlocked) {
            coordinator.sendFromComposer(session, alternate: alternateSendHeld)
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
            // Up and Down move the selection past the visible rows (wrapping at either end): the list follows it.
            let selected = matchingCommands[min(session.commandSelection, matchingCommands.count - 1)]
            ScrollViewReader { proxy in
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
                                    .background(command == selected ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(command)
                        }
                    }
                }.onChange(of: selected) { _, command in proxy.scrollTo(command) }
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
        case "/settings": "change the agent's settings"
        case "/tree": "go to another branch of this conversation"
        case "/reload": "reload extensions, skills and prompts · in terminal"
        case "/exit", "/quit": "quit the agent"
        // Typed into the agent as it is (its own commands, skills); Chat stays.
        default: session.active ? "send to \(session.agentTitle)" : "send to the agent"
        }
    }
}

struct ChatSessionStats: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession

    var body: some View {
        // Pi's footer shows what the session cost: a line of its own under the tokens (beside them, a long session's
        // "$123.456 (sub)" would not fit the activity popover). The other agents' reports are not shown as a price.
        VStack(alignment: .leading, spacing: 4) {
            counters
            if session.agentID == "pi", let usage = session.usage, let cost = Self.cost(usage) {
                Text("Cost \(cost)")
                    .help(usage.subscription ? "What the session's tokens would cost: the model is used through a subscription" : "What the session cost, as Pi reports it")
                    .accessibilityIdentifier("chat-session-cost")
            }
        }.font(theme.typography.detail).foregroundStyle(theme.muted)
            .fixedSize(horizontal: true, vertical: false).accessibilityIdentifier("chat-session-stats")
    }
    private var counters: some View {
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
                // An agent that reports neither count does not count tokens for this chat: say so, not "— in, — out".
                if usage.input == nil && usage.output == nil {
                    Text("Token counter is disabled for this chat")
                        .help("The agent reports no token counts for this chat")
                        .accessibilityIdentifier("chat-session-tokens-off")
                } else {
                    Text("(\(count(usage.input)) in, \(count(usage.output)) out)")
                        .help("Cumulative session tokens")
                }
            } else { Text("Usage unavailable").help("Waiting for agent-reported session usage") }
        }
    }
    private func count(_ value: Int?) -> String { Self.count(value) }
    /// `ChatUsage.costText`, shared with the phone.
    static func cost(_ usage: ChatUsage) -> String? { usage.costText }
    /// `ChatUsage.count`, shared with the phone.
    static func count(_ value: Int?) -> String { ChatUsage.count(value) }
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

/// Something in the input stack that unfolds as it comes and folds away as it goes: its height (and the stack's
/// `spacing` after it) grows from nothing or shrinks to nothing, fading with it, so what sits above follows instead of
/// jumping. It stays mounted while it folds shut, and renders nothing at all once shut (so the stack adds no spacing).
struct ChatInputFold<Content: View>: View {
    let present: Bool
    let spacing: CGFloat
    let reduceMotion: Bool
    @ViewBuilder let content: () -> Content
    /// `present` as last handled: still true in the update that turns `present` off, so the fold has a view to run on.
    @State private var handled: Bool
    @State private var folding = false
    @State private var shown: Double

    init(present: Bool, spacing: CGFloat, reduceMotion: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.present = present; self.spacing = spacing; self.reduceMotion = reduceMotion; self.content = content
        _handled = State(initialValue: present)
        _shown = State(initialValue: present ? 1 : 0)
    }

    var body: some View {
        if present || handled || folding {
            // The stack's spacing after it rides in the fold, and the negative padding gives it back: at full height
            // it adds exactly what it did, folded shut nothing.
            ChatFoldLayout(shown: shown) {
                content().padding(.bottom, spacing)
            }
            .opacity(shown)
            .clipped()
            .padding(.bottom, -spacing)
            .onAppear { if present && shown < 1 { open() } }
            .onChange(of: present) { _, present in
                handled = present
                if present { open() } else { close() }
            }
        }
    }

    private func open() {
        handled = true; folding = false
        guard !reduceMotion else { shown = 1; return }
        // Mounted folded for a frame, then unfolds.
        Task { @MainActor in
            withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.26)) { shown = 1 }
        }
    }

    private func close() {
        guard !reduceMotion else { shown = 0; return }
        folding = true
        withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.24)) { shown = 0 } completion: {
            if !present { folding = false }
        }
    }
}
