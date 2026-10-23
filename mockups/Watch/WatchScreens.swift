import SwiftUI

// MARK: K1 the Agents list

/// The Agents list with the phone's new row grammar: the agent's glyph, the conversation title, the line that follows
/// the state, the blue/amber dot. Host · space and the time sit in a caption so one list can span hosts.
struct AgentsListScreen: View {
    var scrolled = false
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                ForEach(Mock.conversations) { c in
                    HStack(alignment: .top, spacing: 5) {
                        Dot(color: c.dot).padding(.top, 4)
                        AgentGlyph(kind: c.agent, size: 13).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(c.line)
                                .font(.caption)
                                .foregroundStyle(c.dot == .stateUnread ? Color.primary : .secondary)
                                .lineLimit(2)
                            HStack(spacing: 4) {
                                Text("\(Mock.host) · \(Mock.space)").foregroundStyle(Color.hostTint)
                                Spacer(minLength: 2)
                                Text(c.time).foregroundStyle(.tertiary)
                            }
                            .font(.caption2)
                        }
                    }
                    .padding(.vertical, 1)
                    .id(c.id)
                }
            }
            .onAppear {
                guard scrolled else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo(Mock.conversations.last!.id, anchor: .bottom) }
            }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("1").font(.footnote.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                        .background(Color.stateUnread, in: Capsule())
                }
            }
        }
    }
}

// MARK: K2 a thread

/// A finished turn: the last agent message in its bubble, the turn's footnote (steps, time, files, counts), Reply.
struct ThreadScreen: View {
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                HStack(spacing: 5) {
                    AgentGlyph(kind: "claude", size: 12)
                    Text("Claude Code · opus-5.5").font(.caption2).foregroundStyle(.secondary)
                }
                .modifier(BareRow())
                VStack(alignment: .leading, spacing: 3) {
                    AgentBubble {
                        Text("Added a ThemeToggle to the sidebar header and wired it to useTheme.")
                    }
                    (Text("5 steps in 1m 26s · 4 files ") + Text("+61").foregroundStyle(Color.added) + Text(" ")
                        + Text("−9").foregroundStyle(Color.destructive))
                        .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 6)
                }
                .modifier(BareRow())
                .id("card")
                CapsuleButton(title: "Reply", symbol: "mic.fill", style: .accent).modifier(BareRow(vertical: 6))
                CapsuleButton(title: "Open on iPhone", symbol: "iphone").modifier(BareRow())
                // watchOS 27 leaves a List's last row undrawn (the real ThreadScreen's note): an empty row takes that place.
                Color.clear.frame(height: 1).modifier(BareRow(vertical: 0)).id("end")
            }
            .environment(\.defaultMinListRowHeight, 0)
            // The thread opens at its newest item, as the real one does (ThreadScreen.anchor).
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("card", anchor: .top) } }
            }
            .navigationTitle("Sidebar theme toggle")
        }
    }
}

// MARK: K3 an approval

/// The approval card: what the agent asks, the command in mono on the code panel, how long it has waited; Allow in the
/// accent, Deny red.
struct ApprovalScreen: View {
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Text("Codex · gpt-5-codex").font(.caption2).foregroundStyle(.secondary).modifier(BareRow())
                VStack(alignment: .leading, spacing: 3) {
                    AgentBubble {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                AgentGlyph(kind: "codex", size: 11)
                                Text("Codex wants to run").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text("cargo test --workspace")
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .padding(.horizontal, 7).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.approvalCode, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                    Text("Waiting · 2m").font(.caption2).foregroundStyle(.tertiary).padding(.leading, 6)
                }
                .modifier(BareRow())
                .id("card")
                CapsuleButton(title: "Allow", style: .accent).modifier(BareRow(vertical: 4))
                CapsuleButton(title: "Deny", style: .destructive).modifier(BareRow())
                Color.clear.frame(height: 1).modifier(BareRow(vertical: 0)).id("end")
            }
            .environment(\.defaultMinListRowHeight, 0)
            // Opens at the request waiting, as the real thread does.
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("card", anchor: .top) } }
            }
            .navigationTitle("Rate limiter for the API")
        }
    }
}

// MARK: K4 a question

/// A question with its options as list rows (one choice: circles), the phone's AskUserQuestion on the wrist.
struct QuestionScreen: View {
    let options = [("Sidebar header", "next to the space name"), ("Settings page", "under Appearance"), ("Both", "")]
    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where should the toggle live?").font(.footnote)
                    Text("1 of 2").font(.caption2).foregroundStyle(.tertiary)
                }
                .modifier(BareRow(vertical: 4))
                ForEach(options, id: \.0) { option in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.0).font(.body)
                            if !option.1.isEmpty { Text(option.1).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: option.0 == "Sidebar header" ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(option.0 == "Sidebar header" ? Color.dispatchPink : .secondary)
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "mic").foregroundStyle(.secondary)
                    Text("Dictate or type").foregroundStyle(.secondary)
                }
                CapsuleButton(title: "Next", style: .accent).modifier(BareRow(vertical: 6))
            }
            .navigationTitle("Question")
        }
    }
}

// MARK: K5 a reply by dictation

