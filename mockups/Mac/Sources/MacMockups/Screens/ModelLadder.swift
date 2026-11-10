import SwiftUI

// Exploration: the model and effort picker as two tracks. Today's picker (ChatModelPickerView) is two lists, MODEL and
// EFFORT, 470 points wide. When every model the agent lists is a rung of one family the app knows the order of (haiku,
// sonnet, opus, fable; luna, terra, astra), the model is a level as the effort is, and the picker draws both as
// sliders with a stop per choice. The family's security model (mythos, daybreak-blue) is no rung: a switch of its own,
// for this conversation. Versions, effort levels, each stop's line and the current choice still come from the agent;
// only the two orders are the app's.
//
// A track: a recessed groove, filled up to the thumb and deeper toward it; the thumb a raised pill. Pointing at a stop
// lights it and says what it is; a click sends the thumb there; held, the thumb lifts into a lens and follows the
// pointer, the stops ticks; arrow keys move it at once. A choice is translucent until the agent confirms it.

enum ModelLadder {
    static let screens: [Screen] = [
        Screen("E1-ladder", group: "ladder", "Model and effort as two tracks, opened from the composer's footer") {
            inWindow(Popover(picker: claude, arrow: 40))
        },
        Screen("E2-ladder-today", group: "ladder", "Today's two lists beside the tracks") {
            board {
                HStack(alignment: .top, spacing: 32) {
                    tile("Today", "Two lists. The security model is one more row among the models.") { Today() }
                    tile("Tracks", "Two sliders with a stop per choice; the security model a switch of its own.") { Popover(picker: claude) }
                }
            }
        },
        Screen("E3-ladder-states", group: "ladder", "The popover's states: pointing, dragging, switching, a missing level, the security model, a failure, keys, the other family") {
            board {
                HStack(alignment: .top, spacing: 32) {
                    tile("At rest", "fable-5.2 · high.") { Popover(picker: claude) }
                    tile("Pointing", "The stop lights; the header and the caption say what it is. Nothing changes yet.") {
                        Popover(picker: with(claude) { $0.hover = (.model, 2) })
                    }
                    tile("Dragging", "The thumb lifts into a lens and follows the pointer; release applies the nearest stop.") {
                        Popover(picker: with(claude) { $0.held = 1.75 })
                    }
                }
                HStack(alignment: .top, spacing: 32) {
                    tile("Switching", "There at once, translucent until the agent confirms. The old stop keeps an outline.") {
                        Popover(picker: with(claude) { $0.model = 1; $0.unconfirmed = true; $0.wasModel = 3 })
                    }
                    tile("A model without the level", "haiku stops at high: the rest is hatched, and the effort came down.") {
                        Popover(picker: with(claude) { $0.model = 0; $0.effort = "high"; $0.wasEffort = "xhigh" })
                    }
                    tile("Security model on", "Off the ladder: the track keeps the rung it returns to. Effort stays live.") {
                        Popover(picker: with(claude) { $0.specialOn = true })
                    }
                }
                HStack(alignment: .top, spacing: 32) {
                    tile("It didn't switch", "The thumb is back where it was, and the row says so, with the way out.") {
                        Popover(picker: with(claude) { $0.failure = "Couldn't switch to opus-5.5." })
                    }
                    tile("Opened with ⇧⌘E", "By keyboard the row the arrows step has the ring; ↑ ↓ change rows.") {
                        Popover(picker: with(claude) { $0.focus = .effort })
                    }
                    tile("The other family", "luna, terra, astra, and daybreak-blue as its switch.") { Popover(picker: codex) }
                }
            }
        },
        Screen("E4-ladder-footer", group: "ladder", "The composer footer's model and effort: words, folded, and the security model on") {
            board {
                HStack(alignment: .top, spacing: 40) {
                    tile("Words", "As today.") { FooterChip(model: "fable-5.2", effort: "high") }
                    tile("Folded", "A tight footer: the effort as its meter, as today.") { FooterChip(model: "fable-5.2", effort: "high", folded: true) }
                    tile("Security model on", "The shield says which chat is on it.") { FooterChip(model: "mythos-5.2", effort: "high", shield: true) }
                    tile("On, folded", "") { FooterChip(model: "mythos-5.2", effort: "high", folded: true, shield: true) }
                }
            }
        },
        Screen("E5-ladder-storyboard", group: "ladder", "A track frame by frame: the pointer, the keys, the edges") {
            storyboard
        },
    ]

