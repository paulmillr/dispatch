import SwiftUI

// Terminal: search and Clear Screen.

struct TerminalMock: View {
    var dimmed = false
    var highlight: String? = nil
    let lines = ["~/src/web $ pnpm dev", "", "  vite v6.1.0  ready in 412 ms", "  ➜  Local:   http://localhost:5173/",
                 "  ➜  Network: http://10.0.0.12:5173/", "", "  09:37:40 hmr update src/theme.ts",
                 "  09:37:41 hmr update src/components/Sidebar.tsx", "  09:38:02 hmr update src/theme.ts",
                 "  09:38:09 [vite] warning: src/theme.ts has no default export", "  09:38:12 hmr update src/components/ThemeToggle.tsx", "▯"]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line).frame(height: 20)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(Color.black)
    }
    @ViewBuilder private func lineView(_ line: String) -> some View {
        let font = Font.system(size: 13, design: .monospaced)
        if let highlight, let r = line.range(of: highlight) {
            HStack(spacing: 0) {
                Text(String(line[..<r.lowerBound])).font(font)
                Text(highlight).font(font).foregroundStyle(.black).background(Color.caution)
                Text(String(line[r.upperBound...])).font(font)
            }
        } else {
            Text(line).font(font).foregroundStyle(line.hasPrefix("~") ? Color.added : .primary)
        }
    }
}

/// T1: search. The key bar becomes a search bar; matches light up; the arrows step; the count sits in the field.
struct TerminalSearchScreen: View {
    var body: some View {
        NavigationStack {
            TerminalMock(highlight: "theme.ts")
                .safeAreaBar(edge: .top, spacing: 0) {
                    SegmentCapsule(selected: 0, badge: 3).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
                }
                .safeAreaBar(edge: .bottom) {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            Text("theme.ts").font(.system(size: 16, design: .monospaced)).lineLimit(1).fixedSize()
                            Spacer(minLength: 4)
                            Text("2 of 3").font(.subheadline).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).frame(height: 44)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        HStack(spacing: 0) {
                            Image(systemName: "chevron.up").frame(width: 36, height: 44)
                            Image(systemName: "chevron.down").frame(width: 36, height: 44)
                        }
                        .font(.body.weight(.semibold))
                        .glassEffect(.regular.interactive(), in: Capsule())
                        Text("Done").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink).fixedSize()
                            .padding(.horizontal, 12).frame(height: 44).glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .padding(.horizontal, 12).padding(.bottom, 4)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { TabHeader(title: "dev", subtitle: AnyView(HostPath(path: "~/src/web · pnpm", mono: false))) }
        }
    }
}

/// T2: the key bar's overflow: a long-press on the keyboard key (or the ellipsis) shows Clear Screen, Search, Paste.
struct TerminalMenuScreen: View {
    var body: some View {
        NavigationStack {
            TerminalMock()
                .overlay(alignment: .bottomTrailing) {
                    VStack(alignment: .leading, spacing: 0) {
                        row("Search", "magnifyingglass")
                        row("Paste", "doc.on.clipboard")
                        row("Select all", "selection.pin.in.out")
                        Divider().padding(.vertical, 4)
                        row("Clear screen", "clear", note: "⌘K on a keyboard")
                        row("Reset terminal", "arrow.counterclockwise")
                    }
                    .padding(.vertical, 6)
                    .frame(width: 250)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                    .padding(.trailing, 12).padding(.bottom, 70)
                }
                .safeAreaBar(edge: .top, spacing: 0) {
                    SegmentCapsule(selected: 0, badge: 3).padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)
                }
                .safeAreaBar(edge: .bottom) {
                    HStack(spacing: 0) {
                        ForEach(["Ctrl", "Esc", "Tab", "Alt"], id: \.self) { k in
                            Text(k).font(.system(size: 17, design: .monospaced)).frame(maxWidth: .infinity)
                        }
                        Image(systemName: "dpad").font(.system(size: 20)).frame(maxWidth: .infinity)
                        Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(Color.dispatchPink).frame(maxWidth: .infinity)
                    }
                    .frame(height: 50).padding(.horizontal, 8)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.horizontal, 12).padding(.bottom, 4)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { TabHeader(title: "dev", subtitle: AnyView(HostPath(path: "~/src/web · pnpm", mono: false))) }
        }
    }
    private func row(_ title: String, _ symbol: String, note: String? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: symbol).font(.body)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
