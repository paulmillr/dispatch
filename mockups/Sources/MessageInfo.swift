import SwiftUI

// M1: an agent message's details (Mobile/Chat/ChatMessageDetails.swift, M5b) redesigned. The header names the agent
// and when it replied, the menu carries the message's actions, the quote is the whole raw message, the turn's facts
// follow (outcome, time, changes, tokens, the conversation's model), and long step lists fold: patches and failures
// stay, the runs between them fold into one row each. Where it ran is one caption at the end.

enum MessageInfoCase { case long, unfolded, short, interrupted }

struct MessageInfoScreen: View {
    var variant: MessageInfoCase = .long

    var body: some View {
        PushedShell(back: "app", title: "Claude", subtitle: {
            Text(variant == .interrupted ? "Today 10:41 · stopped" : "Today 10:32")
        }, trailing: {
            Menu {
                Button("Copy", systemImage: "doc.on.doc") {}
                Button("Reply", systemImage: "arrowshape.turn.up.left") {}
                Button("Share…", systemImage: "square.and.arrow.up") {}
                Divider()
                Button("Show in Terminal", systemImage: "apple.terminal") {}
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
        }, content: { details(MessageInfoData(variant)) })
    }

    private func details(_ data: MessageInfoData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MessageQuote(text: data.text)
                    .padding(.horizontal, 16).padding(.top, 8)
                // The outcome and when, as one line under what it answers.
                HStack(spacing: 6) {
                    switch data.status {
                    case .finished: Label("Finished", systemImage: "checkmark.circle.fill").foregroundStyle(Color.added)
                    case .stopped: Label("Stopped by you", systemImage: "stop.circle.fill").foregroundStyle(Color.caution)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(data.time).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.subheadline)
                .labelStyle(TightLabel())
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 14)
                MessageCard {
                    ForEach(Array(data.facts.enumerated()), id: \.offset) { index, fact in
                        if index > 0 { Hairline() }
                        fact
                    }
                }
                HStack(alignment: .lastTextBaseline) {
                    SectionHeader(title: "Steps", count: data.stepCount)
                    Spacer()
                    if data.folded {
                        Text("Show all").font(.footnote.weight(.medium)).foregroundStyle(Color.dispatchPink)
                            .padding(.horizontal, 16).padding(.bottom, 6)
                    }
                }
                MessageCard {
                    ForEach(Array(data.steps.enumerated()), id: \.offset) { index, entry in
                        if index > 0 { Hairline(inset: 50) }
                        entry
                    }
                }
                Text("mba2 › app › claude")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18).padding(.bottom, 28)
            }
        }
    }
}

/// The message quoted as a block quote, not a bubble: a bar on its leading edge, no fill, so it never reads as a card
/// beside the sections. Always whole and raw (the Markdown as the agent wrote it), one selection across all of it.
private struct MessageQuote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule().fill(Color.dispatchPink.opacity(0.55)).frame(width: 3)
            Text(verbatim: text)
                .font(.subheadline).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MessageCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.raisedRow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
    }
}

/// A fact: the name in secondary, the value in primary, an optional accessory under the value.
private struct Fact<Value: View>: View {
    let name: String
    var chevron = false
    @ViewBuilder var value: Value
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value.multilineTextAlignment(.trailing)
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .font(.subheadline)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(minHeight: 44)
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

/// The turn's tokens, and under them how full the context was after it: a thin bar with its share.
private struct TokensFact: View {
    let tokens: String
    let used: Double
    let label: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(tokens).monospacedDigit()
            HStack(spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.faintFill)
                        Capsule().fill(used > 0.8 ? Color.caution : Color.secondary).frame(width: proxy.size.width * used)
                    }
                }
                .frame(width: 72, height: 4)
                Text(label).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

enum StepKind {
    case read, search, run, patch, think
    var symbol: String {
        switch self {
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .run: "terminal"
        case .patch: "pencil.line"
        case .think: "brain"
        }
    }
    var label: String {
        switch self {
        case .read: "Read"
        case .search: "Search"
        case .run: "Run"
        case .patch: "Patch"
        case .think: "Thought"
        }
    }
}

/// A step: the kind as a glyph in a fixed column (its name for VoiceOver), the title monospaced, then the patch's
/// counts or failed, and a system chevron. Every step pushes its output, a patch its diff.
private struct StepRow: View {
    let kind: StepKind
    let title: String
    var add = 0
    var del = 0
    var failed: String? = nil
    var nested = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: failed == nil ? kind.symbol : "xmark.octagon")
                .font(.subheadline)
                .foregroundStyle(failed == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.destructive))
                .frame(width: 22)
            Text(title)
                .font(.system(size: 14, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let failed {
                Text(failed).font(.footnote).foregroundStyle(Color.destructive)
            } else if add + del > 0 {
                Counts(add: add, del: del, font: .system(size: 14, design: .monospaced))
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.leading, nested ? 40 : 16).padding(.trailing, 16)
        .frame(minHeight: 46)
    }
}