    // MARK: Data

    struct Rung {
        let name: String
        let id: String
        /// The agent's own line for the model (its menu row's description).
        var detail = ""
        let efforts: [String]
    }

    struct Ladder {
        var rungs: [Rung]
        /// The family's security model: listed by the agent, never a rung.
        var special: Rung?
        /// The rung chosen (while unconfirmed, the one asked for), or the one to return to while the security model
        /// is on.
        var model: Int
        var effort: String
        var specialOn = false
        enum Row { case model, effort }
        /// The row the arrow keys step; shown only when the keyboard opened or moved the picker.
        var focus: Row?
        /// The pointer's stop.
        var hover: (row: Row, stop: Int)?
        /// The model's thumb held, at this place in stops (1.5: halfway from the second stop to the third).
        var held: CGFloat?
        /// The model's thumb on its way from a stop, this far.
        var travel: (from: Int, progress: CGFloat)?
        /// Asked for, not confirmed by the agent yet.
        var unconfirmed = false
        var wasModel: Int?
        /// The effort before a model change brought it down.
        var wasEffort: String?
        var failure: String?

        static let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        /// Every level a model of the family has, weakest first: a stop keeps its place from model to model.
        var levels: [String] {
            Self.order.filter { level in (rungs + [special].compactMap { $0 }).contains { $0.efforts.contains(level) } }
        }
        var shown: Rung { specialOn ? special ?? rungs[model] : rungs[model] }

        var modelRow: LevelRow {
            let hovered = hover?.row == .model ? hover?.stop : nil
            var level = Level(stops: rungs.map(\.name))
            level.current = specialOn ? nil : model
            level.hover = hovered
            level.ghost = specialOn ? model : unconfirmed ? wasModel : nil
            level.focused = focus == .model
            level.unconfirmed = unconfirmed
            level.dimmed = specialOn
            level.held = held
            level.travel = travel
            level.cursor = held ?? hovered.map { CGFloat($0) }
            var row = LevelRow(title: "MODEL", value: rungs[model].id, level: level, caption: .ends("faster", "smarter"))
            if specialOn, let special {
                row.value = special.id; row.style = .shield
                row.caption = .detail("Off the ladder. A stop here turns it off.")
            } else if let held {
                let near = rungs[Int(held.rounded())]
                row.value = near.id; row.caption = .detail(near.detail)
            } else if let hovered {
                row.value = rungs[hovered].id; row.style = hovered == model ? .plain : .muted
                row.caption = .detail(rungs[hovered].detail)
            } else if unconfirmed {
                row.style = .busy
            }
            if let failure { row.caption = .warning(failure, action: "Open in terminal") }
            return row
        }

        var effortRow: LevelRow {
            let levels = self.levels
            let hovered = hover?.row == .effort ? hover?.stop : nil
            let missing = Set(levels.indices.filter { !shown.efforts.contains(levels[$0]) })
            var level = Level(stops: levels)
            level.current = levels.firstIndex(of: effort)
            level.hover = hovered
            level.ghost = wasEffort.flatMap { levels.firstIndex(of: $0) }
            level.unavailable = missing
            level.focused = focus == .effort
            level.cursor = hovered.map { CGFloat($0) }
            var row = LevelRow(title: "EFFORT", value: effort, level: level, caption: .ends("quicker", "more thorough"))
            if let wasEffort { row.note = "was \(wasEffort)" }
            if let hovered, missing.contains(hovered) {
                row.caption = .detail("\(shown.id) stops at \(shown.efforts.last ?? effort).")
            } else if let hovered, levels[hovered] != effort {
                row.value = levels[hovered]; row.style = .muted
            }
            return row
        }
    }

