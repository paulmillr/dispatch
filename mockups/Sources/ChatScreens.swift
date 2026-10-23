import SwiftUI

// Chat: search, the slash-command list, side conversations, goal controls, conversation mode, jump to latest.

struct ChatShell<Content: View, Bottom: View, Overlay: View>: View {
    var title = "Billing webhook retries"
    var subtitle = "~/src/app"
    var badge: Int? = 3
    var trailing: AnyView = AnyView(HostDisc())
    @ViewBuilder var content: Content
    @ViewBuilder var bottom: Bottom
    @ViewBuilder var overlay: Overlay
    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .overlay { overlay }
                .safeAreaBar(edge: .top, spacing: 0) {
                    SegmentCapsule(selected: 1, badge: badge).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
                }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom) { bottom }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { TabHeader(title: title, subtitle: AnyView(HostPath(path: subtitle)), trailing: trailing) }
        }
    }
}

struct Transcript: View {
    var highlight: String? = nil
    var trailingSpace: CGFloat = 8
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Spacer(minLength: 60)
                Bubble(text: "Make billing webhook retries idempotent.", user: true)
                BubbleH(text: "Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process. I'll key on the event id instead and persist what we've seen.", highlight: highlight)
                foot("5 steps in 1m 26s · 2 files +38 −4")
                Bubble(text: "Also cover invoice.paid — it has a separate handler.", user: true)
                BubbleH(text: "Right, the invoice.paid path has its own handler in src/routes/invoices.ts and bypasses the guard. Moving the check into a shared middleware so both routes get it.", highlight: highlight)
                foot("4 steps in 52s · 3 files +61 −9")
                Color.clear.frame(height: trailingSpace)
            }
            .padding(.horizontal, 16)
        }
        .defaultScrollAnchor(.bottom)
    }
    private func foot(_ t: String) -> some View {
        Text(t).font(.footnote).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 22)
    }
}

/// An agent bubble with an optional highlighted word (search).
struct BubbleH: View {
    let text: String
    var highlight: String? = nil
    private var attributed: AttributedString {
        var a = AttributedString(text)
        if let highlight, let r = a.range(of: highlight, options: .caseInsensitive) {
            a[r].backgroundColor = Color.caution.opacity(0.9)
            a[r].foregroundColor = .black
        }
        return a
    }
    var body: some View {
        HStack {
            Text(attributed)
            .font(.body)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.bubbleAgent, in: RoundedRectangle(cornerRadius: 18))
            Spacer(minLength: 60)
        }
    }
}

struct Composer: View {
    var text: String = ""
    var placeholder = "Message"
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
            HStack {
                if text.isEmpty { Text(placeholder).foregroundStyle(.tertiary) } else { Text(text) }
                Spacer()
                Image(systemName: text.isEmpty ? "mic" : "arrow.up").foregroundStyle(text.isEmpty ? Color.secondary : Color.onAccent)
                    .font(text.isEmpty ? .body : .body.weight(.bold))
                    .frame(width: 30, height: 30).background(text.isEmpty ? Color.clear : Color.dispatchPink, in: Circle())
            }
            .padding(.leading, 16).padding(.trailing, text.isEmpty ? 16 : 7).frame(height: 44)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .padding(.horizontal, 16).padding(.bottom, 4)
    }
}

/// C1: search in the conversation. The composer becomes the search field; matches are bolded; arrows step through
/// them; "Searching earlier messages…" while older pages load.
struct ChatSearchScreen: View {
    var body: some View {
        ChatShell {
            Transcript(highlight: "guard")
        } bottom: {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text("guard")
                        Spacer()
                        Text("2 of 2").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    HStack(spacing: 0) {
                        Image(systemName: "chevron.up").frame(width: 40, height: 44)
                        Image(systemName: "chevron.down").frame(width: 40, height: 44)
                    }
                    .font(.body.weight(.semibold))
                    .glassEffect(.regular.interactive(), in: Capsule())
                    Text("Done").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                        .padding(.horizontal, 14).frame(height: 44).glassEffect(.regular.interactive(), in: Capsule())
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Searching earlier messages…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 4)
        } overlay: { EmptyView() }
    }
}

