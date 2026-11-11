import SwiftUI

// The states the Mac has that the first set left out: unavailable Files, the post-send Undo, an outdated comment,
// a fold in the diff, and the way into Review from chat.

/// Files when the host cannot serve it: a plain SSH login (no helper), a login whose grant lacks files/git, or offline.
struct FilesUnavailableScreen: View {
    enum Reason { case noHelper, noGrant, offline }
    let reason: Reason

    var body: some View {
        if reason == .offline {
            HybridShell(mode: .review, hasAccessory: true) {
                HStack(spacing: 4) {
                    Text(MockGit.branch).font(.subheadline.weight(.semibold))
                    Text("· 8 files").font(.subheadline).foregroundStyle(.secondary)
                }
                .lineLimit(1)
            } trailing: {
                BarButton(symbol: "magnifyingglass")
            } accessory: {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.slash")
                    Text("mba2 is offline").font(.body.weight(.semibold)).lineLimit(1).fixedSize()
                    Text("2m ago").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text("Reconnect").font(.subheadline.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                }
                .foregroundStyle(Color.caution)
                .padding(.horizontal, 16)
            } content: {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach([MockChange.Area.staged, .unstaged, .untracked], id: \.rawValue) { area in
                            let rows = MockGit.changes.filter { $0.area == area }
                            SectionHeader(title: area.rawValue, count: rows.count)
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, change in
                                    ChangeRow(change: change, last: index == rows.count - 1)
                                }
                            }
                            .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 12)
                        }
                    }
                    .opacity(0.45)
                }
            }
        } else {
            // No bar: the tab has no git modes to offer, so the capsule's Files segment shows the explanation alone.
            NavigationStack {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: reason == .noHelper ? "shippingbox" : "lock.shield")
                        .font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                    Text(reason == .noHelper ? "Files needs the helper on mba2" : "Files is not allowed on mba2")
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    Text(reason == .noHelper
                         ? "This login is plain SSH. Install the helper to browse files, review changes and read the log."
                         : "The helper runs here, but its integration does not grant reading files or git. Change it to allow Files.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                    HStack(spacing: 10) {
                        Text("Not now").font(.body.weight(.semibold)).padding(.horizontal, 18).frame(height: 44)
                            .glassEffect(.regular.interactive(), in: Capsule())
                        Text(reason == .noHelper ? "Install helper…" : "Change integration…")
                            .font(.body.weight(.semibold)).foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 18).frame(height: 44)
                            .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
                    }
                    .padding(.top, 8)
                    Spacer()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { CapsuleTabHeader(title: "Sidebar theme toggle", state: ModeButtonState(shown: .files, agent: true)) }
            }
        }
    }
}

/// Review just after Send: the comments are gone from the list, the accessory says so with Undo for six seconds.
struct ReviewSentScreen: View {
    var body: some View {
        HybridShell(mode: .review, hasAccessory: true) {
            HStack(spacing: 4) {
                Text(MockGit.branch).font(.subheadline.weight(.semibold))
                Text("· 8 files").font(.subheadline).foregroundStyle(.secondary)
                Counts(add: MockGit.additions, del: MockGit.deletions, font: .system(.subheadline, design: .monospaced))
            }
            .lineLimit(1)
        } trailing: {
            BarButton(symbol: "magnifyingglass")
        } accessory: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.added)
                Text("Sent to claude").font(.body.weight(.semibold))
                Text("3 comments").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("Undo").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink)
            }
            .padding(.horizontal, 16)
        } content: {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach([MockChange.Area.staged, .unstaged, .untracked], id: \.rawValue) { area in
                        let rows = MockGit.changes.filter { $0.area == area }
                        SectionHeader(title: area.rawValue, count: rows.count)
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, change in
                                ChangeRow(change: change, showComments: false, last: index == rows.count - 1)
                            }
                        }
                        .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 12)
                    }
                }
            }
        }
    }
}

/// The diff with a fold and an outdated comment: the file changed under the comment since it was written, so its
/// quote no longer matches; the card says so and offers to drop it or keep it as a file comment.
struct DiffFoldOutdatedScreen: View {
    static let rowHeight: CGFloat = 20
    private let lines = MockGit.sidebarDiff
    private let foldAfter = 10   // rows of hunk 1 shown before the fold