    static let five = ["low", "medium", "high", "xhigh", "max"]
    static let claude = Ladder(rungs: [
        Rung(name: "haiku", id: "haiku-5.5", detail: "Fastest, for quick answers.", efforts: ["low", "medium", "high"]),
        Rung(name: "sonnet", id: "sonnet-5.5", detail: "Best for everyday tasks.", efforts: five),
        Rung(name: "opus", id: "opus-5.5", detail: "Complex work and long tasks.", efforts: five),
        Rung(name: "fable", id: "fable-5.2", detail: "Most capable, for the hardest work.", efforts: five),
    ], special: Rung(name: "mythos", id: "mythos-5.2", efforts: five), model: 3, effort: "high")

    static let codex = Ladder(rungs: [
        Rung(name: "luna", id: "luna-6", detail: "Fast and light.", efforts: ["minimal", "low", "medium", "high"]),
        Rung(name: "terra", id: "terra-6", detail: "Everyday coding.", efforts: ["minimal", "low", "medium", "high"]),
        Rung(name: "astra", id: "astra-6", detail: "Deep reasoning for hard problems.", efforts: ["minimal", "low", "medium", "high", "xhigh"]),
    ], special: Rung(name: "daybreak-blue", id: "daybreak-blue", efforts: ["low", "medium", "high", "xhigh"]),
       model: 2, effort: "medium")

    static func with(_ picker: Ladder, _ change: (inout Ladder) -> Void) -> Ladder {
        var copy = picker
        change(&copy)
        return copy
    }

    // MARK: Stages

    @MainActor private static func inWindow(_ popover: some View) -> some View {
        DispatchWindow(sidebar: Sample.sidebar) {
            Pane(strip: StripModel(tabs: [
                TabItem(title: "Fix the invoice rounding", activity: .finished, shortcut: 1, selected: true),
                TabItem(title: "tests", shortcut: 2),
            ], mode: .chat, agent: true)) {
                ChatPane(items: Sample.chat, composer: ComposerModel(draft: "Also cover the zero-amount case", model: "fable-5.2"))
                    .overlay(alignment: .bottomLeading) {
                        popover.padding(.leading, Chrome.paneContentInset).padding(.bottom, 46)
                    }
            }
        }
    }

