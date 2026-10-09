import SwiftUI

struct ChatModelControls: View {
    @Environment(\.chatTheme) private var theme
    @Bindable var session: ChatSession
    let coordinator: ChatCoordinator
    let focused: Bool
    var compactEffort = false

    /// The model's ID, never an agent's alias or catalog name for it ("Opus", "Claude Opus 5.5").
    private var modelLabel: String { Self.label(for: session.model) }
    /// Claude's banner and footer name the effort only when it differs from the
    /// model's default, and Codex reports none while it is unset, so a known model
    /// without one is on its default effort.
    private var effortLabel: String {
        session.effort ?? (["claude", "codex"].contains(session.agentID) && session.model != session.agentTitle ? "default" : "unknown")
    }

    /// Family, then version: claude-opus-5-5[1m] → opus-5.5[1m], gpt-6.1-sol → sol-6.1. Also covers dated, legacy
    /// (claude-3-5-sonnet), Bedrock (us.anthropic.claude-…-v1:0), Vertex (…@20250805) and provider/model IDs; other
    /// models keep their ID, without the provider.
    static func label(for model: String) -> String {
        let plain = model.split(separator: "/").last.map(String.init) ?? model
        guard let vendor = model.range(of: "(?:^|[./])(?:claude|gpt)-", options: .regularExpression) else { return plain }
        var id = String(model[vendor.upperBound...]), suffix = ""
        if let bracket = id.firstIndex(of: "[") { suffix = String(id[bracket...]); id = String(id[..<bracket]) }
        id = id.replacingOccurrences(of: "(?:-latest|[-@][0-9]{8})?(?:-v[0-9]+(?::[0-9]+)?)?$", with: "", options: .regularExpression)
        let parts = id.split(separator: "-").map(String.init)
        let isVersion = { (part: String) in part.range(of: "^[0-9]+(?:\\.[0-9]+)*$", options: .regularExpression) != nil }
        let family = parts.filter { !isVersion($0) }, version = parts.filter(isVersion)
        // GPT IDs lead with the version (gpt-6.1-sol); without a name after one (gpt-5.5, gpt-4o) the ID stays.
        let gpt = model[vendor].hasSuffix("gpt-")
        guard !family.isEmpty, !gpt || parts.first.map(isVersion) == true else { return plain }
        return (family + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: "-") + suffix
    }

    var body: some View {
        let currentPicker = session.modelPicker
        return HStack(spacing: 7) {
            Button { coordinator.openModelPicker(session, column: .model) } label: {
                Text(modelLabel).footerMenuUnderline(theme.muted)
            }.help(session.model).accessibilityLabel("Choose model").accessibilityValue(session.model)
                .accessibilityIdentifier("chat-model-picker")
                .keyboardShortcut(focused ? KeyboardShortcut("m", modifiers: [.command, .shift]) : nil)
            if !compactEffort { Text("·").accessibilityHidden(true) }
            Button { coordinator.openModelPicker(session, column: .effort) } label: {
                Group {
                    if compactEffort {
                        ChatEffortMeter(effort: session.effort)
                    } else {
                        Text(effortLabel)
                    }
                }.frame(minWidth: 24, minHeight: 20)
                    .contentShape(Rectangle())
            }.help("Effort: \(effortLabel) · ⇧⌘E")
                    .accessibilityLabel("Choose effort").accessibilityValue(effortLabel)
                    .accessibilityIdentifier("chat-effort-picker")
                    .keyboardShortcut(focused ? KeyboardShortcut("e", modifiers: [.command, .shift]) : nil)
        }.buttonStyle(.plain).disabled(!coordinator.canPickModel(session))
            .background {
                Button { coordinator.openModelPicker(session, column: .effort, cycle: true) } label: { Color.clear.frame(width: 0, height: 0) }
                    // This shortcut-only button must not draw a default bezel
                    // behind the model label or intercept pointer input.
                    .buttonStyle(.plain).opacity(0).allowsHitTesting(false)
                    .keyboardShortcut(focused ? KeyboardShortcut("e", modifiers: [.command, .shift, .option]) : nil)
                    .disabled(!coordinator.canPickModel(session)).accessibilityHidden(true)
            }
            .popover(item: Binding(get: { currentPicker?.presented == true ? currentPicker : nil }, set: {
                if $0 == nil { currentPicker?.close() }
            }), arrowEdge: .top) { picker in
                ChatModelPickerView(picker: picker, close: { picker.close() }, terminal: {
                    guard session.modelPicker === picker else { return }
                    picker.abandon(); session.modelPicker = nil
                    coordinator.chooseChat(false, session: session)
                })
            }
    }
}

struct ChatEffortMeter: View {
    @Environment(\.chatTheme) private var theme
    let effort: String?

    private var filled: Int {
        switch effort?.lowercased() {
        case "low": 0
        case "medium": 1
        case "high": 2
        case "xhigh", "extra high", "max": 3
        case "ultra", "ultracode": 4
        default: 0
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < filled ? (index == 3 ? theme.accent : theme.ink.opacity(0.8)) : .clear)
                    .overlay {
                        if index < 3 && index >= filled {
                            RoundedRectangle(cornerRadius: 1).strokeBorder(theme.muted.opacity(0.5), lineWidth: 1)
                        }
                    }
                    .frame(width: 3, height: CGFloat(min(10, 4 + index * 3)))
            }
        }.frame(width: 18, height: 10, alignment: .bottomLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Effort: \(effort ?? "unknown")")
    }
}

