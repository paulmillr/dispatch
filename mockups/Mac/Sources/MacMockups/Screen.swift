import SwiftUI

/// One mockup: an id (`M1-main`, letters and a number first, as the iOS screens), the contact sheet it joins, and what
/// it draws. The renderer sets the theme (`Chrome.palette`), the colour scheme, the accent tint and the typography
/// before calling `make`, so a screen reads them as the app's views do.
struct Screen {
    let id: String
    let group: String
    let title: String
    /// The desktop backdrop and padding around the content; off for close-ups that bring their own.
    var staged = true
    let make: @MainActor () -> AnyView

    init<V: View>(_ id: String, group: String, _ title: String, staged: Bool = true,
                  @ViewBuilder _ content: @escaping @MainActor () -> V) {
        self.id = id; self.group = group; self.title = title; self.staged = staged
        make = { AnyView(content()) }
    }
}

/// Every screen, a file's list per line. A new topic is a file in Screens/ with `static let screens: [Screen]`, listed
/// here.
enum Screens {
    static var all: [Screen] {
        Reference.screens + FilesModes.screens + Landing.screens + Onboarding.screens
            + UpdateScreens.screens + ModelLadder.screens + ClaudeLimits.screens
    }
}
