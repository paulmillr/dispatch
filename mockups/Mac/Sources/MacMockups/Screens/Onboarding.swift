import SwiftUI

// The first-launch setup sheet as it ships (LocalAgentsConsent.Sheet, its pages in Dispatch/Views/OnboardingPages.swift):
// what to type for Chat; for tmux, herdr and SSH hosts; then the two choices for this Mac. One sheet in the SSH consent
// sheet's style, in the accent only, 500 wide. The footer: Back, the steps (Chat · Tabs · Prefs) centred, Skip, Next
// (Let's roll! on the last page).

enum Onboarding {
    static let screens: [Screen] = [
        Screen("O1-chat", group: "onboarding", "Page 1 of 3: start an agent in a tab and it becomes Chat") { over(Strip(page: 0) { ChatPage() }) },
        Screen("O2-tabs", group: "onboarding", "Page 2 of 3: tmux -CC, herdr and ssh, as typed") { over(Strip(page: 1) { NativePage() }) },
        Screen("O3-prefs", group: "onboarding", "Page 3 of 3: the two choices for this Mac") { over(Strip(page: 2) { Choices() }) },
    ]

    static var headers: [(symbol: String, title: String, subtitle: String)] {
        [("text.bubble", "Chat with your agents", "Welcome to Dispatch"),
         ("square.split.2x1", "tmux, herdr and SSH", "Type the commands you already know"),
         ("laptopcomputer", "Set up this Mac", "Two quick choices")]
    }
    static let steps = [("Chat", "start an agent"), ("Tabs", "tmux -CC, herdr, ssh"), ("Prefs", "agents and updates")]