/// The steps between two shown ones, folded: what they did in words, how many, and a disclosure chevron that turns
/// when it opens in place.
private struct FoldRow: View {
    let summary: String
    let count: Int
    var open = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "ellipsis")
                .font(.subheadline).foregroundStyle(.tertiary)
                .frame(width: 22)
            Text(summary).font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            // A disclosure, not a push: it opens in place.
            Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }
}

private struct MessageInfoData {
    var text: String
    var status: Status = .finished
    var time = ""
    var folded = false
    var facts: [AnyView]
    var stepCount: Int
    var steps: [AnyView]

    init(_ variant: MessageInfoCase) {
        switch variant {
        case .short:
            text = "Right, the invoice.paid path has its own handler in src/routes/invoices.ts and bypasses the guard. Moving the check into a shared middleware so both routes get it."
            status = .finished
            time = "10:31 – 10:32 · 52 s"
            facts = Self.facts(files: 2, add: 4, del: 4,
                               tokens: "12.4k in · 820 out", context: 0.31, contextLabel: "31% of context")
            stepCount = 4
            steps = [
                AnyView(StepRow(kind: .read, title: "src/routes/invoices.ts")),
                AnyView(StepRow(kind: .read, title: "src/lib/stripe.ts")),
                AnyView(StepRow(kind: .patch, title: "src/lib/idempotent.ts", add: 2, del: 1)),
                AnyView(StepRow(kind: .patch, title: "src/routes/invoices.ts", add: 2, del: 3)),
            ]
        case .interrupted:
            text = "Moving the idempotency check into middleware. I've written the helper and started on the route, but the invoices tests need a running Stripe mock, so I'll"
            status = .stopped
            time = "10:38 – 10:41 · 2 min 40 s"
            facts = Self.facts(files: 1, add: 12, del: 2,
                               tokens: "31.0k in · 1.9k out", context: 0.52, contextLabel: "52% of context")
            stepCount = 9
            folded = true
            steps = [
                AnyView(FoldRow(summary: "Read 4 files, searched twice", count: 6)),
                AnyView(StepRow(kind: .patch, title: "src/lib/idempotent.ts", add: 12, del: 2)),
                AnyView(StepRow(kind: .run, title: "npm test -- invoices", failed: "stopped")),
                AnyView(StepRow(kind: .read, title: "test/setup/stripe-mock.ts")),
            ]
        case .long, .unfolded:
            text = """
            Done. The `invoice.paid` path had its own handler in `src/routes/invoices.ts` that ran **before** the guard, \
            so a retried event was charged twice.

            - Moved the idempotency check into a shared middleware (`src/middleware/guard.ts`), mounted ahead of both routes.
            - Keys now come from the event id, which Stripe keeps stable across retries.
            - Fixed a stale fixture that still used request ids; the full suite passes (214 tests).

            One thing to decide: replays are rejected with `200`, not `409`, so Stripe stops retrying. Tell me if you'd \
            rather surface them.
            """
            status = .finished
            time = "10:28 – 10:32 · 4 min 12 s"
            facts = Self.facts(files: 3, add: 18, del: 7,
                               tokens: "48.2k in · 3.1k out", context: 0.63, contextLabel: "63% of 250k context")
            stepCount = 31
            folded = true
            let open = variant == .unfolded
            var rows: [AnyView] = [
                AnyView(FoldRow(summary: "Read 5 files, searched 3 times", count: 8)),
                AnyView(StepRow(kind: .patch, title: "src/lib/idempotent.ts", add: 12, del: 2)),
                AnyView(StepRow(kind: .patch, title: "src/routes/invoices.ts", add: 4, del: 5)),
                AnyView(FoldRow(summary: "Ran 2 commands, read 1 file", count: 3, open: open)),
            ]
            if open {
                rows += [
                    AnyView(StepRow(kind: .run, title: "npx tsc --noEmit", nested: true)),
                    AnyView(StepRow(kind: .read, title: "test/fixtures/invoice-paid.json", nested: true)),
                    AnyView(StepRow(kind: .run, title: "git diff --stat", nested: true)),
                ]
            }
            rows += [
                AnyView(StepRow(kind: .run, title: "npm test -- invoices", failed: "exit 1")),
                AnyView(FoldRow(summary: "Read 3 files", count: 3)),
                AnyView(StepRow(kind: .patch, title: "src/middleware/guard.ts", add: 2)),
                AnyView(FoldRow(summary: "Ran 5 commands, read 7 files", count: 12)),
                AnyView(StepRow(kind: .run, title: "npm test")),
            ]
            steps = rows
        }
    }

    enum Status { case finished, stopped }

    private static func facts(files: Int, add: Int, del: Int, tokens: String, context: Double,
                              contextLabel: String) -> [AnyView] {
        [
            AnyView(Fact(name: "Changes", chevron: true) {
                HStack(spacing: 8) {
                    Text(files == 1 ? "1 file" : "\(files) files")
                    Counts(add: add, del: del)
                }
            }),
            AnyView(Fact(name: "Tokens") { TokensFact(tokens: tokens, used: context, label: contextLabel) }),
            // The conversation's model now, which a turn before a switch did not necessarily use.
            AnyView(Fact(name: "Model") { Text("Fable 5.1 · high") }),
        ]
    }
}