    var body: some View {
        PushedShell(back: "Review", title: "Sidebar.tsx") {
            HStack(spacing: 6) {
                Text("src/components").font(.system(.caption, design: .monospaced))
                Text("·")
                Text("M").font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(Color.caution)
                Counts(add: 14, del: 6, font: .system(.caption, design: .monospaced))
            }
        } trailing: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Detached comments first, as the Mac lists them: not in this view.
                    outdatedCard.padding(.top, 8)
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if index == foldAfter { fold }
                        DiffRow(line: line, selected: false)
                            .overlay { if line.new == 42 { commentedTint } }
                    }
                    Color.clear.frame(height: 80)
                }
                .padding(.top, 2)
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                HStack(spacing: 10) {
                    Picker("Show", selection: .constant(0)) { Text("Diff").tag(0); Text("Source").tag(1) }
                        .pickerStyle(.segmented).frame(width: 150)
                    Spacer()
                    Label("Comment", systemImage: "plus.bubble").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).frame(height: 44)
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
                .padding(.horizontal, 16).padding(.bottom, 4)
            }
        }
    }

    private var commentedTint: some View {
        Rectangle().fill(Color.stateUnread.opacity(0.12))
            .overlay(alignment: .leading) { Rectangle().fill(Color.stateUnread).frame(width: 3) }
            .overlay(alignment: .trailing) {
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble").font(.caption.weight(.semibold))
                    Text("1").font(.caption.weight(.bold))
                }
                .foregroundStyle(Color.stateUnread)
                .padding(.horizontal, 8).frame(height: 26)
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.trailing, 6)
            }
            .allowsHitTesting(false)
    }

    /// 28 unmodified lines between the hunks, a tap opens them; the chevrons expand ten at a time from either side.
    private var fold: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.up").font(.caption2.weight(.bold)).foregroundStyle(.secondary).frame(width: 28)
            Text("28 unmodified lines").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color.stateUnread)
            Spacer()
            Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary).padding(.trailing, 12)
        }
        .frame(height: 26)
        .background(Color.stateUnread.opacity(0.06))
        .overlay(Rectangle().fill(Color.stateUnread.opacity(0.25)).frame(height: 0.5), alignment: .top)
        .overlay(Rectangle().fill(Color.stateUnread.opacity(0.25)).frame(height: 0.5), alignment: .bottom)
    }

    private var outdatedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.caution)
                Text("Outdated").font(.subheadline.weight(.semibold))
                Text("· was lines 12–14").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            Text("  const media = window.matchMedia(\"(prefers-color-scheme: dark)\");")
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 6))
            Text("Listen for the media change too; the toggle shows stale state after a system switch.").font(.subheadline)
            Text("The lines this comment quoted are no longer in the file.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label("Keep for the file", systemImage: "doc.text").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).frame(height: 30).background(Color.chipFill, in: Capsule())
                Label("Delete", systemImage: "trash").font(.caption.weight(.semibold)).foregroundStyle(Color.destructive)
                    .padding(.horizontal, 10).frame(height: 30).background(Color.chipFill, in: Capsule())
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.caution.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

/// A message as the app's `ChatBubble` draws it: callout in SF Rounded (Settings' chat font and size by default),
/// 20-point corners with a 6-point one at the speaker's bottom, the user's in the accent on the right (78% of the
/// column at most), the agent's grey on the left (86%). Nothing in the corner: times come in on a swipe.
struct Bubble: View {
    let text: String
    let user: Bool
    var body: some View { MessageBubble(user: user) { Text(text) } }
}

struct MessageBubble<Content: View>: View {
    let user: Bool
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 0) {
            if user { Spacer(minLength: 0) }
            content
                .font(.system(.callout, design: .rounded))
                .lineSpacing(2)
                .foregroundStyle(user ? Color("BubbleUserText") : .primary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(user ? Color("BubbleUser") : Color.bubbleAgent,
                            in: UnevenRoundedRectangle(cornerRadii: user
                                ? .init(topLeading: 20, bottomLeading: 20, bottomTrailing: 6, topTrailing: 20)
                                : .init(topLeading: 20, bottomLeading: 6, bottomTrailing: 20, topTrailing: 20),
                                style: .continuous))
                .frame(maxWidth: 370 * (user ? 0.78 : 0.86), alignment: user ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !user { Spacer(minLength: 0) }
        }
    }
}