struct ChatModelPickerView: View {
    @Environment(\.chatTheme) private var theme
    @Bindable var picker: ChatModelPicker
    let close: () -> Void
    let terminal: () -> Void
    @FocusState private var keyboardFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !picker.scope.isEmpty {
                Text(picker.scopeTitle).font(theme.typography.font(offset: -2, weight: .semibold)).padding(8)
                if let detail = picker.scopeDetail { Text(detail).font(theme.typography.detail).foregroundStyle(theme.muted).padding(.horizontal, 8) }
                ForEach(picker.scope) { choice in
                    Button { picker.selectScope(choice) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.name)
                            Text(choice.detail).font(theme.typography.detail).foregroundStyle(theme.muted)
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            .background(choice.name == picker.highlightedScope ? theme.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).disabled(picker.loading)
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    column("MODEL", rows: picker.models, highlight: picker.highlightedModel, active: picker.column == .model) {
                        picker.selectModel($0.name)
                    }
                    Rectangle().fill(theme.border).frame(width: 1)
                    column("EFFORT", rows: picker.efforts, highlight: picker.highlightedEffort, active: picker.column == .effort) {
                        picker.selectEffort($0)
                    }
                }.frame(height: min(290, max(110, CGFloat(max(picker.models.count, picker.efforts.count)) * max(31, theme.typography.detailLineHeight * 2 + 7) + 30)))
            }
            if let error = picker.error {
                Text(error).font(theme.typography.detail).foregroundStyle(theme.muted).padding(.horizontal, 8)
                Button("Open in terminal", action: terminal).buttonStyle(.bordered).padding(.horizontal, 8)
            }
            Rectangle().fill(theme.border).frame(height: 1)
            HStack(spacing: 8) {
                if picker.loading {
                    ProgressView().controlSize(.mini)
                    Text("Reading agent choices…")
                }
                Spacer(minLength: 0)
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }.font(theme.typography.detail).foregroundStyle(theme.muted).padding(.horizontal, 8).padding(.vertical, 4)
        }.padding(6).frame(width: 470)
            // On glass the popover's own system glass shows through instead of the sidebar fill.
            .background(LiquidGlassStore.shared.active ? Color.clear : theme.sidebar)
            .font(theme.typography.detail).foregroundStyle(theme.ink).preferredColorScheme(theme.isDark ? .dark : .light)
            .focusable().focusEffectDisabled().focused($keyboardFocus)
            .onAppear { keyboardFocus = true }
            .onKeyPress(.upArrow) { picker.move(-1); return .handled }
            .onKeyPress(.downArrow) { picker.move(1); return .handled }
            .onKeyPress(.tab) { picker.showColumn(picker.column == .model ? .effort : .model); return .handled }
            .onKeyPress(.return) { if !picker.loading { picker.chooseHighlighted() }; return .handled }
            .accessibilityIdentifier("chat-model-effort-popover")
    }

    private func column(_ title: String, rows: [AgentModelMenu.Choice], highlight: String, active: Bool,
                        choose: @escaping (AgentModelMenu.Choice) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(theme.typography.detail).foregroundStyle(theme.muted).padding(.horizontal, 8).padding(.vertical, 6)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(rows) { choice in
                            choiceRow(choice, effort: title == "EFFORT", highlighted: choice.name == highlight && active,
                                      choose: choose)
                        }
                        if rows.isEmpty && !picker.loading {
                            Text("Choose a model to see its effort levels.").font(theme.typography.detail).foregroundStyle(theme.muted).padding(8)
                        }
                    }
                }.onChange(of: highlight) { _, name in scroll.scrollTo(name) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func choiceRow(_ choice: AgentModelMenu.Choice, effort: Bool, highlighted: Bool,
                           choose: @escaping (AgentModelMenu.Choice) -> Void) -> some View {
        Button { choose(choice) } label: {
            HStack(spacing: 6) {
                Text(effort ? choice.name.lowercased() : picker.displayName(choice)).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                if effort && !choice.detail.isEmpty {
                    Text(choice.detail).font(theme.typography.detail).foregroundStyle(theme.muted).lineLimit(1)
                } else if choice.isDefault { Text("default").font(theme.typography.detail).foregroundStyle(theme.muted) }
                Image(systemName: "checkmark").opacity(choice.current ? 1 : 0).frame(width: 10)
            }.padding(.horizontal, 8).frame(minHeight: max(30, theme.typography.detailLineHeight * 2 + 6)).contentShape(Rectangle())
                .background(highlighted ? theme.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).help(choice.detail).disabled(picker.loading).id(choice.id)
            .accessibilityLabel(effort ? choice.name : picker.displayName(choice)).accessibilityValue(choice.current ? "Current" : "")
    }
}

extension View {
    /// The thin solid rule under a composer footer menu's label (the model control, the drafts menu), set below the
    /// text's descenders so it never cuts through them.
    func footerMenuUnderline(_ color: Color) -> some View {
        overlay(alignment: .bottom) {
            Rectangle().fill(color.opacity(0.4)).frame(height: 1).offset(y: 2)
        }
    }
}
