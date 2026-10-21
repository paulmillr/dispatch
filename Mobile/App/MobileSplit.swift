import SwiftUI
import UIKit

/// Wide windows (the unfolded iPhone Duo, an iPad): Spaces and Agents, as on the phone, in a sidebar column, and the
/// tab they open in a detail column beside them instead of over them (`SpacesNavigator.SplitPath`). Folded, on every
/// other iPhone, and in a narrow iPad window (Slide Over, a third), the window is the one stack it always was
/// (`MobileRoot`).
enum MobileSplit {
    /// Whose rules lay the window out: the phone's (the unfolded Duo, with its fold and postures) or the iPad's (the
    /// system's sidebar width). By idiom, not by size: the two overlap (an 820 point wide window is a Duo-like laptop on
    /// a phone and a full-screen iPad Air upright), and the Duo's numbers stay as they are.
    enum Device {
        case phone, pad

        @MainActor static var current: Device { UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone }
    }

    /// Both sides at least this: the unfolded Duo (669 × 951 points, either way up) splits; its cover screen (466 wide)
    /// and every iPhone in landscape (at most 440 high) do not. The window's size, not its size class: the system's
    /// split views collapse in a compact width, which the unfolded Duo may report.
    static let minimum: CGFloat = 600

    static func applies(to size: CGSize, device: Device = .phone) -> Bool {
        switch device {
        case .phone: min(size.width, size.height) >= minimum
        case .pad: size.width >= padMinimumWidth
        }
    }

    /// The iPad's sidebar: what `UISplitViewController` gives its double-column primary (measured on iPadOS 27: 320
    /// points in every full-screen iPad either way up and in a 13-inch's two thirds; the window less 448 between 728 and
    /// 768 wide, 296 on an iPad mini upright). Not the rest of the window: on a 13-inch in landscape that was 970 points.
    static let padSidebar: CGFloat = 320
    /// What the system keeps for the detail column while it narrows the sidebar.
    static let padDetailReserve: CGFloat = 448
    /// The iPad sidebar's narrowest: the system's own narrowest tiled sidebar (its width at 728 points), and what the
    /// sidebar's bar needs beside iPadOS's window controls, which a window that narrow always has (the tree and sort
    /// capsule and Edit went into the bar's overflow menu at the phone's 250).
    static let padNarrowestSidebar: CGFloat = 280
    /// The iPad tab's narrowest: the narrowest iPhone iOS 26 runs on (375 points), so the tab still lays out as on a
    /// phone.
    static let padNarrowestTab: CGFloat = 375
    /// An iPad splits once both columns fit at their narrowest (655.5 points). Below 728 the system stops tiling (its
    /// sidebar only overlays); the split goes on down to here. iPadOS 27's own windows (Window Controls, Move & Resize,
    /// measured): every full-screen iPad, the top halves (744 × 561.5 on a mini upright, 1210 × 486 on an 11-inch on
    /// its side) and a 13-inch's half on its side (683 × 909, a 280-point sidebar beside a 402.5-point tab) split; the
    /// other halves (375 on a mini upright to 600 on an 11-inch on its side), thirds and Slide Over (375) stack, where
    /// the window is compact and the stack is exactly the iPhone's. By width alone, as the system's split view decides:
    /// the short windows are the wide ones, where the tab beside the list beats the list across it.
    static var padMinimumWidth: CGFloat { padNarrowestSidebar + 0.5 + padNarrowestTab }

    /// What the tab would keep in laptop posture (taller than wide, the fold across): a phone's width, between the
    /// iPhone 17's 402 points and the Air's 420, so its terminal and chat lay out as on the phone.
    static let laptopTab: CGFloat = 405
    /// The sidebar's narrowest: the narrow sidebar's tab bar (glyphs only) and rows still fit.
    static let narrowestSidebar: CGFloat = 250

    /// The sidebar, the gap after it (the hairline, or the fold) and the tab's column, across `width`.
    struct Columns: Equatable {
        var sidebar: CGFloat
        var gap: CGFloat
        var tab: CGFloat
    }