/// C2: the slash-command list, rising above the composer as "/" is typed.
struct ChatSlashScreen: View {
    let commands: [(String, String, String)] = [
        ("/compact", "Summarise the conversation to free context", "Claude Code"),
        ("/fork", "Continue in a new conversation from here", "Claude Code"),
        ("/goal", "Set a goal the agent keeps working toward", "Dispatch"),
        ("/btw", "Ask on the side, read-only, kept out of the thread", "Dispatch"),
        ("/side", "A side conversation with full permissions", "Dispatch"),
        ("/recap", "What happened since you last looked", "Dispatch"),
    ]
    var body: some View {
        ChatShell {
            Transcript()
        } bottom: {
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.offset) { i, c in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.0).font(.system(.body, design: .monospaced).weight(.semibold))
                                Text(c.1).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(c.2).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background { if i == 0 { Color.lens } }
                        if i < commands.count - 1 { Hairline() }
                    }
                }
                .background(Color.raisedRow, in: RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                .padding(.horizontal, 16)
                Composer(text: "/")
            }
        } overlay: { EmptyView() }
    }
}

/// C3: a side conversation, pushed: a separate thread with its own composer, a banner saying it is kept out of the
/// main one, "Back to main" as the back pill.
struct ChatSideScreen: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").font(.caption.weight(.semibold))
                        Text("Side conversation · read-only, kept out of the main thread").font(.caption)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 6)
                    Spacer(minLength: 300)
                    Bubble(text: "Which handler runs first for a retried invoice.paid event?", user: true)
                    Bubble(text: "The route handler in src/routes/invoices.ts runs before the shared middleware, because it is mounted on the router directly. The guard sees the event only on the second pass.", user: false)
                    foot("Read 3 files · 12s")
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 16)
            }
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .safeAreaBar(edge: .bottom) { Composer(placeholder: "Ask on the side") }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                TabHeader(title: "btw", subtitle: AnyView(Text("Billing webhook retries · claude").font(.caption)),
                          back: BackPill(count: nil, title: "Main"),
                          trailing: AnyView(Menu {
                              Button("Bring into main thread", systemImage: "arrow.turn.down.left") {}
                              Button("Allow changes (/side)", systemImage: "pencil") {}
                              Button("Copy", systemImage: "doc.on.doc") {}
                              Divider()
                              Button("End side conversation", systemImage: "xmark", role: .destructive) {}
                          } label: {
                              Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                                  .glassEffect(.regular.interactive(), in: Circle())
                          }.buttonStyle(.plain)))
            }
        }
    }
    private func foot(_ t: String) -> some View {
        Text(t).font(.footnote).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 22)
    }
}

/// C4: a goal in progress: a status strip under the header with Pause and Stop; the Manage goal sheet behind the menu.
struct ChatGoalScreen: View {
    var sheet = false
    var body: some View {
        ChatShell {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "flag.fill").foregroundStyle(Color.dispatchPink)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Goal · working").font(.subheadline.weight(.semibold))
                        Text("All webhook routes idempotent, tests green").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "pause.fill").font(.subheadline.weight(.semibold)).frame(width: 34, height: 34)
                        .glassEffect(.regular.interactive(), in: Circle())
                    Image(systemName: "stop.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Color.destructive).frame(width: 34, height: 34)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 12).padding(.top, 2)
                Transcript()
            }
        } bottom: {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("Turn 4 of the goal").font(.caption).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text("2 subagents").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("63% context").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 22)
                Composer()
            }
        } overlay: {
            if sheet { Color.black.opacity(0.4).ignoresSafeArea() }
        }
        .sheet(isPresented: .constant(sheet)) {
            NavigationStack {
                List {
                    Section("Goal") {
                        Text("All webhook routes idempotent, tests green").font(.body)
                    }
                    Section("Status") {
                        LabeledContent("Turns") { Text("4 · last 1m ago") }
                        LabeledContent("Stop after") { Text("20 turns") }
                        LabeledContent("Ask before") { Text("Commits, deletes") }
                    }
                    Section {
                        Button("Pause") {}
                        Button("Stop goal", role: .destructive) {}
                    }
                }
                .navigationTitle("Manage goal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") {} } }
            }
            .presentationDetents([.medium])
            .presentationBackground(Color.canvas)
        }
    }
}

