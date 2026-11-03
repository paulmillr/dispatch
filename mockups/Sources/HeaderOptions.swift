import SwiftUI

// X9b: the tab header (2026-10-30), over the Chat segment: a round chevron Back, the title two lines tall (host ·
// folder under a title that fits one line), and the host disc with a ⋯ badge that is the tab's menu. The subtitle is
// the host and the folder's name only.

struct HeaderOptionScreen: View {
    var title = "Chat mode narrow pane footer fix"

    var body: some View {
        NavigationStack {
            Transcript()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .safeAreaBar(edge: .top, spacing: 0) {
                    SegmentCapsule(selected: 1, badge: 2).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
                }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom) { Composer() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { OptionHeader(title: title) }
        }
    }
}

private struct OptionHeader: ToolbarContent {
    let title: String

    /// The bar's width less its 20-point margins and the trailing disc with the bar's 12-point gap before it.
    private var leadingWidth: CGFloat { UIScreen.main.bounds.width - 40 - 44 - 12 }

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                ChevronBack()
                titleColumn.padding(.leading, 4)
            }
            .frame(width: leadingWidth, alignment: .leading)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) { HostMenuDisc(badge: "ellipsis") }
            .sharedBackgroundVisibility(.hidden)
    }

    /// Two lines' height, top-aligned: a title that fits on one line keeps host · folder under it; a longer one takes
    /// both lines and the host stays on the disc.
    private var titleColumn: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                HostPath(host: "mini", path: "dispatch", mono: false).font(.caption).foregroundStyle(.secondary)
            }
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(height: 40, alignment: .topLeading)
    }
}

/// The back button without a label: the iOS 26 system's chevron circle.
private struct ChevronBack: View {
    var body: some View {
        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.dispatchPink)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

/// The host disc as a menu button: a small badge on its lower trailing edge, as on an avatar that opens a menu.
private struct HostMenuDisc: View {
    let badge: String
    var body: some View {
        Image(systemName: "apple.logo").font(.system(size: 20)).foregroundStyle(hostTint)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: badge).font(.system(size: 8, weight: .heavy)).foregroundStyle(.primary)
                    .frame(width: 17, height: 17)
                    .background(Color(white: 0.28), in: Circle())
                    .overlay { Circle().stroke(Color.canvas, lineWidth: 2) }
                    .offset(x: 2, y: 2)
            }
    }
}