/// Dictation in progress: the words so far, a waveform placeholder for the system's dictation UI, Send and Cancel.
struct ReplyScreen: View {
    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 10) {
                Text("Use the sidebar header, and keep the setting in local storage")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.dispatchPink.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Waveform().frame(height: 30)
                Text("Listening…").font(.caption2).foregroundStyle(Color.dispatchPink)
                CapsuleButton(title: "Send", symbol: "arrow.up", style: .accent)
                CapsuleButton(title: "Cancel")
            }
            .padding(.horizontal, 2)
            }
            .navigationTitle("Reply")
        }
    }
}

/// Bars in the accent, the stand-in for the system dictation waveform.
struct Waveform: View {
    let heights: [CGFloat] = [4, 8, 14, 22, 16, 26, 12, 20, 28, 18, 10, 24, 14, 8, 18, 22, 12, 6, 16, 10, 4]
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Capsule().fill(Color.dispatchPink).frame(width: 3, height: h)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: K6 host stats

/// The host as a watch card: name, latency and the state dot on top, the Stocks-style stat strip, the sparkline.
/// Offline: the strip dimmed, "Offline since 2:02 PM", Connect.
struct HostScreen: View {
    let offline: Bool
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "apple.logo").font(.caption.weight(.semibold))
                            .foregroundStyle(offline ? Color.secondary : Color.hostTint)
                            .frame(width: 24, height: 24)
                            .background((offline ? Color.secondary : Color.hostTint).opacity(0.2), in: Circle())
                        Text("herdr").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: Capsule())
                        Spacer(minLength: 0)
                        Circle().fill(offline ? Color.secondary.opacity(0.5) : Color.stateConnected).frame(width: 6, height: 6)
                        Text(offline ? "Offline" : "18 ms").font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            stat("CPU", "34", "%")
                            divider
                            stat("Memory", "11", "GB")
                            divider
                            stat("Disk", "48", "GB", warn: true)
                        }
                        .padding(.vertical, 8)
                        if !offline {
                            Sparkline(bars: Mock.history).frame(height: 36).padding(.horizontal, 10)
                        }
                        if !offline {
                            HStack {
                                Text("CPU · 15 min")
                                Spacer()
                                Text("peak 82%")
                            }
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
                        }
                    }
                    .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .opacity(offline ? 0.5 : 1)
                    if offline {
                        HStack(spacing: 5) {
                            Image(systemName: "wifi.slash")
                            Text("Offline since 2:02 PM")
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.top, 2)
                        CapsuleButton(title: "Connect", symbol: "bolt.fill", style: .accent)
                    } else {
                        HStack(spacing: 4) {
                            Text("2 spaces · 5 tabs").foregroundStyle(.secondary)
                            Spacer()
                            Text("1").foregroundStyle(Color.stateUnread)
                            Circle().fill(Color.stateWorking).frame(width: 6, height: 6)
                        }
                        .font(.caption2).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 2)
            }
            .navigationTitle(Mock.host)
        }
    }

    private var divider: some View { Rectangle().fill(.quaternary).frame(width: 0.5, height: 30) }

    private func stat(_ title: String, _ value: String, _ unit: String, warn: Bool = false) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(warn ? Color.destructive : .primary)
                Text(unit).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: K7 complication note

/// Not a complication: a design note drawn as a screen. The Smart Stack's rectangular widget (two lines) and a corner
/// complication (the glyph and a count), both in the app's pink.
struct ComplicationNoteScreen: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rectangular (Smart Stack)").font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.dispatchPink)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Needs you · 2").font(.headline)
                            Text("Allow cargo test? · mba2").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("Corner").font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        CornerMock()
                        Text("Pink only while something needs you.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("Tap opens Agents on the first row that needs you.").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 2)
            }
            .navigationTitle("Complication")
        }
    }
}

/// A corner slot: the arc the face draws, the pink glyph in it, the count beside.
struct CornerMock: View {
    var body: some View {
        // The face's top-left corner: the arc along the bezel, the glyph in the corner, the count inside.
        ZStack(alignment: .topLeading) {
            Circle().trim(from: 0.5, to: 0.75)
                .stroke(Color.dispatchPink.opacity(0.4), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 104, height: 104)
                .offset(x: 2, y: 2)
            Image(systemName: "sparkle").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.dispatchPink)
                .offset(x: 11, y: 11)
            Text("2").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.primary)
                .offset(x: 31, y: 12)
        }
        .frame(width: 56, height: 50, alignment: .topLeading)
        .clipped()
    }
}

// MARK: K8 review sent

/// The phone's post-send state mirrored: "Review sent to claude · 3 comments" as a notification-style card with Undo.
struct ReviewSentScreen: View {
    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.added)
                        Text("Review sent").font(.headline)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 5) {
                        AgentGlyph(kind: "claude", size: 12)
                        Text("Sidebar theme toggle").font(.footnote).lineLimit(1)
                    }
                    Text("3 comments · 2 files").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                CapsuleButton(title: "Undo", symbol: "arrow.uturn.backward")
                Text("Sent from your iPhone. Undo for 8 s, then claude reads it.")
                    .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 2)
            }
            .navigationTitle("Review")
        }
    }
}
