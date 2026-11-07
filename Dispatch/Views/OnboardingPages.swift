import SwiftUI

// The first-launch setup sheet's SwiftUI parts (LocalAgentsConsent.Sheet holds them, with the choices in AppKit): each
// page's header, the Chat and Tabs pages, and the footer. Drawn after mockups/Mac's Onboarding screens (O1–O3). The
// pictures take the terminal's own colours (ChatThemeStore), the rest the sheet's (SSHIntegrationConsent's style).

enum Onboarding {
    /// The steps the footer names, in order: what to type for Chat, for tmux, herdr and SSH, then the choices.
    static let steps = [("text.bubble", "Chat"), ("square.split.2x1", "Tabs"), ("laptopcomputer", "Prefs")]

    @MainActor static func sheetFont(_ size: CGFloat, bold: Bool = false) -> Font { Font(AppFont.native(size: size, semibold: bold)) }
    @MainActor static var muted: Color { Color(nsColor: SSHIntegrationConsent.muted) }

    /// A command as typed at the prompt, on the terminal's colours.
    @MainActor static func command(_ text: String) -> some View {
        let theme = ChatThemeStore.shared.current
        return HStack(spacing: 0) {
            Text("❯ ").foregroundStyle(theme.green).bold()
            Text(text).foregroundStyle(theme.ink)
        }
        .font(AppFont.sourceCodePro(size: 12))
        .padding(.horizontal, 10).frame(height: 26)
        .background(theme.terminal, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Chrome.border))
    }

    /// The tab before and after the command: a terminal, an arrow, the same tab as Dispatch shows it.
    @MainActor static func beforeAfter<Before: View, After: View>(@ViewBuilder _ before: () -> Before,
                                                                   @ViewBuilder after: () -> After) -> some View {
        HStack(spacing: 10) {
            before().frame(maxWidth: .infinity).frame(height: 104)
            Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Chrome.accent)
            after().frame(maxWidth: .infinity).frame(height: 104)
        }
    }

    /// A small picture's frame: the terminal's background, rounded, the accent edge for the "after" one.
    @MainActor static func picture<Content: View>(lit: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ChatThemeStore.shared.current.terminal)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(lit ? Chrome.accent.opacity(0.6) : Chrome.border))
    }

    /// The prompt line of the "before" pictures: folder, ❯, the command.
    @MainActor static func prompt(_ typed: String) -> some View {
        let theme = ChatThemeStore.shared.current
        return HStack(spacing: 0) {
            Text("app ").foregroundStyle(theme.blue)
            Text("❯ ").foregroundStyle(theme.green).bold()
            Text(typed).foregroundStyle(theme.ink)
        }
    }

    /// The page's glyph on the consent sheets' blue tile, its title and subtitle.
    struct Header: View {
        let symbol: String
        let title: String
        let subtitle: String
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(.sRGB, red: 126/255, green: 166/255, blue: 201/255))
                    .frame(width: 28, height: 28)
                    .background(Color(.sRGB, red: 0.12, green: 0.17, blue: 0.21), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(sheetFont(13, bold: true)).foregroundStyle(Chrome.ink)
                    Text(subtitle).font(sheetFont(11)).foregroundStyle(muted)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Page 1: start an agent in a tab and the tab becomes Chat; what each kind of agent needs first.
    struct ChatPage: View {
        var body: some View {
            let theme = ChatThemeStore.shared.current
            VStack(alignment: .leading, spacing: 12) {
                Text("Start an agent in any tab, as you always do:").font(sheetFont(12)).foregroundStyle(Chrome.ink)
                HStack(spacing: 8) { command("claude"); command("codex") }
                beforeAfter {
                    picture {
                        VStack(alignment: .leading, spacing: 3) {
                            prompt("claude")
                            Spacer(minLength: 0)
                            Text("> Run the tests").foregroundStyle(theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(theme.ink.opacity(0.35)))
                        }
                        .font(AppFont.sourceCodePro(size: 10.5)).padding(9)
                    }
                    .overlay(alignment: .topTrailing) { mode("apple.terminal") }
                } after: {
                    picture(lit: true) {
                        VStack(alignment: .trailing, spacing: 6) {
                            Spacer(minLength: 0)
                            Text("Run the tests").padding(.horizontal, 9).padding(.vertical, 5)
                                .background(theme.ink.opacity(0.08), in: UnevenRoundedRectangle(
                                    topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 3, topTrailingRadius: 10))
                            Text("All 48 pass.").padding(.horizontal, 9).padding(.vertical, 6)
                                .background(theme.window, in: UnevenRoundedRectangle(
                                    topLeadingRadius: 10, bottomLeadingRadius: 3, bottomTrailingRadius: 10, topTrailingRadius: 10))
                                .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3, bottomTrailingRadius: 10,
                                                                topTrailingRadius: 10).strokeBorder(theme.border))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(theme.ink)
                        .padding(9)
                    }
                    .overlay(alignment: .topTrailing) { mode("text.bubble", lit: true) }
                }
                (Text("The tab switches to Chat by itself. ").foregroundColor(Chrome.ink.opacity(0.85))
                 + Text("⇧⌘C").font(.system(size: 11, design: .monospaced)).foregroundColor(Chrome.ink)
                 + Text(" switches between Chat and the terminal.").foregroundColor(Chrome.ink.opacity(0.85)))
                    .font(sheetFont(11.5)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 5) {
                    note("laptopcomputer", Text("Agents on this Mac need hooks: say Yes in Prefs."))
                    note("network", Text("SSH agents need the helper: confirm it when you ")
                         + Text("ssh").font(AppFont.sourceCodePro(size: 11)).foregroundColor(Chrome.ink) + Text(" to a host."))
                }
            }
        }

        /// The tab's mode button in a picture's corner: the terminal glyph, or the Chat bubble lit.
        private func mode(_ symbol: String, lit: Bool = false) -> some View {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .foregroundStyle(lit ? Chrome.window : muted)
                .frame(width: 22, height: 18)
                .background(lit ? Chrome.accent : Chrome.ink.opacity(0.08), in: Capsule())
                .padding(6)
        }

        private func note(_ symbol: String, _ text: Text) -> some View {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(Chrome.accent).frame(width: 16)
                text.font(sheetFont(11)).foregroundStyle(muted).lineLimit(1)
            }
        }
    }

    /// Page 2: the commands that open tmux and herdr as tabs and spaces, and that SSH works the same way.
    struct TabsPage: View {
        var body: some View {
            let theme = ChatThemeStore.shared.current
            VStack(alignment: .leading, spacing: 12) {
                Text("Start tmux or herdr in any tab:").font(sheetFont(12)).foregroundStyle(Chrome.ink)
                HStack(spacing: 8) { command("tmux -CC"); command("tmux -CC attach"); command("herdr") }
                beforeAfter {
                    picture { prompt("tmux -CC attach").font(AppFont.sourceCodePro(size: 10.5)).padding(9) }
                } after: {
                    picture(lit: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 4) {
                                tab("server", selected: true); tab("tests"); tab("claude")
                                Spacer(minLength: 0)
                            }
                            .padding(6).background(Chrome.sidebar)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("listening on :3000").foregroundStyle(theme.ink)
                                Text("GET /health 200").foregroundStyle(theme.comment)
                                Text("GET /api/items 200").foregroundStyle(theme.comment)
                            }
                            .font(AppFont.sourceCodePro(size: 9.5)).padding(8)
                        }
                    }
                }
                Text("tmux windows open as tabs, herdr workspaces as spaces.").font(sheetFont(11.5)).foregroundStyle(Chrome.ink.opacity(0.85))
                HStack(spacing: 7) {
                    Image(systemName: "network").font(.system(size: 10, weight: .medium)).foregroundStyle(Chrome.accent).frame(width: 16)
                    Text("Works over ssh too: Dispatch asks once to upload its helper. Keep Agent hooks checked for Chat there.")
                        .font(sheetFont(11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private func tab(_ title: String, selected: Bool = false) -> some View {
            Text(title).font(sheetFont(10, bold: selected))
                .foregroundStyle(selected ? Chrome.ink : muted)
                .padding(.horizontal, 8).frame(height: 18)
                .background(selected ? Chrome.accent.opacity(0.18) : Chrome.ink.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Chrome.accent.opacity(0.6) : .clear))
        }
    }

    /// What the footer shows and does; the sheet sets it and supplies the actions.
    @MainActor @Observable final class FooterModel {
        enum Mode: Equatable {
            /// A fresh install's three pages: Back, the steps, Skip, Next (Let's roll! on the last).
            case pages
            /// An existing installation's updates question alone: Continue.
            case updates
            /// Yes found no agent CLI: Check again and Done.
            case warning
        }
        var mode = Mode.pages
        var page = 0
        /// A check for agent CLIs is running: every button waits.
        var busy = false
        var back: () -> Void = {}
        var show: (Int) -> Void = { _ in }
        var skip: () -> Void = {}
        var next: () -> Void = {}
        var check: () -> Void = {}
        var done: () -> Void = {}
    }

    /// The footer: Back at the left, the steps centred on the sheet, Skip and the primary action at the right.
    struct Footer: View {
        let model: FooterModel
        var body: some View {
            HStack(spacing: 6) {
                if model.mode == .pages {
                    Button(action: model.back) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Chrome.ink.opacity(model.page == 0 ? 0.25 : 0.75))
                            .frame(width: 30, height: 30)
                            .background(Chrome.ink.opacity(model.page == 0 ? 0.03 : 0.07), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain).disabled(model.page == 0)
                    .accessibilityLabel("Back").accessibilityIdentifier("onboarding-back")
                }
                Spacer(minLength: 8)
                switch model.mode {
                case .pages:
                    // On the last page Skip closes with nothing saved; Settings answers later.
                    Button(action: model.skip) { Text("Skip").font(sheetFont(11.5)).foregroundStyle(muted).padding(.horizontal, 6) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(model.page < 2 ? "onboarding-skip" : "local-agents-later")
                    primary(model.page < 2 ? "Next" : "Let’s roll!", identifier: model.page < 2 ? "onboarding-next" : "local-agents-continue",
                            action: model.next)
                case .updates:
                    primary("Continue", identifier: "local-agents-continue", action: model.next)
                case .warning:
                    Button(action: model.check) {
                        Text("Check again").font(sheetFont(12.5)).foregroundStyle(Chrome.ink)
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(Chrome.ink.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("local-agents-check")
                    primary("Done", identifier: "local-agents-done", action: model.done)
                }
            }
            .padding(.horizontal, 14).frame(height: 54)
            .overlay {
                if model.mode == .pages {
                    HStack(spacing: 6) { ForEach(0..<steps.count, id: \.self) { step($0) } }
                }
            }
            .background(Chrome.sidebar)
            .overlay(alignment: .top) { Rectangle().fill(Chrome.border).frame(height: 1) }
            .disabled(model.busy)
            .opacity(model.busy ? 0.6 : 1)
        }

        private func primary(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title).font(sheetFont(12.5, bold: true)).foregroundStyle(Chrome.window)
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(Chrome.accent, in: Capsule())
            }
            .buttonStyle(.plain).accessibilityIdentifier(identifier)
        }

        /// A step: its glyph and name, the current one filled.
        private func step(_ index: Int) -> some View {
            let current = index == model.page
            return Button { model.show(index) } label: {
                HStack(spacing: 4) {
                    Image(systemName: steps[index].0).font(.system(size: 9, weight: .bold))
                    Text(steps[index].1).font(sheetFont(10.5, bold: current))
                }
                .foregroundStyle(current ? Chrome.window : Chrome.accent)
                .padding(.horizontal, 8).frame(height: 24)
                .background(current ? Chrome.accent : Chrome.accent.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboarding-step-" + steps[index].1.lowercased())
        }
    }
}