/// C5: conversation mode: hands-free. The composer becomes a listening bar with a live waveform; the agent's reply is
/// read aloud (the speaker glyph on its bubble); a tap on the bar ends it.
struct ChatConversationScreen: View {
    var body: some View {
        ChatShell(trailing: AnyView(
            Image(systemName: "waveform").font(.system(size: 20)).foregroundStyle(Color.onAccent)
                .frame(width: 44, height: 44).glassEffect(.regular.tint(.dispatchPink).interactive(), in: Circle())
        )) {
            ScrollView {
                VStack(spacing: 10) {
                    Spacer(minLength: 200)
                    Bubble(text: "Also cover invoice.paid — it has a separate handler.", user: true)
                    HStack(alignment: .bottom, spacing: 6) {
                        Bubble(text: "Right, the invoice.paid path has its own handler and bypasses the guard. Moving the check into a shared middleware so both routes get it.", user: false)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Color.dispatchPink)
                        Text("Reading aloud · 0:08").font(.footnote).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.leading, 22)
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 16)
            }
            .defaultScrollAnchor(.bottom)
        } bottom: {
            VStack(spacing: 8) {
                Text("Listening · say “send” or pause to send").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Waveform().frame(height: 22)
                        Text("and add a test for the retry path").font(.body).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16).frame(height: 50)
                    .glassEffect(.regular.tint(.dispatchPink.opacity(0.35)).interactive(), in: Capsule())
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 50, height: 50)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .padding(.horizontal, 16).padding(.bottom, 4)
            }
        } overlay: { EmptyView() }
    }
}

struct Waveform: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<9, id: \.self) { i in
                Capsule().fill(Color.dispatchPink).frame(width: 3, height: [8, 14, 20, 12, 22, 10, 16, 8, 12][i])
            }
        }
    }
}

/// C6: scrolled up while the agent writes: a "Jump to latest" pill with the new-message count, over the thread.
struct ChatJumpScreen: View {
    var body: some View {
        ChatShell {
            ScrollView {
                VStack(spacing: 10) {
                    Bubble(text: "Make billing webhook retries idempotent.", user: true)
                    Bubble(text: "Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process. I'll key on the event id instead and persist what we've seen.", user: false)
                    Text("5 steps in 1m 26s · 2 files +38 −4").font(.footnote).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 22)
                    Bubble(text: "Also cover invoice.paid — it has a separate handler.", user: true)
                    Bubble(text: "Right, the invoice.paid path has its own handler in src/routes/invoices.ts and bypasses the guard.", user: false)
                    Bubble(text: "What about the Stripe CLI's replay command, does it reuse event ids?", user: true)
                    Bubble(text: "Yes, stripe events resend keeps the original id, so the guard treats it as a retry and skips it. That is what we want for replays of real events.", user: false)
                    Spacer(minLength: 300)
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            .defaultScrollAnchor(.top)
        } bottom: {
            Composer()
        } overlay: {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                    Text("Jump to latest")
                    Text("2").font(.caption.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 6).frame(height: 18).background(Color.stateUnread, in: Capsule())
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).frame(height: 40)
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.bottom, 12)
            }
        }
    }
}
