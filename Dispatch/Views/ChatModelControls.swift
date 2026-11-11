import SwiftUI

struct ChatModelControls: View {
    @Environment(\.chatTheme) private var theme
    @Bindable var session: ChatSession
    let coordinator: ChatCoordinator
    let focused: Bool
    var compactEffort = false
    /// Where the footer is tight: the model name's widest, truncated in the middle (its help names it in full).
    var modelWidth: CGFloat? = nil

    /// The model's ID, never an agent's alias or catalog name for it ("Opus", "Claude Opus 5.5").
    private var modelLabel: String { Self.label(for: session.model) }
    /// Claude's banner and footer name the effort only when it differs from the
    /// model's default, and Codex reports none while it is unset, so a known model
    /// without one is on its default effort.
    private var effortLabel: String? {
        session.effort ?? (["claude", "codex"].contains(session.agentID) && session.model != session.agentTitle ? "default" : nil)
    }
    /// Why the picker is dimmed (the agent works, a request waits), instead of the help for a picker that opens.
    private var blocked: String? { coordinator.modelPickBlockReason(session) }

    static func label(for model: String) -> String { AgentModelMenu.label(for: model) }

    var body: some View {
        let currentPicker = session.modelPicker
        return HStack(spacing: 7) {
            if ChatModelLadder.isSecurity(model: session.model) {
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.cyan)
                    .padding(.trailing, -2).accessibilityHidden(true)
            }
            Button { open(.model) } label: {
                Text(modelLabel).lineLimit(1).truncationMode(.middle).frame(maxWidth: modelWidth, alignment: .leading)
                    .footerMenuUnderline(theme.muted)
            }.help(blocked.map { "\(session.model) · \($0)" } ?? "\(session.model) · ⇧⌘M").accessibilityLabel("Choose model").accessibilityValue(session.model)
                .accessibilityHint(blocked ?? "")
                .accessibilityIdentifier("chat-model-picker")
                .keyboardShortcut(focused ? KeyboardShortcut("m", modifiers: [.command, .shift]) : nil)
            // An agent that reports no effort shows none, rather than "unknown"; ⇧⌘E still opens the picker.
            if let effortLabel {
                if !compactEffort { Text("·").accessibilityHidden(true) }
                Button { open(.effort) } label: {
                    Group {
                        if compactEffort {
                            ChatEffortMeter(effort: session.effort)
                        } else {
                            Text(effortLabel)
                        }
                    }.frame(minWidth: 24, minHeight: 20)
                        .contentShape(Rectangle())
                }.help(blocked.map { "Effort: \(effortLabel) · \($0)" } ?? "Effort: \(effortLabel) · ⇧⌘E")
                    .accessibilityLabel("Choose effort").accessibilityValue(effortLabel)
                    .accessibilityHint(blocked ?? "")
                    .accessibilityIdentifier("chat-effort-picker")
                    .keyboardShortcut(focused ? KeyboardShortcut("e", modifiers: [.command, .shift]) : nil)
            } else {
                Button { open(.effort) } label: { Color.clear.frame(width: 0, height: 0) }
                    .buttonStyle(.plain).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                    .keyboardShortcut(focused ? KeyboardShortcut("e", modifiers: [.command, .shift]) : nil)
            }
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
                    coordinator.showTerminal(session)
                })
            }
            .onChange(of: session.model) { _, model in currentPicker?.followSession(model: model, effort: session.effort) }
            .onChange(of: session.effort) { _, effort in currentPicker?.followSession(model: session.model, effort: effort) }
    }

    /// A shortcut's button press arrives as its key: the tracks show their focus ring only for the keyboard.
    private func open(_ column: ChatModelPicker.Column) {
        coordinator.openModelPicker(session, column: column)
        if NSApp.currentEvent?.type == .keyDown { session.modelPicker?.keyboardFocus = true }
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
        Group {
            if picker.showsTracks { ChatModelTracksView(picker: picker, close: close, terminal: terminal).frame(width: 348) }
            else { lists }
        }
            // On glass the popover's own system glass shows through instead of the sidebar fill.
            .background(LiquidGlassStore.shared.active ? Color.clear : theme.sidebar)
            .font(theme.typography.detail).foregroundStyle(theme.ink).preferredColorScheme(theme.isDark ? .dark : .light)
            .focusable().focusEffectDisabled().focused($keyboardFocus)
            .onAppear { keyboardFocus = true }
            .onKeyPress(.upArrow) { if picker.showsTracks { picker.moveTrackRow(-1) } else { picker.move(-1) }; return .handled }
            .onKeyPress(.downArrow) { if picker.showsTracks { picker.moveTrackRow(1) } else { picker.move(1) }; return .handled }
            .onKeyPress(.leftArrow) { guard picker.showsTracks else { return .ignored }; picker.stepTrack(-1); return .handled }
            .onKeyPress(.rightArrow) { guard picker.showsTracks else { return .ignored }; picker.stepTrack(1); return .handled }
            .onKeyPress(.space) {
                guard picker.showsTracks, picker.trackRow == .security else { return .ignored }
                picker.keyboardFocus = true; picker.toggleSecurity(); return .handled
            }
            .onKeyPress(.escape) { guard picker.showsTracks else { return .ignored }; picker.escapeTrack(); return .handled }
            .onKeyPress(.tab) {
                if picker.showsTracks { picker.moveTrackRow(1, wrapping: true) }
                else { picker.showColumn(picker.column == .model ? .effort : .model) }
                return .handled
            }
            .onKeyPress(.return) {
                if picker.showsTracks { close() } else if !picker.loading { picker.chooseHighlighted() }
                return .handled
            }
            // A container, or its identifier would replace those of the tracks and the switch inside.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat-model-effort-popover")
    }

    private var lists: some View {
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
                Button("Open in Terminal", action: terminal).buttonStyle(.bordered).padding(.horizontal, 8)
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

/// The picker when the agent's models are a ladder: MODEL and EFFORT as tracks, the security model a switch under them.
private struct ChatModelTracksView: View {
    @Environment(\.chatTheme) private var theme
    @Bindable var picker: ChatModelPicker
    let close: () -> Void
    let terminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                ChatModelTrackRow(picker: picker, row: .model, terminal: terminal)
                ChatModelTrackRow(picker: picker, row: .effort, terminal: terminal)
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 13)
            if let security = picker.ladder?.security {
                rule
                securityRow(security)
            }
            rule
            footer.padding(.horizontal, 16).padding(.vertical, 8)
        }.onChange(of: picker.trackAnnouncement) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private var rule: some View { Rectangle().fill(theme.border).frame(height: 1) }

    private func securityRow(_ security: ChatModelLadder.Rung) -> some View {
        let on = picker.securityOn
        return HStack(spacing: 10) {
            Image(systemName: on ? "shield.lefthalf.filled" : "shield").font(.system(size: 16))
                .foregroundStyle(on ? theme.cyan : theme.muted).frame(width: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(security.label).foregroundStyle(on ? theme.ink : theme.ink.opacity(0.85))
                Text(picker.securityLine).foregroundStyle(theme.muted).lineLimit(1).minimumScaleFactor(0.75).help(picker.securityLine)
            }
            Spacer(minLength: 8)
            if let command = picker.ladder?.securityCommand {
                Button(command.title) { picker.runSecurityCommand() }
                    .controlSize(.small).focusable(false).disabled(!picker.canRunSecurityCommand)
                    .help("Runs \(command.text): turns it on or off in this chat, and saves that as the default for new chats.")
                    .accessibilityIdentifier("chat-security-command")
            }
            Toggle("", isOn: Binding(get: { on }, set: { _ in picker.toggleSecurity() }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(theme.cyan).focusable(false)
                .disabled(!picker.trackReady)
                .accessibilityLabel(security.label).accessibilityIdentifier("chat-security-model-switch")
        }.padding(.horizontal, 16).padding(.vertical, 10)
            .background(on ? theme.cyan.opacity(0.07) : .clear)
            .overlay { if picker.keyboardFocus && picker.trackRow == .security { RoundedRectangle(cornerRadius: 6).strokeBorder(theme.accent.opacity(0.7), lineWidth: 1.5).padding(3) } }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let status = picker.trackStatus {
                ProgressView().controlSize(.mini)
                Text(status).lineLimit(1).truncationMode(.middle)
            } else {
                Text("← → step")
                Text("↑ ↓ row")
            }
            Spacer(minLength: 8)
            Button("Done", action: close).controlSize(.small).focusable(false)
        }.foregroundStyle(theme.muted)
    }
}

