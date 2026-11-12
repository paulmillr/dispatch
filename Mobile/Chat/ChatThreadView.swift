import SwiftUI
import UIKit

/// A conversation's Chat segment (M4a, M3b, M4b, M4c, M5a, M5c, M5f): the link banner, the thread, the thinking row and
/// queue, and the composer. The Tabs stream's `TabScreen` draws the header above it (back pill, title, segmented
/// control); this view is its Chat content and must sit inside a `NavigationStack` (message details push, M5b).
struct ChatThreadView: View {
    @Bindable var session: MobileChatSession
    /// The space the conversation's tab lives in (M3b's "claude in app", M5b's facts and back pill).
    var space: String
    /// The conversation's tab (M5b's facts).
    var tab: String? = nil
    /// The terminal's directory (M3b's "Runs in …", paths in steps).
    var directory: String?
    /// The host's homes, for "~" in M3b's "Runs in …" (`HomePath`).
    var homes = HomePath(account: nil)
    /// The composer takes focus on appear (M3b, a new chat). In the split's detail column with a hardware keyboard it
    /// does anyway (`focusesOnAppear`).
    var focusOnAppear = false
    /// The newest result is on screen (ChatConversations.markSeen).
    var seen: () -> Void = {}
    /// Remembers models, efforts and the choice for New chat's defaults.
    var memory: ChatModelMemory?
    /// Opens with the step list unfolded (M5f); for previews and the demo.
    var expandSteps = false
    /// Opens at the thread's top instead of its end (C6's demo).
    var startsAtTop = false

    @State private var workingExpanded = false
    @State private var details: ChatThreadRow?
    @State private var step: ChatStep?
    @State private var settings = false
    @State private var previewing: ChatAttachment?
    @State private var column: CGFloat = 370
    @FocusState private var focused: Bool
    @FocusState private var searchFocused: Bool
    /// The thread shows its end (C6): new rows keep it there; scrolled up, they count into the jump button.
    /// Whether the thread follows its end and what came while it did not (C6, `ChatFollow`), kept outside SwiftUI's
    /// state: it changes with every scrolled frame, which draws nothing. `followShown` is the part that draws.
    @State private var follower = ChatFollower()
    @State private var followShown: ChatFollow.Shown?
    /// Counts requests to show the thread's end (a send).
    @State private var pinned = 0
    /// The last row, to tell rows added at the end from an earlier page added above.
    @State private var lastRow: String?
    /// The oldest row drawn: the thread opens on its last rows (`tailStart`) and draws older ones as its top comes near,
    /// since the stack is not lazy (rows keep their real heights for following the end) and drawing a whole page made
    /// opening a tab take half a second. Nil: the opening rows.
    @State private var firstShown: String?
    @State private var visible = false
    /// This view opened already: a pushed message's details coming back keep the scroll view, only a new view restores
    /// `MobileChatSession.readingPosition`.
    @State private var opened = false
    /// Counts the ends of `settling` moments, to draw again when one is over.
    @State private var settled = 0
    /// The moment the corners' times are told against ("Yesterday 10:17"): set again at midnight, when the clock or time
    /// zone changes and on returning to the app, so the thread redraws for it then rather than on a timer per bubble.
    @State private var today = Date()
    @State private var voice = MobileVoiceConversation.shared
    @State private var reader = MobileMessageReader.shared
    @Environment(\.chatShowTerminal) private var showTerminal
    @Environment(\.scenePhase) private var scenePhase
    /// The software keyboard floats (an iPad): the composer stays at the bottom (`MobileKeyboardReader`).
    @State private var floatingKeyboard = false
    @Environment(\.tabsSplitDetail) private var splitDetail
    /// A phone on its side (`MobileLandscape`): the empty composer folds into the rail's Reply (`composerFolded`).
    @Environment(\.tabRail) private var rail
    /// Reply was tapped: the composer shows and takes the focus until it is left empty and unfocused again.
    @State private var replying = false
    /// Settings › Chat: send's tap queues or steers while the agent works.
    @AppStorage(MobileSettings.chatSendWhileWorkingKey) private var sendWhileWorking = ChatSendWhileWorking.queue
    @ScaledMetric(relativeTo: .callout) private var measure = ChatMeasure.standard
    @Environment(\.dynamicTypeSize) private var typeSize
    /// How long the thread rides out the moment after the agent stops or its turn ends (`settling`).
    @Environment(\.chatSettle) private var settle
    @State private var reveal = ChatReveal()
    /// The haptic for the host's link dropping and coming back while the thread is open (`ChatLinkHaptic`).
    @State private var linkHaptic = ChatLinkHaptic()
    /// The attachment preview zooms out of the tile or chip tapped (`chatAttachmentZoom`).
    @Namespace private var attachmentZoom
    @ScaledMetric(relativeTo: .caption2) private var revealWidth = ChatRevealDetail.width
    @ReduceMotion private var reduceMotion

    /// Whether the composer takes focus when the thread appears: when asked (a new chat, M3b), or when the tab opens in
    /// the split's detail column while a hardware keyboard is attached, so typing goes straight to the agent as on the
    /// Mac. A touch-only iPad gets no software keyboard it did not ask for, and a phone's stack is unchanged.
    static func focusesOnAppear(requested: Bool, splitDetail: Bool, hardwareKeyboard: Bool) -> Bool {
        requested || (splitDetail && hardwareKeyboard)
    }

    private var multiline: Binding<Bool> {
        Binding(get: { session.drafts.current.multiline }, set: { session.drafts.edit(multiline: $0) })
    }

    private var draft: Binding<String> {
        Binding(get: { session.drafts.current.text }, set: { session.drafts.edit(text: $0, fromEditor: true) })
    }

    var body: some View { presenting(thread) }

