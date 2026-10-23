import SwiftUI

struct RefChip: View {
    let name: String
    let kind: MockGit.Commit.Kind
    var color: Color {
        switch kind { case .current, .branch: .added; case .tag: .caution; case .remote: Color.secondary }
    }
    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(kind == .current ? Color.onAccent : color)
            .padding(.horizontal, 6).frame(height: 17)
            .background(kind == .current ? color : color.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(kind == .remote ? color.opacity(0.5) : .clear, lineWidth: 1))
            .lineLimit(1)
    }
}

/// C2: one commit, pushed from the log.
struct CommitDetailScreen: View {
    let commit = MockGit.commits[0]
    var body: some View {
        PushedShell(back: "Commits", title: commit.hash) {
            Text("\(commit.age) ago · \(commit.author)")
        } trailing: {
            Menu {
                Button("Copy hash", systemImage: "doc.on.doc") {}
                Button("Copy subject", systemImage: "text.quote") {}
                Divider()
                Button("Ask claude about this commit", systemImage: "bubble.left") {}
                Button("git show in Terminal", systemImage: "apple.terminal") {}
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
        } content: { CommitDetailBody(commit: commit) }
    }
}

/// The commit's body: pushed on the phone, a pane beside the log on an iPad.
struct CommitDetailBody: View {
    let commit: MockGit.Commit
    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(commit.subject).font(.title3.weight(.semibold))
                        Text(commit.body).font(.subheadline).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(Array(commit.refs.enumerated()), id: \.offset) { _, ref in RefChip(name: ref.0, kind: ref.1) }
                            if commit.signed {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark.seal.fill")
                                    Text("Signed · SSH key")
                                }
                                .font(.caption2.weight(.semibold)).foregroundStyle(Color.added)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 12).padding(.top, 8)
                    VStack(spacing: 0) {
                        DetailRow(label: "Author", value: "Alex Rivera")
                        Hairline()
                        DetailRow(label: "Date", value: "Today, 1:43 AM")
                        Hairline()
                        DetailRow(label: "Parent", value: "7d04e9b", mono: true)
                    }
                    .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 12).padding(.top, 12)
                    HStack(spacing: 6) {
                        SectionHeader(title: "Changed files", count: 4)
                        Counts(add: 61, del: 9, font: .system(.footnote, design: .monospaced)).padding(.top, 12)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(MockGit.commitFiles.enumerated()), id: \.element.id) { index, change in
                            ChangeRow(change: change, showComments: false, last: index == MockGit.commitFiles.count - 1)
                        }
                    }
                    .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 12)
                }
            }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var mono = false
    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(mono ? .system(.subheadline, design: .monospaced) : .subheadline)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}
