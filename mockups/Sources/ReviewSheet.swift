import SwiftUI

/// The Create review sheet, second pass: a "To" row naming the agent, comments with their quoted line, the overall
/// comment with dictation, and the actions pinned at the bottom as glass over the content.
struct CreateReviewSheet: View {
    /// No agent in this tab: Copy is the action, the To row explains.
    var agent = true
    /// The second comment swiped open, Delete showing.
    var swiped = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if agent { toRow } else { noAgentRow }
                    SectionHeader(title: "3 comments · 2 files")
                    VStack(spacing: 0) {
                        ForEach(Array(MockGit.comments.enumerated()), id: \.element.id) { index, c in
                            commentRow(c, index: index)
                                .background(Color.raisedRow)
                                .offset(x: swiped && index == 1 ? -92 : 0)
                                .background(alignment: .trailing) {
                                    if swiped, index == 1 {
                                        VStack(spacing: 4) {
                                            Image(systemName: "trash.fill").font(.body.weight(.semibold))
                                            Text("Delete").font(.caption2.weight(.semibold))
                                        }
                                        .foregroundStyle(.white).frame(width: 92).frame(maxHeight: .infinity)
                                        .background(Color.destructive)
                                    }
                                }
                                .clipped()
                            if index < MockGit.comments.count - 1 { Hairline().background(Color.raisedRow) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12)

                    SectionHeader(title: "Overall")
                    HStack(alignment: .top) {
                        Text(agent ? "Anything else for claude?" : "Anything else?").font(.body).foregroundStyle(.tertiary)
                        Spacer()
                        Image(systemName: "mic").font(.body).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 56, alignment: .topLeading)
                    .padding(12)
                    .background(Color.raisedRow, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12)

                    Text(agent ? "Sent as one message. The comments clear afterwards; Undo brings them back for a minute."
                               : "Copied as markdown for pasting into any agent. The comments clear afterwards; Undo brings them back for a minute.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) { actions }
            .background(Color.canvas)
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { } label: { Image(systemName: "xmark") } }
            }
        }
    }

    private var toRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.dispatchPink)
                .frame(width: 40, height: 40).background(Color.dispatchPink.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("To").foregroundStyle(.secondary)
                    Text("claude").fontWeight(.semibold)
                }
                .font(.body)
                Text("this tab · web · fable-5.1").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.raisedRow, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12).padding(.top, 6)
    }

    private var noAgentRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble").font(.system(size: 16, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 40, height: 40).background(Color.faintFill, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("No agent in this tab").font(.body.weight(.semibold))
                Text("Copy the review, or send it to codex · api").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.raisedRow, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12).padding(.top, 6)
    }

    private func commentRow(_ c: MockGit.Comment, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill").font(.caption).foregroundStyle(Color.stateUnread)
                Text((c.path as NSString).lastPathComponent).font(.subheadline.weight(.semibold))
                Text(c.lineEnd.map { "\(c.line)–\($0)" } ?? "\(c.line)")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            Text(Self.quote[index])
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 6))
            Text(c.text).font(.subheadline).lineLimit(2)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if agent {
                Image(systemName: "doc.on.doc").font(.body.weight(.semibold)).frame(width: 50, height: 50)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            Image(systemName: "eye").font(.body.weight(.semibold)).frame(width: 50, height: 50)
                .glassEffect(.regular.interactive(), in: Circle())
            HStack(spacing: 8) {
                Image(systemName: agent ? "paperplane.fill" : "doc.on.doc.fill")
                Text(agent ? "Send to claude" : "Copy review")
            }
            .font(.body.weight(.semibold)).foregroundStyle(Color.onAccent)
            .frame(maxWidth: .infinity).frame(height: 50)
            .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Capsule())
        }
        .padding(.horizontal, 16).padding(.bottom, 4)
    }

    static let quote = [
        "<nav className={`sidebar sidebar--${theme}`}>",
        "<li key={space.id} className={space.unread ? \"unread\" : \"\"}>",
        "const options = [\"light\", \"dark\", \"system\"];",
    ]
}

struct ReviewSheetHost: View {
    var agent = true
    var swiped = false
    var body: some View {
        HybridReviewScreen()
            .sheet(isPresented: .constant(true)) {
                CreateReviewSheet(agent: agent, swiped: swiped)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }
}