    /// The thread and what it follows; its pushes and sheets are `presenting`'s (one chain was too long to type-check).
    private var thread: some View {
        let rows = session.transcript.rows
        return VStack(spacing: 0) {
            ChatLinkBanner(link: session.link, host: session.hostName, problem: session.linkProblem)
            if let goal = session.goal {
                ChatGoalStrip(session: session, goal: goal)
            }
            scroller(rows)
                // The thread runs on under the header and the composer, the rows fading under their glass as under the
                // system's bars (the side conversation's too); the jump button is laid out inside the bar's inset. Soft at
                // the top too, as Messages has it: left to the system, an iPhone drew the header's edge as the hard one,
                // an opaque band ending in a line, where the simulator drew the soft one.
                .scrollEdgeEffectStyle(.soft, for: .all)
                .safeAreaBar(edge: .bottom, spacing: 0) { bottomBar }
        }
        .environment(\.chatOpenAttachment, { previewing = $0 })
        .environment(\.chatAttachmentZoom, zoomSpace)
        .background(Color.canvas)
        // A floating keyboard sits over the thread, as the terminal's capsule leaves it: SwiftUI's inset for it lifted
        // the composer part of the way, under the keyboard. The user moves the keyboard; a docked one still raises it.
        .ignoresSafeArea(.keyboard, edges: floatingKeyboard ? .bottom : [])
        .background {
            if UIDevice.current.userInterfaceIdiom == .pad {
                MobileKeyboardReader { floatingKeyboard = $0 == .floating }
            }
        }
        .onAppear {
            visible = true
            if !opened {
                opened = true
                restoreReading(rows)
            }
            lastRow = rows.last?.id
            pinFirstShown(self.entries(rows))
            if Self.focusesOnAppear(requested: focusOnAppear, splitDetail: splitDetail,
                                    hardwareKeyboard: HardwareKeyboard.shared.attached) { focused = true }
            if expandSteps { workingExpanded = true }
            seen()
            session.search.update(rows: rows)
        }
        // On a phone's side the composer while empty and unfocused is the rail's Reply: the thread has the window's
        // height. Reply unfolds it and gives it the focus; left empty and unfocused, it folds again.
        .onChange(of: composerFolded, initial: true) { _, folded in rail?.replyShown = folded }
        .onChange(of: replying) { _, replying in
            if replying { Task { @MainActor in focused = true } }
        }
        .onChange(of: focused) { _, focused in
            if !focused, session.drafts.current.text.isEmpty { replying = false }
        }
        .onAppear { rail?.reply = { replying = true } }
        .onDisappear {
            rail?.replyShown = false
            visible = false
            saveReading()
            // Leaving the conversation (not pushing a message's details) ends conversation mode, Read Aloud and an edit
            // of a queued message (its draft set aside comes back).
            if voice.active(for: session), details == nil { voice.stop() }
            if details == nil { session.endQueueEdit(save: false) }
            if details == nil, let reading = reader.reading, session.transcript.rows.contains(where: { $0.id == reading.row }) {
                reader.stop()
            }
        }
        // The side screen has no listening bar: conversation mode talks with the main thread only, so it ends there.
        .onChange(of: session.showingSide) { _, showing in
            if showing, voice.active(for: session) { voice.stop() }
        }
        // Only while the app is in the foreground: a result arriving behind the lock screen is not read. Kept rows shown
        // before the helper named the conversation are seen once it does (their newest record may not change).
        .onChange(of: session.transcript.lastActivity) { _, _ in if scenePhase == .active { seen() } }
        .onChange(of: session.conversation) { _, _ in if scenePhase == .active { seen() } }
        .onChange(of: session.transcript.revision) { _, _ in
            let rows = session.transcript.rows
            pinFirstShown(self.entries(rows))
            countUnseen(rows)
            session.search.update(rows: rows)
            voice.check()
        }
        .onChange(of: session.approvals.count) { _, _ in voice.check() }
        // An earlier page arrived above what is drawn while the top was near: draw on into it.
        .onChange(of: session.loadingEarlier) { _, loading in
            if !loading, follower.nearTop { reachedTop() }
        }
        // A kept transcript's top reached before the helper answered: its earlier page loads once one can.
        .onChange(of: session.canLoadEarlier) { _, can in
            if can, follower.nearTop { reachedTop() }
        }
        .onChange(of: session.working) { _, _ in voice.check() }
        .onChange(of: showsWorkingRow) { _, shown in if !shown { workingExpanded = false } }
        .task(id: [session.stoppedWorking, session.turnEnded]) {
            // Draws once more when the moment after a stop or a turn's end is over (`settling`).
            guard let last = [session.stoppedWorking, session.turnEnded].compactMap({ $0 }).max() else { return }
            try? await Task.sleep(for: .seconds(max(0, last.timeIntervalSinceNow + settle) + 0.05))
            if !Task.isCancelled { settled += 1 }
        }
        .onChange(of: session.search.query) { _, _ in session.search.update(rows: session.transcript.rows) }
        .onChange(of: session.search.visible) { _, open in
            if open { focused = false; searchFocused = true }
        }
        .onChange(of: scenePhase) { _, phase in
            // The microphone stops in the background: conversation mode ends rather than half-listen.
            if phase == .background, voice.active(for: session) { voice.stop() }
            if phase == .active { today = Date(); seen() }
            linkHaptic.scene(active: phase == .active)
        }
        .modifier(ChatLinkHaptics(connected: session.link.isConnected, haptic: $linkHaptic))
        // A new day, or the clock or time zone changed: the corners' times are told again against the current calendar.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            today = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            today = Date()
        }
        .task(id: SearchHistory(query: session.search.active ? session.search.query : "", conversation: session.conversation)) {
            await searchEarlier()
        }
        .onReceive(NotificationCenter.default.publisher(for: ChatSearchBar.requested)) { note in
            guard visible, !session.showingSide else { return }
            let direction = ChatSearchBar.direction(note)
            if direction != 0, session.search.active { session.search.move(direction) } else {
                session.search.open()
                searchFocused = true
            }
        }
    }

    /// The thread's scroll view: the rows, the working row and queue, following the end (C6), the jump button.
    private func scroller(_ rows: [ChatThreadRow]) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: 8) {
                    // The entries are read here, inside the scroll view's content, as they always were: read in the
                    // body's own scope, the answer replacing the working row moved the thread for a frame.
                    transcript(self.entries(session.transcript.rows))
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, showsWorkingRow ? 4 : 12)
                // The rows' frames in the content (`ChatFollower.rowFrames`), its top the scroll view's content top.
                .coordinateSpace(.named(Self.contentSpace))
                .background(ChatKeyboardDragDismissal { updateFollow { $0.draggedKeyboardDown() } })
                .background(ChatScrollViewProbe(follower: follower, attached: attached))
                .environment(\.chatSearchMarks, session.search.active
                             ? ChatSearchMarks(query: session.search.query.trimmingCharacters(in: .whitespacesAndNewlines)) : nil)
                if showsWorkingRow {
                    ChatWorkingRow(session: session, directory: directory, expanded: $workingExpanded) { step = $0 }
                }
                if session.phase == .verified, !session.queueRows.isEmpty {
                    // The queued messages, the user's own faded bubbles under the working row (M5c).
                    VStack(spacing: 8) { ChatQueuedBubbles(session: session, edit: editQueued) }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        // The first message queued while the agent works rises into it; drained or emptied, it goes at once, as the
                        // rows that take its place come.
                        .transition(.asymmetric(insertion: sendRise, removal: .identity))
                }
                Color.clear.frame(height: 1).id(Self.bottom)
            }
            // The end of the thread stays in view as rows come while it is shown; scrolled up, what is read stays
            // put (C6), and older rows drawn above keep the rows in place too (`grew`).
            .defaultScrollAnchor(startsAtTop || restoring != nil ? .top : .bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(shownFollow.following ? .bottom : .top, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            // Times on swipe: a drag toward the leading edge shows the times (`ChatRevealSent`, `ChatRevealReceived`).
            .gesture(ChatRevealPan(reveal: reveal, width: revealWidth + ChatRevealDetail.gap, reduceMotion: reduceMotion))
            .onScrollPhaseChange { old, phase in
                // Only the user's scrolls look for the top: the follow's samples stay as they were.
                switch phase {
                case .idle:
                    if updateFollow({ $0.dragEnded(atEnd: follower.atEnd) }) { scroll.scrollTo(Self.bottom, anchor: .bottom) }
                    // Following but at rest away from the end (the button's scroll lost to a fling): to the end.
                    if updateFollow({ $0.rested(atEnd: follower.atEnd) }) {
                        withAnimation(.snappy) { scroll.scrollTo(Self.bottom, anchor: .bottom) }
                    }
                    // Where it stopped is where the thread opens next time.
                    if restoring == nil { saveReading() }
                case .interacting, .tracking:
                    if phase == .interacting { updateFollow { $0.dragBegan() } }
                    // The user's own scroll takes over from putting the place back.
                    follower.restoring = nil
                default: break
                }
            }
            .onScrollGeometryChange(for: ChatScrollSample.self, of: { geometry in
                // The container leaves out the insets (the composer's bar and the keyboard the thread runs under, the
                // navigation bar above it): what shows starts the top inset below the offset.
                ChatScrollSample(offset: geometry.contentOffset.y,
                                 atEnd: geometry.contentOffset.y + geometry.contentInsets.top + geometry.containerSize.height
                                     >= geometry.contentSize.height - 40,
                                 insets: geometry.contentInsets, height: geometry.containerSize.height,
                                 content: geometry.contentSize.height)
            }) { old, sample in
                // A layout before the scroll view is in its window (a pushed thread's first passes, more of them on a
                // busy phone) reports the content at its top: no scroll of anyone's, so it neither ends the follow nor
                // counts as the top coming near (`ChatFollower.attached`).
                guard follower.attached else { return }
                follower.atEnd = sample.atEnd
                // Putting the place back holds through the first layouts (the navigation bar's inset arrives late).
                if follower.restoring != nil { applyReading() }
                // A row, the keyboard or the composer changing height takes the end out of view for a moment:
                // the thread goes back rather than counting what comes meanwhile (`ChatFollow.moved`).
                let resized = old.insets != sample.insets || old.height != sample.height
                if updateFollow({ $0.moved(offset: sample.offset, atEnd: sample.atEnd, resized: resized) }) {
                    if !pinToEnd() { scroll.scrollTo(Self.bottom, anchor: .bottom) }
                } else if resized || old.content != sample.content {
                    // Within the end's 40 points the follow sees no need to move, and the anchor and a scroll to the
                    // last row leave the thread short of it as rows' real heights replace their estimates: following,
                    // the thread sits exactly at its end.
                    pinToEnd()
                }
            }
            // Older rows were laid out above (`reachedTop`).
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { old, new in grew(by: new - old) }
            // Within half a screen of the top: older rows draw before the top is reached.
            .onScrollGeometryChange(for: Bool.self, of: { geometry in
                follower.attached && geometry.contentOffset.y + geometry.contentInsets.top < geometry.containerSize.height / 2
            }) { _, near in
                follower.nearTop = near
                if near { reachedTop() }
            }
            .onChange(of: pinned) { _, _ in scroll.scrollTo(Self.bottom, anchor: .bottom) }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width - 32 }) { column = $0 }
            .environment(\.chatColumnWidth, column)
            .environment(\.chatMeasure, measure)
            .overlay(alignment: .bottomTrailing) {
                // The follow changes outside any animation (`updateFollow`): the button's transition brings its own.
                if shownFollow.showsJump {
                    ChatJumpButton(count: shownFollow.unseen) {
                        // A fling still running toward older rows would carry on over the scroll to the end: it stops
                        // where it is first.
                        if let view = follower.scrollView, view.isDecelerating {
                            view.setContentOffset(view.contentOffset, animated: false)
                        }
                        updateFollow { $0.follow(scrolling: true) }
                        withAnimation(.snappy) { scroll.scrollTo(Self.bottom, anchor: .bottom) }
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                    .transition(jumpTransition)
                }
            }
            .onChange(of: rows.first?.id) { previous, first in
                // C6's demo reads the thread from its top once it has loaded.
                if startsAtTop, previous == nil, let first { scroll.scrollTo(first, anchor: .top) }
            }
            .onChange(of: session.search.navigation) { _, _ in
                guard let match = session.search.current else { return }
                updateFollow { $0.leave() }
                // A match above what is drawn: its row is drawn first, and scrolled to once it is laid out.
                let current = self.entries(session.transcript.rows)
                if let index = current.firstIndex(where: { $0.id == match.row }), index < shownStart(current) {
                    firstShown = match.row
                    DispatchQueue.main.async { withAnimation(.snappy) { scroll.scrollTo(match.row, anchor: .center) } }
                    return
                }
                withAnimation(.snappy) { scroll.scrollTo(match.row, anchor: .center) }
            }
        }
    }

    /// The thread's pushes (a message's details, the side conversation), its sheets and the attachment preview.
    private func presenting(_ thread: some View) -> some View {
        thread
        // A sheet or the preview over the thread: its working row and banner stand still meanwhile.
        .coversLoops(step != nil || settings || session.managingGoal || session.showingShells || previewing != nil)
        .navigationDestination(item: $details) { row in
            messageDetails(row)
        }
        .navigationDestination(isPresented: $session.showingSide) {
            if let side = session.side {
                ChatSideScreen(session: session, side: side, conversation: session.title ?? tab ?? space)
            }
        }
        .sheet(item: $step) { step in
            ChatStepOutputSheet(session: session, step: step, directory: directory)
        }
        .sheet(isPresented: $settings) {
            ChatSettingsSheet(session: session, memory: memory)
        }
        .sheet(isPresented: $session.managingGoal) {
            ChatGoalSheet(session: session)
        }
        .sheet(isPresented: $session.showingShells) {
            ChatShellsSheet(session: session)
        }
        .fullScreenCover(item: $previewing) { attachment in
            MobileAttachmentPreview(attachment: attachment, host: session.key.host, read: read)
                .chatZoom(attachment.id, in: zoomSpace)
        }
    }

    private static let bottom = "thread-bottom"

    private var sendRise: AnyTransition { ChatSendRise.transition(reduceMotion: reduceMotion) }

    /// Where attachment previews zoom from (`chatAttachmentZoom`); none with Reduce Motion.
    private var zoomSpace: Namespace.ID? { reduceMotion ? nil : attachmentZoom }

    private var jumpTransition: AnyTransition {
        reduceMotion ? .opacity.animation(.easeOut(duration: 0.15))
            : .opacity.combined(with: .scale(scale: 0.9)).animation(.snappy(duration: 0.25))
    }

    /// The rows drawn (`shownStart` on), then the prompt being sent as a user row: the record that confirms it takes its
    /// id (`MobileChatSession.reconcile`), so the same view carries on, mid-flight or not.
    private func drawn(_ entries: [Entry], from start: Int) -> [Entry] {
        var drawn = Array(entries[start...])
        if let prompt = session.optimisticPrompt {
            drawn.append(.row(ChatThreadRow(id: prompt.id, kind: .user, item: prompt, turnID: "", time: nil)))
        }
        return drawn
    }

    /// `date` is within the last `settle` seconds (`chatSettle`): state and records arrive apart, so for that long
    /// after the agent stops the working row stays until the turn's end comes, and after the turn ends it stays away
    /// until the busy state clears, rather than the row and the turn's summary flashing between the two.
    private func settling(_ date: Date?) -> Bool {
        _ = settled
        return date.map { Date().timeIntervalSince($0) < settle } ?? false
    }

    /// The working row (M5a): for as long as the agent works, and in the moment after it stops before the turn's end
    /// arrives; away in the moment after the turn ends while the busy state that ran through it is still on its way
    /// out, unless its step list is unfolded (M5f stays readable). A prompt sent here or work that began after the end
    /// (another device's prompt) shows it at once.
    private var showsWorkingRow: Bool {
        guard session.working || session.transcript.openTurn != nil && settling(session.stoppedWorking) else { return false }
        if workingExpanded { return true }
        let stale = settling(session.turnEnded) && session.submittedAt == nil
            && session.workingSince.map { since in session.turnEnded.map { since <= $0 } ?? false } == true
        return !stale
    }

    /// The corner of an agent reply (`ChatCorner.reply`): the ended turn's summary on its last one, else the reply's
    /// time; none on Claude's or Pi's thinking. While the turn runs the working row tells the work.
    private func corner(_ row: ChatThreadRow, summary: ChatTurnSummary?) -> ChatCorner? {
        guard case .agent = row.kind else { return nil }
        return ChatCorner.reply(time: row.time, summary: summary, now: today,
                                metrics: ChatCornerMetrics(column: column, measure: measure, size: typeSize))
    }

    /// Rows added after the last one while scrolled up count into the jump button (C6).
    private func countUnseen(_ rows: [ChatThreadRow]) {
        defer { lastRow = rows.last?.id }
        let added = Self.appended(rows, after: lastRow)
        if added > 0 { updateFollow { $0.appended(added) } }
    }

    /// What the button and the size-change anchor read.
    private var shownFollow: ChatFollow.Shown { followShown ?? ChatFollow(following: !startsAtTop).shown }

    /// Changes the follow state; draws again only when what it shows changed.
    @discardableResult
    private func updateFollow<Result>(_ change: (inout ChatFollow) -> Result) -> Result {
        var next = follower.model ?? ChatFollow(following: !startsAtTop)
        let result = change(&next)
        follower.model = next
        if next.shown != shownFollow { followShown = next.shown }
        return result
    }

    /// How many rows follow `last` (the last row before a change): rows added at the end. A first load (no `last`), an
    /// earlier page added above or a replaced transcript (`last` gone) add none.
    static func appended(_ rows: [ChatThreadRow], after last: String?) -> Int {
        guard let last, rows.last?.id != last, let index = rows.lastIndex(where: { $0.id == last }) else { return 0 }
        return rows.count - 1 - index
    }

    private struct SearchHistory: Equatable {
        let query: String
        let conversation: String?
    }

    private func searchEarlier() async { await session.search.searchEarlier(in: session) }

    /// What sits under the thread: the listening bar in conversation mode (C5), the search bar while searching (C1),
    /// else the composer with the slash list over it (C2), the goal's status (C4) and the way back to a side
    /// conversation (C3).
    @ViewBuilder private var bottomBar: some View {
        if voice.active(for: session) {
            ChatListeningBar(voice: voice)
        } else if session.search.visible {
            ChatSearchBar(search: session.search, focus: $searchFocused)
        } else {
            VStack(spacing: 0) {
                let commands = slashCommands
                if !commands.isEmpty {
                    ChatSlashList(commands: commands) { command in
                        session.drafts.edit(text: command.name + " ")
                        focused = true
                    }
                    .padding(.bottom, 8)
                    // Typing "/" lays the list out at once and fades it in; chosen or typed away, it goes at once rather
                    // than fading over the thread's last rows.
                    .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.15)), removal: .identity))
                }
                if let side = session.side, !session.showingSide {
                    ChatSideReturn(side: side) { session.showingSide = true }
                }
                if !session.shells.isEmpty {
                    ChatShellsLine(shells: session.shells) { session.showingShells = true }
                }
                if session.goal != nil, !session.goalStatus.isEmpty {
                    ChatGoalStatusLine(parts: session.goalStatus)
                }
                if session.queueEdit != nil {
                    ChatQueueEditBar { session.endQueueEdit(save: false) }
                } else if let note = session.queueEditNote {
                    Button { session.queueEditNote = nil } label: { ChatCaption(text: note).padding(.horizontal, 10) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Dismisses the note")
                }
                let routes = composerRoutes
                // Settings › Chat may make send's tap steer while the agent works; its long press queues then.
                let steers = sendWhileWorking == .steer && routes.steer == .steer
                if !composerFolded {
                let editing = session.queueEdit != nil
                CodeComposer(text: draft, placeholder: placeholder, working: session.working && session.phase == .verified,
                             focus: $focused,
                             // Editing a queued message, send is ✓: the text goes back in its place.
                             send: { if editing { session.endQueueEdit(save: true) } else { send(steer: steers) } },
                             steer: !editing && routes.steer == .steer ? {
                                 session.send(steer: true)
                                 followAfterSending()
                             } : nil,
                             queue: !editing && steers ? { send(steer: false) } : nil,
                             stop: { session.stop() },
                             sendOptions: editing ? [] : sendOptions(routes),
                             saving: editing,
                             attachments: attachments,
                             dictationOwner: ObjectIdentifier(session), multiline: multiline,
                             converse: session.phase == .verified ? { voice.start(session) } : nil)
                }
            }
        }
    }

    /// The composer is the rail's Reply (a phone on its side): empty, nothing attached or uploading, not focused, not
    /// unfolded by Reply.
    private var composerFolded: Bool {
        guard rail != nil, !replying, !focused else { return false }
        let draft = session.drafts.current
        return draft.text.isEmpty && draft.attachments.isEmpty && session.draftUploads.isEmpty
    }

    /// The slash list's rows for the draft (C2).
    private var slashCommands: [ChatSlashCommand] { session.slashCommands }

    /// The composer's send, its button and Return (`MobileChatSession.sendFromComposer`): the slash list's lit row,
    /// "/terminal", or the draft, steered into the running turn when `steer`.
    private func send(steer: Bool = false) {
        switch session.sendFromComposer(steer: steer, showTerminal: showTerminal.map { terminal in { terminal.show() } }) {
        case .completed: focused = true
        case .sent: followAfterSending()
        case .terminal: break
        }
    }

    /// Where the draft goes on a tap of send, and on its long press's Send now (`MobileChatSession.route`): a command
    /// routes as one and never steers.
    private var composerRoutes: (tap: MobileChatSession.Route, steer: MobileChatSession.Route) {
        let text = session.drafts.current.text
        let command = AgentInput.isCommand(text, multiline: text.contains("\n"))
        return (session.route(steer: false, command: command), session.route(steer: true, command: command))
    }

    /// What send's long press offers: what the tap would do with the draft as it is. The slash list's lit row completes
    /// into the draft and "/terminal" opens Terminal (`MobileChatSession.sendFromComposer`), each the one item; else the
    /// routes' ways (`CodeComposer.sendOptions`).
    private func sendOptions(_ routes: (tap: MobileChatSession.Route, steer: MobileChatSession.Route)) -> [CodeComposer.SendOption] {
        let text = session.drafts.current.text
        if let first = session.slashCommands.first, first.name != text { return [.complete(first.name)] }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/terminal", showTerminal != nil { return [.terminal] }
        return CodeComposer.sendOptions(queues: routes.tap == .queue || routes.tap == .outbox, steers: routes.steer == .steer)
    }

    /// A message sent from here shows at the thread's end, and the thread follows it (no "Jump to latest").
    private func followAfterSending() {
        updateFollow { $0.follow() }
        pinned += 1
    }

    /// Reads a stored attachment from this conversation's host (`attachments.read`).
    private var read: @MainActor (String) async throws -> Data? {
        { [session] path in try await session.attachmentBytes(path) }
    }

    /// The composer's attachments (docs/ios.md, Attachments): offered while the helper takes them; what the draft holds
    /// and the uploads still show (and can be removed) after the link drops.
    private var attachments: ComposerAttachments? {
        let chips = ComposerAttachments.chips(session)
        guard session.attachmentsAvailable || !chips.isEmpty || session.attachmentError != nil else { return nil }
        let stored = session.drafts.current.attachments
        return ComposerAttachments(
            chips: chips, error: session.attachmentError, enabled: session.canAttach,
            remaining: max(0, ChatAttachment.maximumCount - stored.count - session.draftUploads.count),
            add: { session.attach($0) }, remove: { session.removeAttachment($0) }, retry: { session.retryUpload($0) },
            open: { id in
                if let attachment = stored.first(where: { $0.id == id }) { previewing = attachment }
            },
            dismissError: { session.attachmentError = nil })
    }

    /// A queued bubble's Edit: its text in the composer, focused.
    private func editQueued(_ row: MobileChatSession.QueueRow) {
        session.beginQueueEdit(row)
        focused = true
    }

    /// The composer's hint (M4a, M4c, M5a, M5c).
    private var placeholder: String {
        if session.queueEdit != nil { return "Edit the queued message…" }
        if session.route(steer: false) == .outbox { return "Queue a message…" }
        if sendWhileWorking == .steer, session.route(steer: true) == .steer { return "Steer the current turn…" }
        if !session.queueRows.isEmpty { return "Queue another…" }
        return session.working ? "Queue a message…" : "Message"
    }

    /// The shown search match, when the search is open.
    private var currentMatch: ChatThreadSearch.Match? { session.search.active ? session.search.current : nil }

    @ViewBuilder private func transcript(_ entries: [Entry]) -> some View {
        let start = shownStart(entries)
        if start > 0 || session.hasEarlier {
            // Older rows, drawn or paged in as the top comes near (`ChatFollower.nearTop`), never on `onAppear`: in a stack that is
            // not lazy every view appears at once, and the spinner then paged in a page on every open.
            VStack(spacing: 8) {
                if start == 0, let error = session.earlierError {
                    Button("Load earlier messages") { session.loadEarlier() }
                    Text(error).font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
        }
        if let launching = session.launching, session.transcript.isEmpty {
            // The agent this phone started is not up yet: no intro until it is (the Mac's launch cover).
            ProgressView("Starting \(launching)…")
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if session.loadingHistory && session.transcript.isEmpty {
            ChatLoadingLine(session: session)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if session.transcript.isEmpty, session.optimisticPrompt == nil, session.queueRows.isEmpty, session.approvals.isEmpty {
            ChatIntro(session: session, space: space, directory: directory, homes: homes) { settings = true }
        }
        ForEach(drawn(entries, from: start)) { entry in
            switch entry {
            case .row(let row):
                rowView(row)
                    .environment(\.chatSearchCurrent, currentMatch?.row == row.id ? currentMatch?.occurrence : nil)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.contentSpace)) }) { frame in
                        follower.rowFrames[row.id] = frame
                        if follower.restoring?.row == row.id { applyReading() }
                    }
                    .id(row.id)
                    .transition(row.id == session.optimisticPrompt?.id ? sendRise : .identity)
            case .approval(let approval):
                if approval.pending.questions != nil {
                    ChatQuestionFormView(approval: approval) { session.answerDraft(approval, skip: $0) }
                } else {
                    ChatApprovalView(approval: approval) { session.answer(approval, with: $0) }
                }
            }
        }
        ForEach(session.questions) { question in
            ChatSideQuestionView(question: question) { session.answer(question, skip: $0) }
        }
        if session.phase != .verified {
            ChatQueuedBubbles(session: session, edit: editQueued)
        }
        notices
    }

    @ViewBuilder private func rowView(_ row: ChatThreadRow) -> some View {
        switch row.kind {
        case .user:
            VStack(spacing: 5) {
                ChatRevealSent(reveal: reveal, corner: sentCorner(row)) {
                    ChatUserMessage(text: row.item.text, attachments: row.item.attachments, host: session.key.host, read: read)
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.item.text }
                            readAloud(row)
                        }
                }
                readingFootnote(row)
            }
        case .agent(let summary):
            VStack(spacing: 5) {
                agentBubble(row, summary: summary)
                if let reading = voice.reading, reading.row == row.id, voice.active(for: session) {
                    ChatReadingFootnote(since: reading.since)
                } else {
                    readingFootnote(row)
                }
            }
        case .thinking:
            // Claude's or Pi's thinking: an agent bubble of its own, in the same colours and font as its messages.
            VStack(spacing: 5) {
                agentBubble(row, summary: nil)
                readingFootnote(row)
            }
        case .notice:
            notice(row.noticeText, row: row.id)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// Read Aloud, or Stop Reading while this message is read; none while conversation mode reads the replies.
    @ViewBuilder private func readAloud(_ row: ChatThreadRow) -> some View {
        if !voice.active(for: session) {
            ChatReadAloudButton(reader: reader, text: row.item.text, row: row.id)
        }
    }

    /// "Reading aloud · 0:08" and Stop under the message Read Aloud reads.
    @ViewBuilder private func readingFootnote(_ row: ChatThreadRow) -> some View {
        if let reading = reader.reading, reading.row == row.id {
            ChatReadingFootnote(since: reading.since, stop: { reader.stop() })
        }
    }

    /// A message's details (M5b), whose Reply and Show in Terminal return to the thread first.
    private func messageDetails(_ row: ChatThreadRow) -> ChatMessageDetails {
        let terminal: (() -> Void)? = showTerminal.map { terminal in { details = nil; terminal.show() } }
        return ChatMessageDetails(session: session, row: row, space: space, tab: tab, directory: directory,
                                  reply: { details = nil; reply(to: row) }, showTerminal: terminal)
    }

    /// Quotes a message into the composer above the draft, and focuses it (the bubble menu's and message details' Reply).
    private func reply(to row: ChatThreadRow) {
        let quote = row.item.text.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
        session.drafts.edit(text: quote + "\n\n" + session.drafts.current.text)
        focused = true
    }

    /// An agent's message or thinking: the bubble with the turn's summary in the last one's corner, a reply's time beside
    /// it on the swipe (`ChatCorner.swiped`, `ChatRevealReceived`; the bubble's value speaks it), the bubble tapped opens
    /// the message's details (M5b), and the long press's Copy, Reply and Info.
    private func agentBubble(_ row: ChatThreadRow, summary: ChatTurnSummary?) -> some View {
        let (corner, time) = swiped(row, summary: summary)
        let stream = streaming(row)
        return ChatRevealReceived(reveal: reveal, time: time) {
            ChatBubble(side: .agent) {
                MobileTypedMarkdown(text: row.item.text, corner: corner, rowID: row.id, reveals: session.typing,
                                    live: stream.live, ended: stream.ended, posts: ChatTypingReveals.posts(session.agentKey))
            }
                .environment(\.openURL, MobileChatMarkdown.openURL)
                .onTapGesture { details = row }
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.item.text }
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { reply(to: row) }
                    readAloud(row)
                    Button("Info", systemImage: "info.circle") { details = row }
                }
        }
    }

    /// Whether a reply is in the live turn, and whether it may still stream there (its turn's newest item, not
    /// complete): such a reply types out (`ChatTypingReveals`), and so does thinking that streams in (Pi's).
    private func streaming(_ row: ChatThreadRow) -> (live: Bool, ended: Bool) {
        let typed = switch row.kind { case .agent, .thinking: true; default: false }
        guard typed, let open = session.transcript.openTurn, open.id == row.turnID else { return (false, true) }
        return (true, row.item.completed || open.items.last?.id != row.item.id)
    }

    /// A reply's corner and its time on the swipe (`ChatCorner.swiped`); a thinking bubble has neither.
    private func swiped(_ row: ChatThreadRow, summary: ChatTurnSummary?) -> (corner: ChatCorner?, time: String?) {
        guard case .agent = row.kind else { return (nil, nil) }
        return ChatCorner.swiped(time: row.time, summary: summary, now: today,
                                 metrics: ChatCornerMetrics(column: column, measure: measure, size: typeSize))
    }

    /// A user's message's time, which the swipe brings in after it (`ChatRevealSent`).
    private func sentCorner(_ row: ChatThreadRow) -> ChatCorner? {
        ChatCorner.reply(time: row.time, summary: nil, now: today,
                         metrics: ChatCornerMetrics(column: column, measure: measure, size: typeSize))
    }

    /// A notice row's text, with the search's marks.
    @ViewBuilder private func notice(_ text: String, row: String) -> some View {
        if session.search.active,
           var marker = ChatSearchMarker(ChatSearchMarks(query: session.search.query.trimmingCharacters(in: .whitespacesAndNewlines)),
                                         current: currentMatch?.row == row ? currentMatch?.occurrence : nil) {
            Text(marker.mark(text))
        } else {
            Text(text)
        }
    }

    @ViewBuilder private var notices: some View {
        if session.approvalInTerminal, session.phase == .verified {
            ChatNote(text: "Codex is asking for approval in its terminal. To get its approvals here, pick Trust all under “Hooks need review” there.")
        }
        // Not for a terminal nobody asked for yet (a warm session's, attached as its thread shows: one frame).
        if session.phase == .verified, !session.terminalAttached, !session.defersTerminal {
            ChatNote(text: "Attaching the terminal… messages wait in the queue until it shows.")
        }
        if case .paused(let reason) = session.phase {
            ChatNote(text: reason)
        }
        if let result = session.commandResult {
            ChatNote(text: result.title + (result.text.isEmpty ? "" : "\n" + result.text))
                .onTapGesture { session.commandResult = nil }
        }
        if let failure = session.failure {
            ChatNote(text: failure)
                .onTapGesture { session.failure = nil }
        }
    }

    /// The thread in order: rows, with each approval after the turn that holds its tool call (the Mac's placement),
    /// else after the turn that was last when it arrived, else at the end. A pending one stays last, where it is answered;
    /// a decided one whose turn is not loaded waits for that earlier history instead of sitting at the end.
    private func entries(_ rows: [ChatThreadRow]) -> [Entry] {
        var placed: [String: [MobileChatSession.Approval]] = [:]
        var unplaced: [MobileChatSession.Approval] = []
        let turns = session.transcript.turns
        for approval in session.approvals {
            let owner = approval.pending.turnID.flatMap { id in turns.contains { $0.id == id } ? id : nil }
                ?? approval.pending.toolItemID.flatMap { item in turns.first { $0.items.contains { $0.id == item } }?.id }
            if let owner, rows.contains(where: { $0.turnID == owner }) { placed[owner, default: []].append(approval) }
            else if !approval.pending.pending, let anchor = approval.anchor, rows.contains(where: { $0.turnID == anchor }) {
                placed[anchor, default: []].append(approval)
            } else if !approval.pending.pending, approval.anchor != nil {
                continue
            } else { unplaced.append(approval) }
        }
        var result: [Entry] = []
        for (index, row) in rows.enumerated() {
            result.append(.row(row))
            if index == rows.count - 1 || rows[index + 1].turnID != row.turnID {
                result += (placed.removeValue(forKey: row.turnID) ?? []).map(Entry.approval)
            }
        }
        return result + unplaced.map(Entry.approval)
    }

    /// How tall the rows a thread opens on are, by `estimatedHeight`: two tall screens, so the thread fills at once and
    /// scrolls up a while before drawing more. Each time the top comes near, `olderRows` more draw.
    static let openingHeight: CGFloat = 2000
    static let olderRows = 20

    /// The index of the oldest entry drawn (`firstShown`), the opening rows until one is pinned or when the pinned row is
    /// gone (another conversation, a replaced transcript).
    private func shownStart(_ entries: [Entry]) -> Int {
        if startsAtTop { return 0 }
        if let firstShown, let index = entries.firstIndex(where: { $0.id == firstShown }) { return index }
        // Opening where the thread was read: from that row (`restoreReading`), before `onAppear` pins it.
        if !opened, let row = Self.restorable(session.readingPosition, in: entries),
           let index = entries.firstIndex(where: { $0.id == row }) {
            return min(index, Self.tailStart(entries.map(Self.estimatedHeight)))
        }
        return Self.tailStart(entries.map(Self.estimatedHeight))
    }

    /// Where the rows the thread opens on start: the last ones whose heights (`estimatedHeight`) add up to
    /// `openingHeight`.
    static func tailStart(_ heights: [CGFloat]) -> Int {
        var total: CGFloat = 0
        for index in heights.indices.reversed() {
            total += heights[index]
            if total >= openingHeight { return index }
        }
        return 0
    }

    /// A rough height for an entry before it is drawn, at the phone's default text size: about 40 characters to a line
    /// of 21 points, plus the bubble's padding and the spacing; an approval card a fixed 200.
    private static func estimatedHeight(_ entry: Entry) -> CGFloat {
        guard case .row(let row) = entry else { return 200 }
        let lines = row.item.text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + 39) / 40) }
        return CGFloat(lines) * 21 + 26
    }

    /// Pins the oldest row drawn, so rows arriving at the end add to what is drawn instead of moving its top.
    private func pinFirstShown(_ entries: [Entry]) {
        guard !startsAtTop, !entries.isEmpty else { return }
        if let firstShown, entries.contains(where: { $0.id == firstShown }) { return }
        var start = Self.tailStart(entries.map(Self.estimatedHeight))
        if let row = restoring?.row, let index = entries.firstIndex(where: { $0.id == row }) { start = min(start, index) }
        // A row, not an approval: approvals move between turns as their turns load.
        let row = entries[start...].first { if case .row = $0 { true } else { false } } ?? entries[start]
        firstShown = row.id
    }

    /// The rows' coordinate space: the scroll view's content, its top at the content's top.
    static let contentSpace = "chat-thread-content"

    /// The place being put back (`ChatFollower.restoring`), while it is.
    /// Before the view opens: the session's saved place, when its row is still there (the opening layout reads it).
    private var restoring: ChatReadingPosition? {
        guard !opened else { return follower.restoring }
        guard !startsAtTop, let position = session.readingPosition,
              session.transcript.rows.contains(where: { $0.id == position.row }) else { return nil }
        return position
    }

    /// The saved place's row when it can be put back: not at the thread's end, and its row still in the transcript.
    private static func restorable(_ position: ChatReadingPosition?, in entries: [Entry]) -> String? {
        guard let position, entries.contains(where: { $0.id == position.row }) else { return nil }
        return position.row
    }

    /// Opens where the thread was read (`MobileChatSession.readingPosition`): drawn from that row, scrolled to it
    /// (`applyReading`), not following; what came at the end meanwhile counts into the jump button. Without a place, or with
    /// its row gone, the thread opens at its end.
    private func restoreReading(_ rows: [ChatThreadRow]) {
        guard !startsAtTop, let position = session.readingPosition,
              Self.restorable(position, in: entries(rows)) != nil else { return }
        follower.restoring = position
        updateFollow { follow in
            follow.leave()
            follow.appended(Self.appended(rows, after: position.last))
        }
        // The first layouts settle within a moment; after that the place is the user's to move.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if follower.restoring == position { follower.restoring = nil; saveReading() }
        }
    }

    /// Scrolls so the saved row sits where it did: its top `into` points above the visible top. At the end, the thread
    /// follows it again (`ChatFollow.moved`).
    private func applyReading() {
        guard let position = follower.restoring, let frame = follower.rowFrames[position.row],
              let scroll = follower.scrollView, scroll.contentSize.height > 0 else { return }
        let top = -scroll.adjustedContentInset.top
        let bottom = max(top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        let target = min(max(frame.minY + position.into + top, top), bottom)
        if abs(scroll.contentOffset.y - target) > 0.5 { scroll.contentOffset.y = target }
    }

    /// The scroll view came into its window. Its layouts before went unread (`ChatFollower.attached`): on a busy phone
    /// the bars' inset of a push arrives in one of them and lowers the offset, with nothing changing after to tell. The
    /// thread is put where it shows: the place being put back, else its end while it follows; an offset from before is
    /// no scroll of the user's.
    private func attached() {
        // In the window, in the layout of the thread's first frame: what the helper sent meanwhile applies, and a
        // terminal deferred for this showing attaches, just after that frame is committed (`firstFrameShown`), not
        // inside it. The view's `onAppear` can come earlier, before the window (a push over an existing screen).
        if session.waitsForFirstFrame {
            let session = session
            DispatchQueue.main.async { session.firstFrameShown() }
        }
        updateFollow { $0.attached() }
        guard let scroll = follower.scrollView, scroll.contentSize.height > 0 else { return }
        if follower.restoring != nil { return applyReading() }
        guard shownFollow.following else { return }
        let end = max(-scroll.adjustedContentInset.top,
                      scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        if scroll.contentOffset.y < end - 0.5 { scroll.contentOffset.y = end }
    }

    /// While the thread follows its end and nothing else moves it (no finger, no fling, the button's animated scroll, a
    /// place being put back), puts it exactly at its end: its last row's bottom at the composer, not a few points (or the
    /// 40 the follow lets pass as "at the end") above. False without a laid-out scroll view.
    @discardableResult
    private func pinToEnd() -> Bool {
        guard let scroll = follower.scrollView, scroll.window != nil, scroll.contentSize.height > 0 else { return false }
        let follow = follower.model ?? ChatFollow(following: !startsAtTop)
        guard follower.restoring == nil, follow.following, !follow.dragging, !follow.scrollingToEnd,
              !scroll.isTracking, !scroll.isDecelerating else { return true }
        let end = max(-scroll.adjustedContentInset.top,
                      scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        if abs(scroll.contentOffset.y - end) > 0.5 { scroll.contentOffset.y = end }
        return true
    }

    /// Keeps where the thread is being read (`MobileChatSession.readingPosition`): the first row drawn whose bottom is
    /// below the visible top, and how far it is scrolled past; nothing while the thread follows its end.
    private func saveReading() {
        guard !startsAtTop else { return }
        guard !shownFollow.following, !follower.atEnd else {
            session.readingPosition = nil
            return
        }
        guard let scroll = follower.scrollView else { return }
        let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
        let entries = entries(session.transcript.rows)
        let drawn = entries[shownStart(entries)...]
        guard let (row, frame) = drawn.lazy.compactMap({ entry -> (String, CGRect)? in
            guard case .row = entry, let frame = follower.rowFrames[entry.id] else { return nil }
            return (entry.id, frame)
        }).first(where: { $0.1.maxY > top }) else { return }
        session.readingPosition = ChatReadingPosition(row: row, into: top - frame.minY, last: session.transcript.rows.last?.id)
    }

    /// The top of what is drawn is near (`ChatFollower.nearTop`): older rows are drawn, else the helper's earlier page is
    /// asked for. Once laid out (`grew`), the rows in view are where they were, and a top still near (short rows) draws
    /// on.
    private func reachedTop() {
        guard !follower.growing else { return }
        let entries = entries(session.transcript.rows)
        let start = shownStart(entries)
        guard start > 0 else {
            session.loadEarlier()
            return
        }
        let above = entries[max(0, start - Self.olderRows)..<start]
        follower.growing = true
        firstShown = (above.first { if case .row = $0 { true } else { false } } ?? above.first)?.id
    }

    /// Older rows were laid out above (`reachedTop`), `delta` taller. Following, the end stays in view (the size-change
    /// anchor); else the scroll view keeps its offset, which moves by what was drawn, so the rows being read stay put,
    /// also under a finger still dragging. A top still near (short rows) draws on (its geometry is told after this).
    private func grew(by delta: CGFloat) {
        guard follower.growing else { return }
        follower.growing = false
        if !shownFollow.following, delta > 0, let scroll = follower.scrollView { scroll.contentOffset.y += delta }
        // The scroll view's own offset, not only the last near-top change told: SwiftUI drops geometry changes that
        // come several to a frame, and a top no longer near drew on to the transcript's start and asked for its page.
        Task { if follower.nearTop, follower.nearTopNow { reachedTop() } }
    }

    private enum Entry: Identifiable {
        case row(ChatThreadRow)
        case approval(MobileChatSession.Approval)
        var id: String {
            switch self { case .row(let row): row.id; case .approval(let approval): "approval-" + approval.id.uuidString }
        }
    }
}

/// A small centred note in the thread (paused input, hints, failures).
struct ChatNote: View {
    let text: String
    @Environment(\.chatMeasure) private var measure
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            // Centred at the readable measure in a wide column.
            .frame(maxWidth: measure)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}

/// M3b: a fresh chat shows who you are talking to and the settings this turn will use, as a line that opens the pickers.
struct ChatIntro: View {
    let session: MobileChatSession
    let space: String
    let directory: String?
    var homes = HomePath(account: nil)
    let pick: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(Color.bubbleAgent, in: Circle())
                .accessibilityHidden(true)
            Text("\(session.agentKey ?? "Agent") in \(space)")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Button(action: pick) {
                HStack(spacing: 5) {
                    Text([session.modelLabel ?? session.model, session.effort].compactMap { $0 }.joined(separator: " · ")
                        .nilIfEmpty ?? "Model and effort")
                    Text("›").font(.subheadline).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                .scaledFont(14, relativeTo: .subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 13)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -13)
            .accessibilityHint("Chooses the model and effort")
            .disabled(session.phase != .verified)
            if let directory {
                (Text("Runs in ") + Text(homes.abbreviate(directory)).font(.footnote.monospaced())
                    + Text(" on \(session.hostName) with the tools the space allows."))
                    .scaledFont(14, relativeTo: .subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 18)
    }
}

extension EnvironmentValues {
    /// How long a thread rides out the moment after the agent stops or its turn ends (`ChatThreadView.settling`);
    /// tests set it to take the clock out of their checks.
    @Entry var chatSettle: TimeInterval = 3
}

/// `ChatThreadView`'s follow state, outside SwiftUI's state (it changes with every scrolled frame).
@MainActor final class ChatFollower {
    var model: ChatFollow?
    /// The thread's end is in view (within 40 points).
    var atEnd = true
    /// The thread is scrolled to within half a screen of its top (`ChatThreadView.reachedTop`).
    var nearTop = false
    /// Older rows are being drawn above (`ChatThreadView.reachedTop`, `grew`).
    var growing = false
    /// The thread's scroll view (`ChatScrollViewProbe`), whose offset follows rows drawn above.
    weak var scrollView: UIScrollView?
    /// The scroll view is in a window: the thread's scroll geometry is the one shown.
    var attached: Bool { scrollView?.window != nil }
    /// Within half a screen of the top as the scroll view lies now (`nearTop`'s measure, the insets left out).
    var nearTopNow: Bool {
        guard let scroll = scrollView, scroll.window != nil, scroll.contentSize.height > 0 else { return false }
        let insets = scroll.adjustedContentInset
        return scroll.contentOffset.y + insets.top < (scroll.bounds.height - insets.top - insets.bottom) / 2
    }
    /// The rows' frames in the content (`ChatThreadView.contentSpace`), as last laid out.
    var rowFrames: [String: CGRect] = [:]
    /// The place being put back as the thread opens (`ChatThreadView.restoreReading`), until the user scrolls or a
    /// moment has passed.
    var restoring: ChatReadingPosition?
}

/// Where a thread was being read (`MobileChatSession.readingPosition`): the row at the visible top, how far it was
/// scrolled past its top, and the last row then (rows after it came while the thread was away).
struct ChatReadingPosition: Equatable {
    let row: String
    let into: CGFloat
    let last: String?
}

/// Finds the thread's `UIScrollView` for `ChatFollower`, as `ChatKeyboardDragDismissal` finds it for its drag.
struct ChatScrollViewProbe: UIViewRepresentable {
    let follower: ChatFollower
    /// The scroll view came into a window (`ChatThreadView.attached`).
    let attached: () -> Void

    func makeUIView(context: Context) -> Probe { Probe(follower: follower, attached: attached) }
    func updateUIView(_ view: Probe, context: Context) { view.attached = attached }

    final class Probe: UIView {
        private weak var follower: ChatFollower?
        var attached: () -> Void

        init(follower: ChatFollower, attached: @escaping () -> Void) {
            self.follower = follower
            self.attached = attached
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            follower?.scrollView = view as? UIScrollView
            attached()
        }
    }
}

/// A sent message's way into the thread, the Mac's send flight in short: it rises from the composer, from under the
/// thread's bottom edge, growing out of its trailing corner as it fades in. Only its drawing moves: the thread lays it
/// out at once, so following the end and the rows around it are as without it.
struct ChatSendRise: Transition {
    /// The rise, a fade with Reduce Motion. The session sends outside any animation, so the transition brings its own.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity.animation(.easeOut(duration: 0.15)) : AnyTransition(ChatSendRise()).animation(.smooth(duration: 0.32))
    }

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : 0.92, anchor: .bottomTrailing)
            .offset(y: phase.isIdentity ? 0 : 44)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

/// What the thread's scroll geometry reports to `ChatFollow`: the offset and whether the end is in view.
struct ChatScrollSample: Equatable {
    var offset: CGFloat
    var atEnd: Bool
    /// The insets and the visible height: a change in them moves the offset without the user (`ChatFollow.moved`).
    var insets: EdgeInsets
    var height: CGFloat
    /// The content's height: rows drawn, grown or gone, which a following thread keeps its end through (`pinToEnd`).
    var content: CGFloat = 0
}
