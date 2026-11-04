import SwiftUI

/// The desktop a staged screen sits on: a plain backdrop a step off the window's tone, and room for the shadow.
struct Stage<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        let dark = Chrome.palette.isDark
        content
            .padding(40)
            .background(dark ? Color(white: 0.2) : Color(white: 0.84))
    }
}

/// A window's traffic lights as macOS 26 draws them (measured from the app's capture): 14-point circles 23 points
/// apart, centred 21 points down and 16 in. `active: false` draws them gray, as an inactive window's.
struct TrafficLights: View {
    var active = true
    var body: some View {
        HStack(spacing: 9) {
            light(Color(red: 1, green: 0.373, blue: 0.341), Color(red: 0.886, green: 0.271, blue: 0.247))
            light(Color(red: 0.996, green: 0.737, blue: 0.180), Color(red: 0.875, green: 0.616, blue: 0.094))
            light(Color(red: 0.157, green: 0.784, blue: 0.251), Color(red: 0.118, green: 0.659, blue: 0.188))
        }
    }
    private func light(_ fill: Color, _ edge: Color) -> some View {
        Circle().fill(active ? fill : Color.gray.opacity(0.35))
            .overlay(Circle().strokeBorder(active ? edge.opacity(0.6) : .clear, lineWidth: 0.5))
            .frame(width: 14, height: 14)
    }
}

/// A Mac window: rounded corners, a hairline edge and the system's shadow, and the traffic lights over the content's
/// top-left (full-size content, as Dispatch's main window). `lights: false` for panels and Settings-style windows that
/// draw their own title bar.
struct MacWindow<Content: View>: View {
    var width: CGFloat = 1180
    var height: CGFloat = 740
    var lights = true
    var cornerRadius: CGFloat = 16
    @ViewBuilder let content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .frame(width: width, height: height, alignment: .topLeading)
            .background(Chrome.window)
            .overlay(alignment: .topLeading) { if lights { TrafficLights().padding(.leading, 9).padding(.top, 14) } }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Chrome.palette.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(Chrome.palette.isDark ? 0.55 : 0.22), radius: 24, y: 12)
    }
}

/// A sheet over a window, as AppKit attaches one: the window dimmed, the sheet centred under its top edge.
struct SheetOver<Window: View, Sheet: View>: View {
    @ViewBuilder let window: Window
    @ViewBuilder let sheet: Sheet
    var body: some View {
        window
            .overlay { Color.black.opacity(Chrome.palette.isDark ? 0.35 : 0.12).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) }
            .overlay(alignment: .top) {
                sheet
                    .background(Chrome.palette.isDark ? Color(white: 0.16) : Color(white: 0.98))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
                    .padding(.top, 48)
            }
    }
}

/// A menu as macOS draws one (opaque: materials do not render offscreen). Items are `MenuItem`s; `nil` is a separator.
struct MacMenu: View {
    let items: [MenuItem?]
    var width: CGFloat = 240
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if let item {
                    HStack(spacing: 8) {
                        Image(systemName: item.checked ? "checkmark" : "circle").opacity(item.checked ? 1 : 0)
                            .font(.system(size: 11, weight: .semibold)).frame(width: 12)
                        if let symbol = item.symbol { Image(systemName: symbol).frame(width: 16) }
                        Text(item.title)
                        Spacer(minLength: 16)
                        if let shortcut = item.shortcut { Text(shortcut).foregroundStyle(item.highlighted ? .white.opacity(0.8) : .secondary) }
                        if item.submenu { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(item.highlighted ? .white : item.enabled ? .primary : .secondary)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(item.highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .padding(.horizontal, 5)
                } else {
                    Divider().padding(.horizontal, 14).padding(.vertical, 5)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: width)
        .background(Chrome.palette.isDark ? Color(white: 0.19) : Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }
}

struct MenuItem {
    var title: String
    var symbol: String?
    var shortcut: String?
    var checked = false
    var highlighted = false
    var enabled = true
    var submenu = false
}

/// A callout for design notes on a screen: numbered, in the accent, so a reviewer can refer to it ("2 is too tight").
struct Callout: View {
    let number: Int
    var note: String?
    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Color.orange))
            if let note { Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.orange)) }
        }
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }
}