    /// One track through an interaction, a frame a row: what the hand does, then what the track shows.
    @MainActor private static var storyboard: some View {
        let haiku = with(claude) { $0.model = 0; $0.effort = "high" }
        return board {
            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 16) {
                    heading("Pointer")
                    frame(1, "At rest", "The groove is filled up to the thumb, deeper toward it.", claude.modelRow)
                    frame(2, "Point", "The stop lights. The header names it and the caption is the agent's own line for it. Nothing changes.",
                          with(claude) { $0.hover = (.model, 1) }.modelRow)
                    frame(3, "Click", "The thumb springs over in 0.25 s, trailing from the stop it left. Reduce Motion: it jumps.",
                          with(claude) { $0.model = 1; $0.travel = (3, 0.5) }.modelRow)
                    frame(4, "Not confirmed yet", "There at once, translucent until the agent says so; the stop it left keeps an outline.",
                          with(claude) { $0.model = 1; $0.unconfirmed = true; $0.wasModel = 3 }.modelRow)
                    frame(5, "Press", "Held, the thumb lifts into a lens and the stops show as ticks.",
                          with(claude) { $0.held = 3 }.modelRow)
                    frame(6, "Drag", "It follows the pointer, a tap in the trackpad at each stop. Release applies the nearest; Esc puts it back.",
                          with(claude) { $0.held = 1.75 }.modelRow)
                }
                VStack(alignment: .leading, spacing: 16) {
                    heading("Keys and edges")
                    frame(7, "← →", "The thumb moves at once and applies after 0.6 s without a key: ← ← ← is one switch. Esc before that puts it back.",
                          with(claude) { $0.focus = .model; $0.model = 2; $0.unconfirmed = true; $0.wasModel = 3 }.modelRow)
                    frame(8, "No such level", "haiku stops at high, so the rest of the groove is hatched. Pointing there says why; a click does nothing.",
                          with(haiku) { $0.hover = (.effort, 3) }.effortRow)
                    frame(9, "The effort came down", "A model without the level brings the effort to its highest, and says so until the picker closes.",
                          with(haiku) { $0.wasEffort = "xhigh" }.effortRow)
                    frame(10, "Security model on", "The thumb has left the track; the outline is where it returns. A stop here turns the switch off.",
                          with(claude) { $0.specialOn = true }.modelRow)
                    frame(11, "It didn't switch", "The thumb springs back, and the caption says so, with the way out.",
                          with(claude) { $0.failure = "Couldn't switch to opus-5.5." }.modelRow)
                }
            }
        }
    }

    @MainActor private static func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(ChatColors.current.ink).padding(.bottom, 2)
    }

    @MainActor private static func frame(_ number: Int, _ title: String, _ note: String, _ row: LevelRow) -> some View {
        let colors = ChatColors.current
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Callout(number: number)
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.ink)
                }
                Text(note).font(.system(size: 11.5)).foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 210, alignment: .leading)
            row.padding(.horizontal, 16).padding(.vertical, 13).frame(width: Popover.width)
                .foregroundStyle(colors.ink).background(PopoverCard(lifted: false))
        }
    }

    /// Close-ups stand on the chat's background, where the popover opens.
    @MainActor private static func board(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 36) { content() }
            .padding(32)
            .background(ChatColors.current.terminal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @MainActor private static func tile(_ title: String, _ note: String, @ViewBuilder _ content: () -> some View) -> some View {
        let colors = ChatColors.current
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.ink)
                Text(note.isEmpty ? " " : note).font(.system(size: 11.5)).foregroundStyle(colors.muted)
                    .lineLimit(2, reservesSpace: true).frame(maxWidth: Popover.width, alignment: .leading)
            }
            content()
        }
        .fixedSize()
    }

    // MARK: The popover

    struct Popover: View {
        var picker: Ladder
        /// Where the arrow points down from, from the leading edge; nil draws none.
        var arrow: CGFloat?
        static let width: CGFloat = 348

        var body: some View {
            let colors = ChatColors.current
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    picker.modelRow
                    picker.effortRow
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 13)
                if let special = picker.special {
                    rule
                    specialRow(special)
                }
                rule
                footer.padding(.horizontal, 16).padding(.vertical, 8)
            }
            .frame(width: Self.width)
            .foregroundStyle(colors.ink)
            .background(PopoverCard(arrow: arrow))
        }

        private var rule: some View { Rectangle().fill(ChatColors.current.ink.opacity(0.09)).frame(height: 1) }

        private func specialRow(_ special: Rung) -> some View {
            let colors = ChatColors.current
            let on = picker.specialOn
            return HStack(spacing: 10) {
                Image(systemName: on ? "shield.lefthalf.filled" : "shield").font(.system(size: 16, weight: .regular))
                    .foregroundStyle(on ? ModelLadder.shield : colors.muted).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(special.id).font(ChatType.font(12, weight: .medium)).foregroundStyle(on ? colors.ink : colors.ink.opacity(0.85))
                    Text(on ? "On for this chat. Off returns to \(picker.rungs[picker.model].id)." : "For security work. This chat only.")
                        .font(ChatType.font(11)).foregroundStyle(colors.muted)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: .constant(on)).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(ModelLadder.shield)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(on ? ModelLadder.shield.opacity(0.07) : .clear)
        }

        private var footer: some View {
            let colors = ChatColors.current
            return HStack(spacing: 10) {
                if picker.unconfirmed {
                    Spinner()
                    Text("Switching to \(picker.rungs[picker.model].id)…").foregroundStyle(colors.muted)
                } else {
                    key("← →", "step")
                    key("↑ ↓", "row")
                }
                Spacer(minLength: 8)
                Button("Done") {}.controlSize(.small)
            }
            .font(ChatType.font(11))
        }

        private func key(_ keys: String, _ action: String) -> some View {
            let colors = ChatColors.current
            return HStack(spacing: 4) {
                Text(keys).font(AppFont.shortcut(size: 10.5)).foregroundStyle(colors.muted)
                Text(action).foregroundStyle(colors.muted.opacity(0.8))
            }
        }
    }

    /// The security model's colour, apart from everything chosen on the ladder.
    @MainActor static var shield: Color { ChatColors.current.cyan }

    /// A popover as macOS draws one over the chat (its glass does not draw offscreen: an opaque tone), with its arrow.
    struct PopoverCard: View {
        var arrow: CGFloat?
        /// Off for a storyboard's strips, which lie on the board.
        var lifted = true
        var body: some View {
            let dark = Chrome.palette.isDark
            let fill = dark ? Color(white: 0.155) : Color(white: 0.975)
            let edge = dark ? Color.white.opacity(0.13) : Color.black.opacity(0.1)
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            ZStack(alignment: .bottomLeading) {
                if let arrow {
                    RoundedRectangle(cornerRadius: 3).fill(fill)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(edge, lineWidth: 0.5))
                        .frame(width: 18, height: 18).rotationEffect(.degrees(45)).offset(x: arrow - 9, y: 8)
                }
                shape.fill(fill).overlay(shape.strokeBorder(edge, lineWidth: 0.5))
                if let arrow { Rectangle().fill(fill).frame(width: 22, height: 2).offset(x: arrow - 11, y: -0.5) }
            }
            .compositingGroup()
            .shadow(color: .black.opacity(lifted ? (dark ? 0.5 : 0.18) : (dark ? 0.3 : 0.08)), radius: lifted ? 18 : 5, y: lifted ? 8 : 2)
        }
    }

    // MARK: A row: its header, its track, its caption

    enum Caption {
        /// What the track's two ends mean.
        case ends(String, String)
        /// What the stop under the pointer or the thumb is.
        case detail(String)
        case warning(String, action: String)
    }

    struct LevelRow: View {
        var title: String
        var value: String
        enum Style { case plain, muted, busy, shield }
        /// The value: the choice; muted, the stop pointed at; busy, asked for and not confirmed; the security model.
        var style = Style.plain
        var note: String?
        var level: Level
        var caption: Caption

        var body: some View {
            let colors = ChatColors.current
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text(title).font(ChatType.font(11, weight: .semibold)).kerning(0.7).foregroundStyle(colors.muted)
                    Spacer(minLength: 8)
                    if let note { Text(note).font(ChatType.font(11)).foregroundStyle(colors.yellow) }
                    if style == .busy { Spinner() }
                    if style == .shield {
                        Image(systemName: "shield.lefthalf.filled").font(.system(size: 11, weight: .medium)).foregroundStyle(ModelLadder.shield)
                    }
                    Text(value).font(ChatType.font(12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(style == .muted ? colors.muted : colors.ink)
                }
                LevelTrack(level: level)
                Group {
                    switch caption {
                    case .ends(let low, let high):
                        HStack {
                            Text(low)
                            Spacer()
                            Text(high)
                        }
                        .font(ChatType.font(10.5)).foregroundStyle(colors.muted.opacity(0.75))
                    case .detail(let text):
                        Text(text).font(ChatType.font(11)).foregroundStyle(colors.muted).frame(maxWidth: .infinity, alignment: .leading)
                    case .warning(let text, let action):
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(colors.yellow)
                            Text(text).foregroundStyle(colors.yellow)
                            Spacer(minLength: 6)
                            Text(action).foregroundStyle(colors.ink).underline(color: colors.ink.opacity(0.4))
                        }
                        .font(ChatType.font(11))
                    }
                }
                .lineLimit(1).padding(.horizontal, 10).frame(height: 14).padding(.top, -2)
            }
        }
    }

    /// Asked for, waiting on the agent.
    struct Spinner: View {
        var body: some View {
            Circle().trim(from: 0.1, to: 0.78).stroke(ChatColors.current.muted, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 9, height: 9).rotationEffect(.degrees(-50))
        }
    }

    // MARK: The track

    struct Level {
        var stops: [String]
        /// The choice: where the thumb rests.
        var current: Int?
        /// The pointer's stop.
        var hover: Int?
        /// A stop the thumb left and may return to: a dashed outline.
        var ghost: Int?
        /// Stops the shown model does not have: hatched.
        var unavailable: Set<Int> = []
        var focused = false
        /// Asked for, not confirmed: the thumb translucent.
        var unconfirmed = false
        var dimmed = false
        /// The thumb held, at this place in stops: a lens.
        var held: CGFloat?
        /// The thumb on its way to `current` from a stop, this far.
        var travel: (from: Int, progress: CGFloat)?
        /// The pointer, at this place in stops.
        var cursor: CGFloat?

        /// Where the thumb is, in stops.
        var place: CGFloat? {
            if let held { return held }
            guard let current else { return nil }
            guard let travel else { return CGFloat(current) }
            return CGFloat(travel.from) + CGFloat(current - travel.from) * travel.progress
        }

        /// The travelling thumb's span in stops: its head at `place`, its tail back at the stop it left.
        var stretch: ClosedRange<CGFloat>? {
            guard let travel, let place else { return nil }
            return min(place, CGFloat(travel.from))...max(place, CGFloat(travel.from))
        }

        @MainActor func label(_ index: Int) -> (color: Color, weight: Font.Weight) {
            let colors = ChatColors.current
            if unavailable.contains(index) { return (colors.muted.opacity(0.45), .regular) }
            if let held {
                if Int(held.rounded()) == index { return (colors.ink, .semibold) }
                return (CGFloat(index) < held ? colors.ink.opacity(0.78) : colors.muted, .regular)
            }
            if travel != nil, let place, abs(CGFloat(index) - place) < 0.5 { return (colors.terminal, .semibold) }
            if index == current { return (unconfirmed || travel != nil ? colors.ink : colors.terminal, .semibold) }
            if index == hover { return (colors.ink, .regular) }
            if let place, CGFloat(index) < place { return (colors.ink.opacity(0.78), .regular) }
            return (colors.muted, .regular)
        }
    }

    /// A groove of equal stops, filled up to the thumb.
    struct LevelTrack: View {
        var level: Level
        static let height: CGFloat = 32

        var body: some View {
            let colors = ChatColors.current
            let dark = Chrome.palette.isDark
            let height = Self.height
            GeometryReader { box in
                let width = box.size.width / CGFloat(level.stops.count)
                let slot = CGSize(width: width - 6, height: height - 6)
                ZStack(alignment: .leading) {
                    // The groove, recessed; its fill up to the thumb, deeper toward it.
                    Pill().fill(colors.ink.opacity(0.06).shadow(.inner(color: .black.opacity(dark ? 0.5 : 0.14), radius: 2, y: 1)))
                    if let place = level.place {
                        Pill().fill(LinearGradient(colors: [colors.ink.opacity(0.02), colors.ink.opacity(0.17)],
                                                   startPoint: .leading, endPoint: .trailing))
                            .frame(width: min(box.size.width, (place + 1) * width))
                    }
                    if !level.unavailable.isEmpty { Hatch(stops: level.stops.count, unavailable: level.unavailable) }
                    if let ghost = level.ghost {
                        PillStroke(color: colors.ink.opacity(0.45), lineWidth: 1, dash: [3, 3])
                            .frame(width: slot.width, height: slot.height).offset(x: CGFloat(ghost) * width + 3)
                    }
                    if let hover = level.hover, level.held == nil, hover != level.current, !level.unavailable.contains(hover) {
                        Pill().fill(colors.ink.opacity(0.1)).frame(width: slot.width, height: slot.height)
                            .offset(x: CGFloat(hover) * width + 3)
                    }
                    thumb(width: width, slot: slot)
                    HStack(spacing: 0) {
                        ForEach(Array(level.stops.enumerated()), id: \.offset) { index, stop in
                            let label = level.label(index)
                            Text(stop).font(ChatType.font(12, weight: label.weight)).foregroundStyle(label.color)
                                .lineLimit(1).frame(width: width, height: height)
                        }
                    }
                    if level.held != nil {
                        // The stops, while the thumb is held.
                        ForEach(level.stops.indices, id: \.self) { index in
                            Circle().fill(colors.ink.opacity(0.4)).frame(width: 2.5, height: 2.5)
                                .offset(x: (CGFloat(index) + 0.5) * width - 1.25, y: height / 2 - 4.5)
                        }
                    }
                }
                .frame(width: box.size.width, height: height, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    // Beside the label it points at; holding the thumb, under the lens's middle.
                    if let cursor = level.cursor {
                        Cursor().offset(x: (cursor + 0.5) * width + (level.held == nil ? 22 : -4), y: height / 2 + (level.held == nil ? 3 : 8))
                    }
                }
            }
            .frame(height: height)
            .overlay(PillStroke(color: colors.ink.opacity(0.08), lineWidth: 1).allowsHitTesting(false))
            .opacity(level.dimmed ? 0.6 : 1)
            .padding(3)
            .overlay { if level.focused { PillStroke(color: colors.accent.opacity(0.7), lineWidth: 1.5) } }
            .padding(-3)
        }

        /// The thumb: a raised pill; translucent while unconfirmed; on its way, a head with a fading tail; a lens while
        /// held.
        @ViewBuilder private func thumb(width: CGFloat, slot: CGSize) -> some View {
            let colors = ChatColors.current
            let dark = Chrome.palette.isDark
            if let place = level.place {
                if level.held != nil {
                    ZStack {
                        Pill().fill(Color.white.opacity(dark ? 0.2 : 0.9)).shadow(color: .black.opacity(dark ? 0.55 : 0.25), radius: 9, y: 4)
                        Pill().fill(LinearGradient(colors: [.white.opacity(dark ? 0.22 : 0.7), .white.opacity(0)], startPoint: .top, endPoint: .center))
                        PillStroke(color: .white.opacity(dark ? 0.5 : 1), lineWidth: 1)
                    }
                    .frame(width: width + 6, height: Self.height + 8).offset(x: place * width - 3)
                } else if let stretch = level.stretch, let travel = level.travel, let current = level.current {
                    let back = travel.from > current
                    let fade: [(Double, CGFloat)] = [(0.94, 0), (0.5, 0.42), (0, 1)]
                    Pill().fill(LinearGradient(stops: (back ? fade : fade.reversed()).map {
                        Gradient.Stop(color: colors.ink.opacity($0.0), location: back ? $0.1 : 1 - $0.1)
                    }, startPoint: .leading, endPoint: .trailing))
                        .frame(width: (stretch.upperBound - stretch.lowerBound + 1) * width - 6, height: slot.height)
                        .offset(x: stretch.lowerBound * width + 3)
                } else if level.unconfirmed {
                    Pill().fill(colors.ink.opacity(0.17)).overlay(PillStroke(color: colors.ink.opacity(0.6), lineWidth: 1))
                        .frame(width: slot.width, height: slot.height).offset(x: place * width + 3)
                } else {
                    Pill().fill(LinearGradient(colors: [colors.ink.opacity(0.99), colors.ink.opacity(0.84)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: .black.opacity(dark ? 0.5 : 0.3), radius: 2.5, y: 1)
                        .frame(width: slot.width, height: slot.height).offset(x: place * width + 3)
                }
            }
        }
    }

    /// Stops the model lacks: the groove hatched over them.
    struct Hatch: View {
        var stops: Int
        var unavailable: Set<Int>
        var body: some View {
            let color = ChatColors.current.ink.opacity(0.1)
            Canvas { context, size in
                context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
                let width = size.width / CGFloat(stops)
                for index in unavailable {
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
            }
        }
    }

    /// The pointer, for frames with a hand in them.
    struct Cursor: View {
        var body: some View {
            let arrow = Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 16.5))
                path.addLine(to: CGPoint(x: 3.9, y: 12.9))
                path.addLine(to: CGPoint(x: 6.6, y: 19))
                path.addLine(to: CGPoint(x: 9.1, y: 17.9))
                path.addLine(to: CGPoint(x: 6.4, y: 11.9))
                path.addLine(to: CGPoint(x: 11.5, y: 11.9))
                path.closeSubpath()
            }
            arrow.fill(.black).overlay(arrow.stroke(.white, style: StrokeStyle(lineWidth: 1.1, lineJoin: .round)))
                .frame(width: 12, height: 19).shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
        }
    }

    // MARK: Today, and the footer

    /// ChatModelPickerView as it ships: MODEL and EFFORT lists, the current row checked, stronger efforts first.
    struct Today: View {
        var body: some View {
            let colors = ChatColors.current
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    column("MODEL", rows: [("fable-5.2", "default", true), ("opus-5.5", "", false), ("sonnet-5.5", "", false),
                                           ("haiku-5.5", "", false), ("mythos-5.2", "", false)], highlight: 0)
                    Rectangle().fill(colors.border).frame(width: 1)
                    column("EFFORT", rows: [("max", "", false), ("xhigh", "", false), ("high", "", true), ("medium", "", false),
                                            ("low", "", false)], highlight: nil)
                }
                .frame(height: 5 * 31 + 30)
                Rectangle().fill(colors.border).frame(height: 1)
                HStack {
                    Spacer()
                    Button("Done") {}.controlSize(.small)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .padding(6).frame(width: 470)
            .font(ChatType.detail).foregroundStyle(colors.ink)
            .background(PopoverCard())
        }

        private func column(_ title: String, rows: [(String, String, Bool)], highlight: Int?) -> some View {
            let colors = ChatColors.current
            return VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(colors.muted).padding(.horizontal, 8).padding(.vertical, 6)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 6) {
                        Text(row.0)
                        Spacer(minLength: 0)
                        if !row.1.isEmpty { Text(row.1).foregroundStyle(colors.muted) }
                        Image(systemName: "checkmark").opacity(row.2 ? 1 : 0).frame(width: 10)
                    }
                    .padding(.horizontal, 8).frame(minHeight: 30)
                    .background(index == highlight ? colors.ink.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The composer footer's model and effort (ChatModelControls): the ID underlined, then the effort in words or,
    /// folded, as its meter; the shield before the ID while the security model is on.
    struct FooterChip: View {
        var model: String
        var effort: String
        var folded = false
        var shield = false
        var body: some View {
            let colors = ChatColors.current
            HStack(spacing: 7) {
                if shield {
                    Image(systemName: "shield.lefthalf.filled").font(.system(size: 11, weight: .medium)).foregroundStyle(ModelLadder.shield)
                        .padding(.trailing, -2)
                }
                Text(model)
                    .overlay(alignment: .bottom) { Rectangle().fill(colors.muted.opacity(0.4)).frame(height: 1).offset(y: 2) }
                if !folded { Text("·") }
                if folded { Meter(effort: effort) } else { Text(effort) }
            }
            .font(ChatType.detail).foregroundStyle(colors.muted.opacity(0.65))
            .padding(.horizontal, 12).frame(height: 38)
            .background(GlassTone.track, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(GlassTone.trackEdge, lineWidth: 1))
        }
    }

    /// ChatEffortMeter, as the kit's composer draws it.
    struct Meter: View {
        let effort: String
        var body: some View {
            let colors = ChatColors.current
            let filled = ["low": 0, "medium": 1, "high": 2, "xhigh": 3, "max": 3, "ultra": 4][effort] ?? 0
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < filled ? (index == 3 ? colors.accent : colors.ink.opacity(0.8)) : .clear)
                        .overlay {
                            if index < 3 && index >= filled { RoundedRectangle(cornerRadius: 1).strokeBorder(colors.muted.opacity(0.5), lineWidth: 1) }
                        }
                        .frame(width: 3, height: CGFloat(min(10, 4 + index * 3)))
                }
            }
            .frame(width: 18, height: 10, alignment: .bottomLeading)
        }
    }
}

/// A capsule as a path, for fills.
private nonisolated struct Pill: Shape {
    func path(in rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: rect.height / 2) }
}

/// A capsule's outline, drawn in a canvas 2 points larger than it: offscreen, a stroked shape's curve is cut flat where
/// it meets its layer's edge (a nub at each end of a capsule).
private struct PillStroke: View {
    var color: Color
    var lineWidth: CGFloat = 1
    var dash: [CGFloat] = []
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2 + lineWidth / 2, dy: 2 + lineWidth / 2)
            context.stroke(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth, dash: dash))
        }
        .padding(-2)
    }
}