    /// Laptop posture (taller than wide, the fold across both columns whatever they do): the tab keeps a phone's
    /// width (263-point sidebar unfolded). Book posture (wider than tall): the hairline is the fold, Spaces on one side
    /// and the tab on the other; a fold down the tab's column (as the 380-point sidebar had it) split its header, the
    /// Terminal / Chat control and the thread. `fold` is where it runs in the columns' space (`MobileFoldReader`:
    /// the division region's middle, off centre on the Duo, 517.5 of 951 points held one way); without one the
    /// halves meet in the middle.
    ///
    /// On an iPad (`Device.pad`) the posture and the fold do not apply: the sidebar takes the system's width
    /// (`padSidebar`, less as the window narrows, never under `padNarrowestSidebar`) either way up, the tab the rest.
    static func columns(width: CGFloat, height: CGFloat, fold: CGFloat? = nil, device: Device = .phone) -> Columns {
        if device == .pad {
            let sidebar = min(padSidebar, max(padNarrowestSidebar, (width - padDetailReserve).rounded(.down)))
            return Columns(sidebar: sidebar, gap: 0.5, tab: max(0, width - sidebar - 0.5))
        }
        if height > width {
            let sidebar = max(narrowestSidebar, (width - 0.5 - laptopTab).rounded(.down))
            return Columns(sidebar: sidebar, gap: 0.5, tab: max(0, width - sidebar - 0.5))
        }
        let line = fold.flatMap { $0 >= narrowestSidebar && width - $0 >= narrowestSidebar ? $0 : nil } ?? width / 2
        return Columns(sidebar: line - 0.25, gap: 0.5, tab: width - line - 0.25)
    }

    static func sidebarWidth(for size: CGSize, device: Device = .phone) -> CGFloat {
        columns(width: size.width, height: size.height, device: device).sidebar
    }

    /// A sidebar narrower than a phone (laptop posture): its tab bar shows glyphs only, which labelled crowded each
    /// other under 283 points, and the Spaces rows say space, host and folder (`TabsTabRow`). Never on an iPad: its
    /// sidebar is 280 at the least, where the labels fit, and the narrow rows cost a full-screen mini (296) every
    /// tab's name.
    static func narrow(sidebar width: CGFloat, device: Device = .phone) -> Bool { device == .phone && width < 300 }

    /// The window's size before the first layout measures it, so a launch on the unfolded screen does not draw the
    /// stack for a frame first: the scene's own bounds, not its screen's (an iPad window in Split View, Slide Over or
    /// Stage Manager is smaller than the screen, and the screen's size drew the split for a frame before the stack).
    @MainActor static var initialSize: CGSize {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return .zero }
        let bounds = scene.effectiveGeometry.coordinateSpace.bounds.size
        return bounds.width > 0 ? bounds : scene.screen.bounds.size
    }
}

/// Where the screen folds down its height, for the split's columns: the middle of the system's division region
/// (iOS 27.1, the unfolded Duo's hinge; inactive while it lies flat, a crease all the same) in this view's space,
/// else the window's middle there, with the space's size. Reported after layout, once per change.
struct MobileFoldReader: UIViewRepresentable {
    let changed: (CGSize, CGFloat) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.changed = changed
        probe.report()
    }

    final class Probe: UIView {
        var changed: ((CGSize, CGFloat) -> Void)?
        private var last: (CGSize, CGFloat)?

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        func report() {
            guard let window, bounds.width > 0 else { return }
            var fold = convert(CGPoint(x: window.bounds.midX, y: 0), from: window).x
            if #available(iOS 27.1, *),
               let region = reservedRegions(kind: .division, options: .includeInactive).first(where: { $0.frame.height > $0.frame.width }) {
                fold = region.frame.midX
            }
            guard last.map({ $0.0 != bounds.size || $0.1 != fold }) ?? true else { return }
            last = (bounds.size, fold)
            let size = bounds.size
            // After this layout pass: the split's state changes with it, not during SwiftUI's update.
            DispatchQueue.main.async { [weak self] in self?.changed?(size, fold) }
        }
    }
}

/// The split's detail column: the tab last on the path, on its own stack for what it pushes (space details, message
/// details, a diff); before any tab is open, where to find one.
struct MobileSplitDetail: View {
    @Bindable var navigator: SpacesNavigator
    let content: TabsContent
    let hostViews: SpacesHostViews

    var body: some View {
        NavigationStack(path: Binding(get: { navigator.splitPath.detail }, set: { navigator.setDetail($0) })) {
            Group {
                if let tab = navigator.splitPath.tab {
                    TabScreen(model: navigator.model, ref: tab, path: $navigator.path, content: content)
                        .environment(\.tabsSplitDetail, true)
                        .id(tab)
                } else {
                    ContentUnavailableView {
                        Label("No tab open", systemImage: "square.on.square")
                    } description: {
                        Text("Open a tab in Spaces, or a conversation in Agents.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.canvas)
                }
            }
            .navigationDestination(for: TabsRoute.self) { route in
                TabsDestination(route: route, navigator: navigator, content: content, hostViews: hostViews)
            }
        }
    }
}


