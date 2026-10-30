import SwiftUI

/// A titled Settings card: the box every page's rows sit in.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).fontWeight(.semibold).foregroundStyle(SettingsControlStyle.selectedText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10).padding(.bottom, 7)
            VStack(spacing: 0) { content }
                .padding(.bottom, 4)
        }.padding(.horizontal, 14)
            .background(Chrome.sidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.border) }
    }
}

/// One Settings line: a separator above, the title and its muted detail, the control at the trailing edge.
struct SettingsRow<Control: View>: View {
    @Environment(\.appTypography) private var typography
    let title: String
    var detail: String?
    var indented = false
    /// What the setting means for privacy, shown on hovering a hand beside the title.
    var privacy: String?
    /// How the setting works, when the detail line cannot say it: shown on hovering an info mark beside the title.
    var info: String?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            SettingsSeparator()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsTitle(title: title, privacy: privacy, info: info)
                    // Wraps rather than truncates beside a wide control.
                    if let detail {
                        Text(detail).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.leading, indented ? 18 : 0)
                Spacer(minLength: 8)
                control
            }.padding(.vertical, 9)
        }
    }
}

/// A setting's title, with a raised hand after it when the setting decides what is kept, shown or shared; hovering
/// the hand says what.
struct SettingsTitle: View {
    let title: String
    var privacy: String?
    /// An explanation (not a privacy note): an info mark whose tooltip holds it.
    var info: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
            if let info {
                Image(systemName: "info.circle").imageScale(.small).foregroundStyle(SettingsControlStyle.detail)
                    .contentShape(Rectangle()).help(info)
                    .accessibilityLabel("About").accessibilityHint(info)
            }
            if let privacy {
                Image(systemName: "hand.raised.fill").imageScale(.small).foregroundStyle(SettingsControlStyle.detail)
                    // Named in the tooltip: the hand alone doesn't say what it's about.
                    .contentShape(Rectangle()).help("Privacy: " + privacy)
                    .accessibilityLabel("Privacy").accessibilityHint(privacy)
            }
        }
    }
}

struct SettingsSeparator: View {
    var body: some View { Rectangle().fill(Chrome.palette.separator).frame(height: 1) }
}
