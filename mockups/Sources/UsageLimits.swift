import SwiftUI

// N4: the working row unfolded with the plan's limits on the steps line (the Mac's activity popover,
// `ChatLimitsSection`): the steps and the session's tokens lead, the weekly limit trails as a ring with its share and
// when it resets. An account that still reports the 5-hour window shows that window's ring in the reset's place. The
// week's name goes where the line is too narrow for it. A ring fills as it is used; the line stays dim, the rings and
// shares too, until a window passes 80% (amber), then 95% (red), the Mac's thresholds.

/// Claude Code's windows as the Mac shows them, and the session's counts.
private enum UsageSample {
    static let tokens = "182.4K in · 12.3K out"
    static let resets = "resets thu 9:40am"
    /// The week's and the 5-hour window's shares: past the 80% warning, or both under it (`low`).
    static func used(low: Bool) -> Int { low ? 46 : 83 }
    static func hourUsed(low: Bool) -> Int { low ? 23 : 42 }
}

/// Dim as the rest of the steps line under 80%; from 80% the limits' own amber (`LimitCaution`: an orange in light,
/// where the banners' Caution reads brown), from 95% red.
private func usageTone(_ used: Int) -> AnyShapeStyle {
    used >= 95 ? AnyShapeStyle(Color.destructive) : used >= 80 ? AnyShapeStyle(Color("LimitCaution")) : AnyShapeStyle(.tertiary)
}

struct UsageLimitsScreen: View {
    /// The account reports the 5-hour window too.
    var fiveHour = false
    /// Every window under 80%: no warning tone.
    var low = false

    var body: some View {
        ChatShell {
            ScrollView {
                VStack(spacing: 10) {
                    Spacer(minLength: 40)
                    Bubble(text: "Make billing webhook retries idempotent.", user: true)
                    BubbleH(text: "Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process. I'll key on the event id instead.")
                    Bubble(text: "Also cover invoice.paid — it has a separate handler.", user: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                UnfoldedWorkingRow(fiveHour: fiveHour, low: low)
            }
            .defaultScrollAnchor(.bottom)
        } bottom: {
            Composer(placeholder: "Message")
        } overlay: {
            EmptyView()
        }
    }
}

/// The app's working row unfolded: the thinking line, the steps line with the limits, four steps.
private struct UnfoldedWorkingRow: View {
    let fiveHour: Bool
    let low: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color("ThinkingBorder")).frame(height: 1)
            HStack(spacing: 8) {
                ThinkingGlyphMock()
                Text("thinking").font(.subheadline.weight(.semibold)).foregroundStyle(Color("ShimmerBase"))
                Text("·").foregroundStyle(.tertiary)
                Text("52s").monospacedDigit()
                StopDisc().padding(.leading, 2)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).background(Color.chipFill, in: Circle())
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(minHeight: 44)
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    ForEach([true, false], id: \.self) { named in
                        HStack(spacing: 8) {
                            Text("4 steps · \(UsageSample.tokens)")
                            Spacer(minLength: 0)
                            Limits(named: named, fiveHour: fiveHour, low: low)
                        }
                    }
                }
                .font(.caption).monospacedDigit().foregroundStyle(.tertiary).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                MockLogStep(kind: "READ", symbol: "doc.text", tint: Color("StepRead"), title: "src/routes/invoices.ts")
                Rectangle().fill(Color("Hairline").opacity(0.6)).frame(height: 0.5)
                MockLogStep(kind: "READ", symbol: "doc.text", tint: Color("StepRead"), title: "src/lib/stripe.ts")
                Rectangle().fill(Color("Hairline").opacity(0.6)).frame(height: 0.5)
                MockLogStep(kind: "PATCH", symbol: "pencil.line", tint: .added, title: "src/lib/idempotent.ts", counts: (2, 1))
                Rectangle().fill(Color("Hairline").opacity(0.6)).frame(height: 0.5)
                MockLogStep(kind: "RUN", symbol: "terminal", tint: Color("StepRun"), title: "npm test -- webhooks",
                            detail: "running 14 tests", live: true)
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 16)
    }
}

/// The week's ring, its share and when it resets; with the 5-hour window, that window's ring in the reset's place.
private struct Limits: View {
    let named: Bool
    let fiveHour: Bool
    let low: Bool
    var body: some View {
        let used = UsageSample.used(low: low), hour = UsageSample.hourUsed(low: low)
        HStack(spacing: 5) {
            Ring(used: used)
            Text(named ? "\(used)% weekly" : "\(used)%").foregroundStyle(usageTone(used))
            if fiveHour {
                Text("·").foregroundStyle(.tertiary)
                Ring(used: hour)
                Text("\(hour)% 5-hour").foregroundStyle(usageTone(hour))
            } else {
                Text((named ? "· " : "") + UsageSample.resets).foregroundStyle(.tertiary)
            }
        }
        .fixedSize()
    }
}

private struct Ring: View {
    let used: Int
    var body: some View {
        ZStack {
            Circle().stroke(Color("Hairline"), lineWidth: 2.5)
            Circle().trim(from: 0, to: CGFloat(used) / 100)
                .stroke(usageTone(used), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
    }
}

/// One step of the live log as the app draws it: badge, two lines, the status mark.
private struct MockLogStep: View {
    let kind: String
    let symbol: String
    let tint: Color
    let title: String
    var counts: (Int, Int)? = nil
    var detail: String? = nil
    var live = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.caption2.weight(.semibold)).imageScale(.small).frame(width: 12)
                Text(kind).font(.caption2.weight(.bold).monospaced()).tracking(0.44)
                    .frame(width: 44, alignment: .leading)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 3).frame(minHeight: 20)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5)).foregroundStyle(.primary).lineLimit(1)
                Group {
                    if let counts {
                        Text("+\(counts.0)").foregroundStyle(Color.added) + Text(" ") + Text("−\(counts.1)").foregroundStyle(Color.destructive)
                    } else {
                        Text(detail ?? " ")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Group {
                if live { ProgressView().controlSize(.mini) }
                else { Image(systemName: "checkmark.circle").font(.footnote).foregroundStyle(Color.added) }
            }
            .frame(width: 18, height: 20)
        }
        .padding(.vertical, 9)
        .opacity(live ? 1 : 0.72)
    }
}