/// One row: the title and value, the track, the caption.
private struct ChatModelTrackRow: View {
    @Environment(\.chatTheme) private var theme
    @Bindable var picker: ChatModelPicker
    let row: ChatModelPicker.TrackRow
    let terminal: () -> Void
    @State private var hover: Int?

    var body: some View {
        let state = picker.trackState(row, hover: hover)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(state.title).font(theme.typography.font(offset: -2, weight: .semibold)).kerning(0.7).foregroundStyle(theme.muted)
                Spacer(minLength: 8)
                if let note = state.note { Text(note).foregroundStyle(theme.yellow) }
                if state.unconfirmed && picker.trackSending { ProgressView().controlSize(.mini) }
                if state.shield {
                    Image(systemName: "shield.lefthalf.filled").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.cyan)
                }
                Text(state.value).monospacedDigit().foregroundStyle(state.valueMuted ? theme.muted : theme.ink)
            }
            ChatModelTrack(picker: picker, row: row, state: state, hover: $hover)
            caption(state.caption).padding(.horizontal, 10)
        }
    }

    @ViewBuilder private func caption(_ caption: ChatModelPicker.TrackCaption) -> some View {
        switch caption {
        case .ends(let low, let high):
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }.foregroundStyle(theme.muted.opacity(0.75)).lineLimit(1)
        case .detail(let text):
            Text(text).foregroundStyle(theme.muted).lineLimit(1).truncationMode(.tail).help(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failure(let text):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(theme.yellow).accessibilityHidden(true)
                Text(text).foregroundStyle(theme.yellow).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("Open in terminal", action: terminal).buttonStyle(.plain).underline().fixedSize().focusable(false)
            }
        }
    }
}

