import SwiftUI

// iPad panes (docs/ios.md, iPad › Panes): the detail column as the Grid layout, four agents' chats in four panes,
// each with its own strip: the selected pill spanning the track and the space's others in the overflow pill, "+", the
// mode button's glyph alone in a column under 640 points, and in the top right pane's the layout button after it on
// one glass pill, its grid glyph in the accent, as the Mac's strip ends. The top left pane is focused; the others'
// strips are dimmed, as an inactive window's toolbar is, and their empty composers fold, as the Mac's unfocused panes':
// a glass Reply circle while the agent is idle, nothing but the working row while it works or the request's buttons
// while it asks.

private struct GridAgent {
    let title: String
    let kind: String
    var dot: Color? = nil
    /// The space's other tabs, in the overflow pill.
    let more: Int
    let prompt: String
    let reply: String
    let steps: String
    let state: State

    enum State { case working(String, String), approval(String), done }

    var working: Bool { if case .working = state { true } else { false } }
    var waiting: Bool { if case .approval = state { true } else { false } }
}

private let gridAgents: [GridAgent] = [
    .init(title: "Sidebar theme toggle", kind: "claude", dot: .stateWorking, more: 4,
          prompt: "Add a theme toggle to the sidebar and make the unread rows stand out.",
          reply: "Added ThemeToggle in the sidebar footer and a useTheme hook that follows the system preference.",
          steps: "5 steps in 1m 26s · 4 files +61 −9", state: .working("52s", "7 steps")),
    .init(title: "Rate limiter for the API", kind: "codex", dot: .stateUnread, more: 1,
          prompt: "Add a token bucket per API key, 100 requests a minute, and tests.",
          reply: "The limiter is in middleware/rate.rs with a bucket per key. I'd like to run the whole test suite.",
          steps: "9 steps in 3m 02s · 3 files +148 −6", state: .approval("cargo test --workspace")),
    .init(title: "Docs site migration", kind: "claude", dot: .stateUnread, more: 2,
          prompt: "Move the docs from MkDocs to Starlight and keep every URL.",
          reply: "Moved the docs to Starlight; the old MkDocs config is gone and every page keeps its path, with redirects for the two renamed ones.",
          steps: "14 steps in 6m 40s · 38 files +902 −611", state: .done),
    .init(title: "Flaky login e2e test", kind: "claude", dot: .stateWorking, more: 1,
          prompt: "The login test fails one run in ten on CI. Find out why.",
          reply: "It races the session cookie: the test clicks before the redirect lands. Checking the fixture's timing next.",
          steps: "6 steps in 2m 11s", state: .working("1m 04s", "11 steps")),
]

/// I9: four agents in the Grid layout beside the sidebar.
struct PadGridScreen: View {
    var body: some View {
        HStack(spacing: 0) {
            PadSidebar()
            Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    GridPane(agent: gridAgents[0], focused: true)
                    hairline(vertical: true)
                    GridPane(agent: gridAgents[1], layoutButton: true)
                }
                hairline(vertical: false)
                HStack(spacing: 0) {
                    GridPane(agent: gridAgents[2])
                    hairline(vertical: true)
                    GridPane(agent: gridAgents[3])
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.canvas)
    }

    private func hairline(vertical: Bool) -> some View {
        Rectangle().fill(Color(uiColor: .separator))
            .frame(width: vertical ? 0.5 : nil, height: vertical ? nil : 0.5)
    }
}

private struct GridPane: View {
    let agent: GridAgent
    var focused = false
    var layoutButton = false

    var body: some View {
        VStack(spacing: 0) {
            GridStrip(agent: agent, layoutButton: layoutButton).opacity(focused ? 1 : 0.55)
            ScrollView {
                VStack(spacing: 10) {
                    Spacer(minLength: 24)
                    Bubble(text: agent.prompt, user: true)
                    Bubble(text: agent.reply, user: false)
                    Text(agent.steps).font(.footnote).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
                    if case .approval(let command) = agent.state { GridApproval(command: command) }
                }
                .padding(.horizontal, 14)
            }
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                VStack(spacing: 4) {
                    if case .working(let time, let steps) = agent.state { GridWorkingRow(time: time, steps: steps) }
                    // As the Mac's unfocused panes: only the focused pane (or one holding a draft) keeps its composer.
                    if focused { Composer() }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Unfocused and idle: the folded composer is a glass Reply circle; while the agent works its row says so.
                if !focused, !agent.working, !agent.waiting {
                    Image(systemName: "arrowshape.turn.up.left").font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .padding(.trailing, 16).padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
    }
}

/// A pane's strip, narrow: the selected pill with its ×, the overflow pill, "+"; the layout button in the top right
/// pane's; the mode button's glyph.
private struct GridStrip: View {
    let agent: GridAgent
    let layoutButton: Bool

    var body: some View {
        HStack(spacing: 10) {
            // The track spans the strip up to "+": the selected pill and the overflow pill, as the Mac's strip.
            HStack(spacing: 2) {
                HStack(spacing: 7) {
                    if let dot = agent.dot { Circle().fill(dot).frame(width: 7, height: 7) }
                    AgentGlyph(kind: agent.kind).scaleEffect(0.75).frame(width: 18)
                    Text(agent.title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 30).frame(maxWidth: .infinity).frame(height: 32)
                .overlay(alignment: .trailing) {
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).padding(.trailing, 6)
                }
                .background(Capsule().fill(Color.lens))
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    Text("\(agent.more)").font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 32)
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
            .frame(maxWidth: .infinity)
            Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 38, height: 38)
                .glassEffect(.regular.interactive(), in: Circle())
            // As the Mac's strip: the mode button, then the layout button at the trailing end, on one glass pill.
            HStack(spacing: 0) {
                Image(symbol: ModeButtonState.filled(PadMode.chat.symbol))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.dispatchPink)
                    .frame(minWidth: 44, minHeight: 38)
                if layoutButton {
                    Image(systemName: "square.split.2x2").font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.dispatchPink)
                        .frame(width: 44, height: 38)
                }
            }
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 4)
    }
}

/// The working row, as `WorkingRowMock` draws it, with the pane's clock and steps.
private struct GridWorkingRow: View {
    let time: String
    let steps: String

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color("ThinkingBorder")).frame(height: 1)
            HStack(spacing: 8) {
                ThinkingGlyphMock()
                Text("thinking").font(.subheadline.weight(.semibold))
                    .foregroundStyle(LinearGradient(colors: [Color("ShimmerBase"), Color("ShimmerHighlight"), Color("ShimmerBase")],
                                                    startPoint: .init(x: -0.2, y: 0.5), endPoint: .init(x: 0.7, y: 0.5)))
                Text("·").foregroundStyle(.tertiary)
                Text(time).monospacedDigit()
                StopDisc().padding(.leading, 2)
                Spacer(minLength: 8)
                Text(steps).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                ChevronDisc()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
        }
    }
}

/// A permission request: what the agent asks to run, Deny and Allow Once.
private struct GridApproval: View {
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield").foregroundStyle(Color.caution)
                Text("Run a command?").font(.subheadline.weight(.semibold))
            }
            Text(command).font(.system(.subheadline, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.chipFill, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Spacer()
                Text("Deny").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(height: 34)
                    .glassEffect(.regular.interactive(), in: Capsule())
                Text("Allow Once").font(.subheadline.weight(.semibold)).foregroundStyle(Color.onAccent)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(Color.dispatchPink, in: Capsule())
            }
        }
        .padding(12)
        .background(Color.chipFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }
}