    /// The sheet over a fresh install's main window: one Local space, its shell.
    @MainActor private static func over(_ sheet: some View) -> some View {
        DispatchWindow(width: 900, height: 600, sidebar: SidebarModel(spaces: [SpaceItem(name: "~", shortcut: 1, selected: true)], width: 220)) {
            Pane(strip: StripModel(tabs: [TabItem(title: "~", shortcut: 1, selected: true)])) { TerminalScreen(lines: [.prompt(folder: "~", branch: nil)]) }
        }
        .overlay { Color.black.opacity(Chrome.palette.isDark ? 0.35 : 0.12).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) }
        .overlay(alignment: .top) { sheet.padding(.top, 40) }
    }

    // MARK: Style (SSHIntegrationConsent's)

    static let width: CGFloat = 500, inset: CGFloat = 20
    static var content: CGFloat { width - inset * 2 }
    @MainActor static var muted: Color {
        Chrome.palette.isDark ? Color(.sRGB, red: 111/255, green: 111/255, blue: 120/255) : Chrome.muted
    }
    @MainActor static func sheetFont(_ size: CGFloat, bold: Bool = false) -> Font { Font(AppFont.native(size: size, semibold: bold)) }

    @MainActor static func section(_ title: String) -> some View {
        Text(title.uppercased()).font(sheetFont(10, bold: true)).foregroundStyle(muted)
    }

    /// Rows in one rounded, accent-bordered box.
    @MainActor static func group<Rows: View>(_ color: Color, @ViewBuilder _ rows: () -> Rows) -> some View {
        VStack(spacing: 0) { rows() }
            .background(Chrome.sidebar)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.35)))
    }

    /// A ChoiceButton parent row: radio or checkbox, title and detail.
    struct Choice: View {
        let title: String
        let detail: String
        var on = false
        var radio = false
        var divider = true
        var body: some View {
            HStack(spacing: 12) {
                Group {
                    if radio {
                        Circle().fill(on ? Chrome.accent : .clear)
                            .overlay(Circle().strokeBorder(Chrome.ink.opacity(on ? 0 : 0.25), lineWidth: 1.5))
                            .overlay(Circle().fill(Chrome.window).frame(width: 6, height: 6).opacity(on ? 1 : 0))
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(on ? Chrome.accent : .clear)
                            .overlay(Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Chrome.window).opacity(on ? 1 : 0))
                    }
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(sheetFont(12.5, bold: true)).foregroundStyle(on ? Chrome.ink : Chrome.muted)
                    Text(detail).font(sheetFont(11)).foregroundStyle(muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 22)
            .frame(height: 56)
            .background(Chrome.accent.opacity(on ? 0.08 : 0.02))
            .overlay(alignment: .bottom) { if divider { Rectangle().fill(Chrome.accent.opacity(0.25)).frame(height: 1) } }
        }
    }

    /// A command as typed at the prompt, on the terminal's own colours.
    @MainActor static func command(_ text: String) -> some View {
        let scheme = TerminalScheme.current
        return HStack(spacing: 0) {
            Text("❯ ").foregroundStyle(scheme.palette[2]).bold()
            Text(text).foregroundStyle(scheme.foreground)
        }
        .font(AppFont.sourceCodePro(size: 12))
        .padding(.horizontal, 10).frame(height: 26)
        .background(scheme.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Chrome.border))
    }

    // MARK: Pages

    /// Page 1: start an agent in a tab and the tab becomes Chat.
    struct ChatPage: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Start an agent in any tab, as you always do:").font(sheetFont(12)).foregroundStyle(Chrome.ink)
                HStack(spacing: 8) { command("claude"); command("codex") }
                // Before and after: the tab's terminal with the agent started, then the same tab as Chat.
                HStack(spacing: 10) {
                    TerminalBefore().frame(maxWidth: .infinity).frame(height: 104)
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Chrome.accent)
                    ChatAfter().frame(maxWidth: .infinity).frame(height: 104)
                }
                (Text("The tab switches to Chat by itself. ")
                    .font(sheetFont(11.5)).foregroundColor(Chrome.ink.opacity(0.85))
                + Text("⇧⌘C").font(.system(size: 11, design: .monospaced)).foregroundColor(Chrome.ink)
                + Text(" switches between Chat and the terminal.").font(sheetFont(11.5)).foregroundColor(Chrome.ink.opacity(0.85)))
                    .fixedSize(horizontal: false, vertical: true)
                // Where each agent gets what Chat needs, one line apiece.
                VStack(alignment: .leading, spacing: 5) {
                    note("laptopcomputer", Text("Agents on this Mac need hooks: say Yes in Prefs."))
                    note("network", Text("SSH agents need the helper: confirm it when you ") + Text("ssh").font(AppFont.sourceCodePro(size: 11)).foregroundColor(Chrome.ink) + Text(" to a host."))
                }
            }
        }

        private func note(_ symbol: String, _ text: Text) -> some View {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(Chrome.accent)
                    .frame(width: 16)
                text.font(sheetFont(11)).foregroundStyle(muted).lineLimit(1)
            }
        }
    }

    private struct TerminalBefore: View {
        var body: some View {
            let scheme = TerminalScheme.current
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text("app ").foregroundStyle(scheme.palette[12])
                    Text("❯ ").foregroundStyle(scheme.palette[2]).bold()
                    Text("claude").foregroundStyle(scheme.foreground)
                }
                Spacer(minLength: 0)
                Text("> Run the tests").foregroundStyle(scheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(scheme.foreground.opacity(0.35)))
            }
            .font(AppFont.sourceCodePro(size: 10.5))
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(scheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.border))
            .overlay(alignment: .topTrailing) { modeBadge("terminal") }
        }
    }

    private struct ChatAfter: View {
        var body: some View {
            let colors = ChatColors.current
            VStack(alignment: .trailing, spacing: 6) {
                Text("Run the tests").font(ChatType.font(12)).padding(.horizontal, 9).padding(.vertical, 5)
                    .foregroundStyle(colors.ink)
                    .background(colors.ink.opacity(0.08),
                                in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 3, topTrailingRadius: 10))
                HStack(spacing: 0) {
                    Text("All 48 pass.").font(ChatType.font(12)).foregroundStyle(colors.ink)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(colors.window, in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3, bottomTrailingRadius: 10, topTrailingRadius: 10))
                        .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3, bottomTrailingRadius: 10, topTrailingRadius: 10).strokeBorder(colors.border))
                    Spacer(minLength: 0)
                }
            }
            .padding(9).padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .background(colors.terminal)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.accent.opacity(0.6)))
            .overlay(alignment: .topTrailing) { modeBadge("text.bubble", lit: true, color: Chrome.accent) }
        }
    }

    /// The tab's mode button in the corner of a picture: the terminal glyph, or the Chat bubble lit.
    @MainActor private static func modeBadge(_ symbol: String, lit: Bool = false, color: Color = Chrome.accent) -> some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            .foregroundStyle(lit ? Chrome.window : muted)
            .frame(width: 22, height: 18)
            .background(lit ? color : Chrome.ink.opacity(0.08), in: Capsule())
            .padding(6)
    }

    /// Page 2: the commands that bring tmux, herdr and SSH hosts into the window.
    struct NativePage: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Start tmux or herdr in any tab:").font(sheetFont(12)).foregroundStyle(Chrome.ink)
                HStack(spacing: 8) { command("tmux -CC"); command("tmux -CC attach"); command("herdr") }
                // Before and after: the session started in a tab, then its windows as Dispatch's tabs.
                HStack(spacing: 10) {
                    MultiplexerBefore().frame(maxWidth: .infinity).frame(height: 104)
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Chrome.accent)
                    TabsAfter().frame(maxWidth: .infinity).frame(height: 104)
                }
                Text("tmux windows open as tabs, herdr workspaces as spaces.")
                    .font(sheetFont(11.5)).foregroundStyle(Chrome.ink.opacity(0.85))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Chrome.accent)
                    Text("Works over ssh too: Dispatch asks once to upload its helper. Keep Agent hooks checked for Chat there.")
                        .font(sheetFont(11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private struct MultiplexerBefore: View {
        var body: some View {
            let scheme = TerminalScheme.current
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text("app ").foregroundStyle(scheme.palette[12])
                    Text("❯ ").foregroundStyle(scheme.palette[2]).bold()
                    Text("tmux -CC attach").foregroundStyle(scheme.foreground)
                }
                Spacer(minLength: 0)
            }
            .font(AppFont.sourceCodePro(size: 10.5))
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(scheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.border))
        }
    }

    /// The session's windows as a strip of tabs over the selected one's terminal.
    private struct TabsAfter: View {
        var body: some View {
            let scheme = TerminalScheme.current
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    tab("server", selected: true)
                    tab("tests")
                    tab("claude")
                    Spacer(minLength: 0)
                }
                .padding(6)
                .background(Chrome.sidebar)
                VStack(alignment: .leading, spacing: 2) {
                    Text("listening on :3000").foregroundStyle(scheme.foreground)
                    Text("GET /health 200").foregroundStyle(scheme.palette[8])
                    Text("GET /api/items 200").foregroundStyle(scheme.palette[8])
                }
                .font(AppFont.sourceCodePro(size: 9.5))
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(scheme.background)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.accent.opacity(0.6)))
        }

        private func tab(_ title: String, selected: Bool = false) -> some View {
            Text(title).font(sheetFont(10, bold: selected))
                .foregroundStyle(selected ? Chrome.ink : muted)
                .padding(.horizontal, 8).frame(height: 18)
                .background(selected ? Chrome.accent.opacity(0.18) : Chrome.ink.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Chrome.accent.opacity(0.6) : .clear))
        }
    }

    /// The choices: the agents question and updates, as the sheet asked them before it had pages.
    struct Choices: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                section("Agents").padding(.bottom, 6)
                group(Chrome.accent) {
                    Choice(title: "Yes, I’ll use agents on this Mac", detail: "sets up Chat hooks for the agents installed here", on: true, radio: true)
                    Choice(title: "No, only remotely or not at all", detail: "leaves this Mac’s agent settings untouched", radio: true, divider: false)
                }
                section("Updates").padding(.top, 14).padding(.bottom, 6)
                group(Chrome.accent) {
                    Choice(title: "Keep Dispatch up to date", detail: "checks daily and downloads; asks before restarting", on: true, divider: false)
                }
                Text("Change either later in Settings.").font(sheetFont(11)).foregroundStyle(muted).padding(.top, 14)
            }
        }
    }

    /// The sheet: the header, the page, the footer strip.
    struct Strip<Page: View>: View {
        let page: Int
        @ViewBuilder let body_: Page
        init(page: Int, @ViewBuilder _ body: () -> Page) { self.page = page; body_ = body() }

        var body: some View {
            let header = headers[page], color = Chrome.accent
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    // The consent sheets' header: the glyph on its small blue tile.
                    HStack(spacing: 10) {
                        Image(systemName: header.symbol).font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color(.sRGB, red: 126/255, green: 166/255, blue: 201/255))
                            .frame(width: 28, height: 28)
                            .background(Color(.sRGB, red: 0.12, green: 0.17, blue: 0.21), in: RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(header.title).font(sheetFont(13, bold: true)).foregroundStyle(Chrome.ink)
                            Text(header.subtitle).font(sheetFont(11)).foregroundStyle(muted)
                        }
                    }
                    body_
                }
                .padding(.horizontal, inset).padding(.top, 18).padding(.bottom, 18)
                // The steps centred on the sheet; Back at the left edge, Skip and Next at the right.
                HStack(spacing: 6) {
                    back
                    Spacer(minLength: 8)
                    // On the last page Skip is today's Ask later: nothing saved, asked again next launch.
                    Text("Skip").font(sheetFont(11.5)).foregroundStyle(muted)
                        .padding(.trailing, 6)
                    action
                }
                .padding(.horizontal, 14).frame(height: 54)
                .overlay { HStack(spacing: 6) { ForEach(0..<3, id: \.self) { index in pill(index) } } }
                .background(Chrome.sidebar)
                .overlay(alignment: .top) { Rectangle().fill(Chrome.border).frame(height: 1) }
            }
            .frame(width: width)
            .background(Chrome.window)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Chrome.border))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
        }

        /// Back, dimmed on the first page so the steps never move.
        private var back: some View {
            Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                .foregroundStyle(Chrome.ink.opacity(page == 0 ? 0.25 : 0.75))
                .frame(width: 30, height: 30)
                .background(Chrome.ink.opacity(page == 0 ? 0.03 : 0.07), in: Circle())
        }

        /// Next; the last page's is Let's roll!, which saves both answers and closes.
        private var action: some View {
            HStack(spacing: 6) {
                Text(page < 2 ? "Next" : "Let’s roll!").font(sheetFont(12.5, bold: true))
            }
            .foregroundStyle(Chrome.window)
            .padding(.horizontal, 14).frame(height: 30)
            .background(Chrome.accent, in: Capsule())
        }

        private func pill(_ index: Int) -> some View {
            let current = index == page, color = Chrome.accent
            return HStack(spacing: 4) {
                Image(systemName: headers[index].symbol).font(.system(size: 9, weight: .bold))
                Text(steps[index].0).font(sheetFont(10.5, bold: current))
            }
            .foregroundStyle(current ? Chrome.window : color)
            .padding(.horizontal, 8).frame(height: 24)
            .background(current ? color : color.opacity(0.14), in: Capsule())
        }
    }
}