/// A groove of equal stops, filled up to a raised thumb. Held, the thumb lifts into a lens that follows the pointer.
private struct ChatModelTrack: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Bindable var picker: ChatModelPicker
    let row: ChatModelPicker.TrackRow
    let state: ChatModelPicker.TrackState
    @Binding var hover: Int?
    @State private var pressed = false
    @State private var crossed: Int?
    private static let height: CGFloat = 32

    private var held: Double? { picker.trackHeld?.row == row ? picker.trackHeld?.place : nil }
    private var travel: Animation? { reduceMotion ? nil : .spring(duration: 0.25) }
    private var lift: Animation? { reduceMotion ? nil : .easeOut(duration: 0.12) }

    var body: some View {
        GeometryReader { box in
            let width = box.size.width / CGFloat(max(state.stops.count, 1))
            let slot = CGSize(width: max(width - 6, 0), height: Self.height - 6)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.ink.opacity(0.06).shadow(.inner(color: .black.opacity(theme.isDark ? 0.5 : 0.14), radius: 2, y: 1)))
                fill(width: width, total: box.size.width)
                if state.stops.contains(where: { !$0.available }) { hatch }
                if let ghost = state.ghost {
                    Capsule().stroke(theme.ink.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: slot.width, height: slot.height).offset(x: CGFloat(ghost) * width + 3)
                }
                if let hover, held == nil, hover != state.current, state.stops.indices.contains(hover), state.stops[hover].available, !state.disabled {
                    Capsule().fill(theme.ink.opacity(0.1)).frame(width: slot.width, height: slot.height).offset(x: CGFloat(hover) * width + 3)
                }
                thumb(width: width, slot: slot)
                HStack(spacing: 0) {
                    ForEach(Array(state.stops.enumerated()), id: \.element.id) { index, stop in
                        Text(stop.title).font(theme.typography.font(offset: -2, weight: labelWeight(index)))
                            .foregroundStyle(labelColor(index)).lineLimit(1).minimumScaleFactor(0.7)
                            .frame(width: width, height: Self.height)
                    }
                }.allowsHitTesting(false)
                if held != nil {
                    ForEach(state.stops.indices, id: \.self) { index in
                        Circle().fill(theme.ink.opacity(0.4)).frame(width: 2.5, height: 2.5)
                            .offset(x: (CGFloat(index) + 0.5) * width - 1.25, y: Self.height / 2 - 4.5)
                    }
                }
            }.frame(width: box.size.width, height: Self.height, alignment: .leading)
                .contentShape(Capsule())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point): hover = stop(at: point.x, width: width)
                    case .ended: hover = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in changed(value, width: width) }
                    .onEnded { value in ended(value, width: width) })
        }.frame(height: Self.height)
            .overlay(Capsule().strokeBorder(theme.ink.opacity(0.08), lineWidth: 1).allowsHitTesting(false))
            .opacity(state.dimmed || state.disabled ? 0.6 : 1)
            .overlay { if picker.keyboardFocus && picker.trackRow == row { Capsule().stroke(theme.accent.opacity(0.7), lineWidth: 1.5).padding(-3) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row == .model ? "Model" : "Effort")
            .accessibilityValue(state.current.map { "\(state.value), \($0 + 1) of \(state.stops.count)" } ?? state.value)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: picker.stepTrack(1, row: row)
                case .decrement: picker.stepTrack(-1, row: row)
                @unknown default: break
                }
            }
            .accessibilityIdentifier(row == .model ? "chat-model-track" : "chat-effort-track")
    }

    private func stop(at x: CGFloat, width: CGFloat) -> Int? {
        guard width > 0, !state.stops.isEmpty else { return nil }
        return min(max(Int(x / width), 0), state.stops.count - 1)
    }

    private func place(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width) - 0.5, 0), Double(max(state.stops.count - 1, 0)))
    }

    private func changed(_ value: DragGesture.Value, width: CGFloat) {
        let place = place(at: value.location.x, width: width)
        if !pressed {
            pressed = true
            crossed = Int(place.rounded())
            picker.pressTrack(row, at: place)
        } else if held != nil {
            picker.dragTrack(to: place)
            if crossed != Int(place.rounded()) {
                crossed = Int(place.rounded())
                #if canImport(AppKit)
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                #endif
            }
        }
    }

    private func ended(_ value: DragGesture.Value, width: CGFloat) {
        pressed = false
        let moved = hypot(value.translation.width, value.translation.height) > 3
        // A click lands on the stop under it; a drag ends at the nearest.
        let at = moved ? place(at: value.location.x, width: width) : stop(at: value.location.x, width: width).map(Double.init) ?? 0
        picker.releaseTrack(row, at: at, moved: moved)
    }

    private func labelWeight(_ index: Int) -> Font.Weight {
        guard state.stops[index].available else { return .regular }
        if let held { return Int(held.rounded()) == index ? .semibold : .regular }
        return index == state.current ? .semibold : .regular
    }

    private func labelColor(_ index: Int) -> Color {
        guard state.stops[index].available else { return theme.muted.opacity(0.45) }
        if let held {
            if Int(held.rounded()) == index { return theme.ink }
            return Double(index) < held ? theme.ink.opacity(0.78) : theme.muted
        }
        if index == state.current { return state.unconfirmed ? theme.ink : theme.terminal }
        if index == hover { return theme.ink }
        if let current = state.current, index < current { return theme.ink.opacity(0.78) }
        return theme.muted
    }

    @ViewBuilder private func fill(width: CGFloat, total: CGFloat) -> some View {
        if let place = held ?? state.current.map(Double.init) {
            Capsule().fill(LinearGradient(colors: [theme.ink.opacity(0.02), theme.ink.opacity(0.17)], startPoint: .leading, endPoint: .trailing))
                .frame(width: min(total, CGFloat(place + 1) * width))
                .animation(travel, value: state.current)
        }
    }

    /// One shape from pill to lens, so a release travels from under the pointer to its stop. A tail follows slower and
    /// fades into the thumb as it arrives.
    @ViewBuilder private func thumb(width: CGFloat, slot: CGSize) -> some View {
        if let place = held ?? state.current.map(Double.init) {
            let lens = held != nil && !reduceMotion
            if !reduceMotion, held == nil {
                ForEach([(0.34, 0.32), (0.18, 0.42)], id: \.0) { opacity, duration in
                    Capsule().fill(theme.ink.opacity(opacity)).frame(width: slot.width, height: slot.height)
                        .offset(x: CGFloat(place) * width + 3)
                        .animation(.easeOut(duration: duration), value: state.current)
                }
            }
            Capsule().fill(thumbFill(held: held != nil))
                .overlay { if held != nil { Capsule().strokeBorder(.white.opacity(theme.isDark ? 0.5 : 1), lineWidth: 1) } }
                .overlay { if state.unconfirmed && held == nil { Capsule().strokeBorder(theme.ink.opacity(0.6), lineWidth: 1) } }
                .shadow(color: .black.opacity(state.unconfirmed ? 0 : theme.isDark ? 0.5 : 0.3), radius: held != nil ? 9 : 2.5, y: held != nil ? 4 : 1)
                .frame(width: lens ? width + 6 : slot.width, height: lens ? Self.height + 8 : slot.height)
                .offset(x: CGFloat(place) * width + (lens ? -3 : 3))
                .animation(travel, value: state.current)
                .animation(lift, value: held != nil)
        }
    }

    private func thumbFill(held: Bool) -> AnyShapeStyle {
        if held { return AnyShapeStyle(reduceTransparency ? theme.sidebar : Color.white.opacity(theme.isDark ? 0.2 : 0.9)) }
        if state.unconfirmed { return AnyShapeStyle(theme.ink.opacity(0.17)) }
        return AnyShapeStyle(LinearGradient(colors: [theme.ink.opacity(0.99), theme.ink.opacity(0.84)], startPoint: .top, endPoint: .bottom))
    }

    /// Stops the model lacks: the groove hatched over them.
    private var hatch: some View {
        let color = theme.ink.opacity(0.1), stops = state.stops
        return Canvas { context, size in
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
            let width = size.width / CGFloat(stops.count)
            for index in stops.indices where !stops[index].available {
                var layer = context
                let rect = CGRect(x: width * CGFloat(index), y: 0, width: width, height: size.height)
                layer.clip(to: Path(rect))
                var lines = Path()
                var x = rect.minX - size.height
                while x < rect.maxX {
                    lines.move(to: CGPoint(x: x, y: size.height))
                    lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 6
                }
                layer.stroke(lines, with: .color(color), lineWidth: 1)
            }
        }.allowsHitTesting(false)
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
