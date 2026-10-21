import SwiftUI
import UIKit

/// The host's glyph on a disc of its tint (15 %), as every row and header draws it (M2a, M2c, M4d).
struct TabsHostDisc: View {
    let host: TabsHost
    var size: CGFloat = 44
    var glyph: CGFloat? = nil

    var body: some View {
        HostGlyph(host: host.glyphRecord, size: glyph ?? size * 0.5)
            .foregroundStyle(host.tint)
            .frame(width: size, height: size)
            .background(host.tint.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A row's disc glyph: a speech bubble for a chat tab, a prompt for a terminal tab (M2a).
struct TabsKindGlyph: View {
    let chat: Bool
    var body: some View {
        if chat {
            TabsMockupGlyph.chat
        } else {
            Image(systemName: "apple.terminal")
                .resizable()
                .scaledToFit()
                .fontWeight(.regular)
                .padding(1)
        }
    }
}

/// The mockup's own line glyphs where no SF Symbol draws them: drawn on its 24 point grid with a 1.8 point stroke,
/// scaled to the frame they are given.
struct TabsMockupGlyph: View {
    let path: (inout Path) -> Void

    /// A square speech bubble with its tail lower left (M2a's chat rows).
    static var chat: TabsMockupGlyph {
        TabsMockupGlyph { path in
            path.move(to: CGPoint(x: 3.5, y: 5))
            path.addLine(to: CGPoint(x: 20.5, y: 5))
            path.addLine(to: CGPoint(x: 20.5, y: 16))
            path.addLine(to: CGPoint(x: 11.5, y: 16))
            path.addLine(to: CGPoint(x: 7, y: 20))
            path.addLine(to: CGPoint(x: 7, y: 16))
            path.addLine(to: CGPoint(x: 3.5, y: 16))
            path.closeSubpath()
        }
    }

    /// The tree toggle (M2a): a stem branching to two boxes.
    static var tree: TabsMockupGlyph {
        TabsMockupGlyph { path in
            path.move(to: CGPoint(x: 5, y: 4))
            path.addLine(to: CGPoint(x: 5, y: 16))
            path.addQuadCurve(to: CGPoint(x: 7, y: 18), control: CGPoint(x: 5, y: 18))
            path.addLine(to: CGPoint(x: 11, y: 18))
            path.move(to: CGPoint(x: 5, y: 10))
            path.addLine(to: CGPoint(x: 11, y: 10))
            path.addRoundedRect(in: CGRect(x: 13, y: 7, width: 7, height: 6), cornerSize: CGSize(width: 1.5, height: 1.5))
            path.addRoundedRect(in: CGRect(x: 13, y: 15, width: 7, height: 6), cornerSize: CGSize(width: 1.5, height: 1.5))
        }
    }

    /// Sort and filter (M2a): three lines, shorter each.
    static var filter: TabsMockupGlyph {
        TabsMockupGlyph { path in
            for (y, inset) in [(7.0, 4.0), (12.0, 7.0), (17.0, 10.0)] {
                path.move(to: CGPoint(x: inset, y: y))
                path.addLine(to: CGPoint(x: 24 - inset, y: y))
            }
        }
    }

    var body: some View {
        Canvas { context, size in
            var shape = Path()
            path(&shape)
            let scale = min(size.width, size.height) / 24
            let transform = CGAffineTransform(translationX: (size.width - 24 * scale) / 2, y: (size.height - 24 * scale) / 2)
                .scaledBy(x: scale, y: scale)
            context.stroke(shape.applying(transform), with: .foreground,
                           style: StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// The glass pills of the pushed screens' headers (M2c, M4a, M4d): 44 points high, the app tint for text.
struct TabsHeaderPill<Label: View>: View {
    /// The mockup's: 16 after a word, 14 after the back pill's count.
    var trailing: CGFloat = 16
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .font(.body)
                .foregroundStyle(Color.dispatchPink)
                .fixedSize()
                .padding(.leading, 12)
                .padding(.trailing, trailing)
                .frame(height: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .fixedSize()
        // The navigation bar keeps its height: the pill's text grows to xxxLarge, larger sizes show the large content
        // viewer on a long press, as the system's bar buttons do.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
    }
}

/// The back pill: a chevron and the previous screen's title, or the needs-you count in a tab (M4a: "‹ 1").
struct TabsBackPill: View {
    /// A tab's back pill: how many conversations elsewhere need the user, as a badge (Messages' unread count); with
    /// none, the screen it returns to. A bare "0" read as nothing at all.
    static func needsYou(_ count: Int, back title: String, action: @escaping () -> Void) -> TabsBackPill {
        count > 0 ? TabsBackPill(label: "\(count)", count: true, action: action) : TabsBackPill(label: title, action: action)
    }

    let label: String
    var count = false
    let action: () -> Void

    var body: some View {
        TabsHeaderPill(trailing: count ? 14 : 16, action: action) {
            HStack(spacing: count ? 5 : 4) {
                TabsBackChevron()
                if count {
                    // A badge, so the number reads as a count of waiting conversations.
                    Text(label)
                        .font(.footnote.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.onAccent)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.dispatchPink, in: Capsule())
                } else {
                    Text(label)
                        .font(.body)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityLabel(count ? "Back, \(label) \(label == "1" ? "conversation needs" : "conversations need") you" : "Back to \(label)")
    }
}

/// The back pill's chevron at the glyph's 11 points, as the mockup's: the symbol's image carries side bearings that
/// made every back pill 6 points wider than M2c's and M4a's. Its own view, so its width scales under the pill's
/// Dynamic Type cap.
private struct TabsBackChevron: View {
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 11
    var body: some View {
        Image(systemName: "chevron.left")
            .scaledFont(19, weight: .medium, relativeTo: .body)
            .frame(width: width)
    }
}

/// The header of a pushed screen (M2c, M4a, M6a) as navigation bar items: back pill, title with its subtitle, a
/// trailing control. In the bar, not over the content: a hidden bar on a pushed screen hides it for the whole stack
/// at the start of the push, and the screen underneath jumped up for a frame (a screen recording showed it).
struct TabsScreenHeader<Back: View, Subtitle: View, Trailing: View>: ToolbarContent {
    /// The title column's widest: the screen less the back pill, the host pill and the bar's margins.
    @MainActor static var titleWidth: CGFloat {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 402
        return max(160, screen - 170)
    }
    let title: String
    @ViewBuilder var back: Back
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var trailing: Trailing

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { back }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarLeading) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // The bar's height is fixed: its title grows to xxxLarge, as the system's inline titles do.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.leading, 4)
            // At most what the bar has between the back pill and the host pill: a long folder truncates instead of
            // pushing every item into the bar's overflow menu.
            .frame(maxWidth: Self.titleWidth, alignment: .leading)
            .fixedSize()
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) { trailing }
            .sharedBackgroundVisibility(.hidden)
    }
}

/// "mba2 · ~/src/app": the host in its tint, a path in mono (M2c, M4a).
struct TabsHostPath: View {
    let host: TabsHost
    let path: String?
    var trailing: String? = nil
    var mono = true
    @ScaledMetric(relativeTo: .caption2) private var monoSize: CGFloat = 11.5

    var body: some View {
        var text = AttributedString(host.name)
        text.foregroundColor = host.tint
        if let path {
            text += AttributedString(" · ")
            var part = AttributedString(path)
            if mono { part.font = .system(size: monoSize, design: .monospaced) }
            text += part
        }
        if let trailing { text += AttributedString(" · " + trailing) }
        return Text(text)
    }
}

/// The floating glass button (M2c's New tab).
struct TabsFloatingButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.title3.weight(.medium))
                Text(title).font(.headline)
            }
            .foregroundStyle(.primary)
            .padding(.leading, 18)
            .padding(.trailing, 22)
            .padding(.vertical, 8)
            .frame(minHeight: 60)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

extension View {
    /// A pushed screen with its own header items (`TabsScreenHeader`): the system back button gives way to the back
    /// pill and the edge swipe still goes back. No tab bar: the one stack holds the tab bar (`MobileRoot`), so a push
    /// covers it as UIKit pushes do (`toolbar(.hidden, for: .tabBar)` dropped it a frame early on push and left the root
    /// without it for about 25 frames on pop; SwiftUI's hosting controllers ignore `hidesBottomBarWhenPushed`).
    func tabsPushedScreen() -> some View {
        navigationBarBackButtonHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .background(TabsSwipeBack())
            .background(Color.canvas)
    }
}

/// Hiding the back button turns off UIKit's edge swipe back; this keeps it on for the stack it is in.
struct TabsSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let navigation = navigationController, let gesture = navigation.interactivePopGestureRecognizer else { return }
            gesture.isEnabled = true
            gesture.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
