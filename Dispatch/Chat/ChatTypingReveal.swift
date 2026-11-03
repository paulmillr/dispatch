import Foundation
import QuartzCore
import Observation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// The typed reveal of streamed assistant text (docs/architecture.md, "Typed reveal"): Codex and Pi send a reply a few
// words at a time, and each delta used to land at once. A live message instead types out steadily a little behind
// what has arrived, with a caret. Presentation only: the model, persistence and the helper never see it, and while
// testing (or with Reduce Motion) every message shows at once.

/// A streamed message as its reveal counts it: the arrived source cut where a half-arrived construct would show raw
/// syntax (`stableEnd`), its Markdown blocks (`ChatMarkdownBlock`, as both apps draw them) and the units each reveals
/// in order (a text block's rendered characters, a code block's lines, a table's rows, a rule whole), and what typing
/// each unit costs.
struct ChatTypingLayout: Equatable {
    struct Block: Equatable {
        let kind: ChatMarkdownBlock.Kind
        /// Where the block's units start in the message's.
        let start: Int
        let units: Int
        /// A text block's rendered characters (its inline Markdown resolved); empty for code, tables and rules.
        let plain: [Character]
        var end: Int { start + units }
        var isText: Bool {
            switch kind {
            case .paragraph, .heading, .list, .quote: true
            case .code, .rule, .table: false
            }
        }
    }

    /// The part of the arrived text that can show: a prefix of it, all of it once the stream ended.
    let source: String
    let blocks: [Block]
    /// What each unit costs to type, in characters: 1, more after punctuation and at a block's start (`cost`).
    let costs: [Double]
    /// The rendered text was cut for safety (`TextRendering.rich`): such a message shows at once.
    let truncated: Bool
    var total: Int { costs.count }

    /// Pauses, in characters typed: after `,;:` and `.!?` (before the space that follows) and at a new block.
    static let commaPause = 2.5, sentencePause = 5.0, blockPause = 7.0
    /// Each cost varies by this much either way, the same for the same position every time.
    static let jitter = 0.25

    @MainActor init(_ arrived: String, ended: Bool) {
        source = ended ? arrived : String(arrived[..<Self.stableEnd(arrived)])
        let rendered = TextRendering.rich(source)
        truncated = rendered.truncated
        var blocks: [Block] = []
        var costs: [Double] = []
        for (index, block) in ChatMarkdownBlock.parse(rendered.text).enumerated() {
            let start = costs.count
            var plain: [Character] = []
            func add(_ cost: Double) {
                let paused = costs.count == start && index > 0 ? cost + Self.blockPause : cost
                costs.append(Self.jittered(paused, at: costs.count))
            }
            switch block.kind {
            case .paragraph, .heading, .list, .quote:
                plain = Array(Self.plain(block.text))
                for (offset, character) in plain.enumerated() {
                    var cost = 1.0
                    if offset > 0, character.isWhitespace {
                        let previous = plain[offset - 1]
                        if ".!?".contains(previous) { cost += Self.sentencePause }
                        else if ",;:".contains(previous) { cost += Self.commaPause }
                    }
                    add(cost)
                }
            case .code:
                // By line: a long line costs more, but far less than typing it.
                for line in Self.lines(block.text) { add(1 + Double(min(line.count, 80)) / 8) }
            case .table(let rows):
                for _ in rows { add(3) }
            case .rule:
                add(1)
            }
            blocks.append(Block(kind: block.kind, start: start, units: costs.count - start, plain: plain))
        }
        self.blocks = blocks
        self.costs = costs
    }

    /// A code block's lines as units: none for an empty block.
    static func lines(_ code: String) -> [Substring] { code.isEmpty ? [] : code.split(separator: "\n", omittingEmptySubsequences: false) }

    /// How many units of block `index` show when the message shows `shown`: nil while none.
    func shown(block index: Int, of shown: Int) -> Int? {
        let block = blocks[index]
        guard block.start < shown else { return nil }
        return min(block.units, shown - block.start)
    }

    /// The blocks that show any of the first `shown` units.
    func visibleBlocks(_ shown: Int) -> Int { blocks.firstIndex { $0.start >= shown } ?? blocks.count }

    /// The block whose unit `shown - 1` is the last one showing: where the caret goes.
    func caretBlock(_ shown: Int) -> Int? {
        guard shown > 0 else { return nil }
        return blocks.lastIndex { $0.start < shown && $0.units > 0 }
    }

    /// How many characters after the first `shown` of text block `index` finish the word being typed (a path or URL
    /// too, up to `wordReach`): laid out but not drawn, so a half-typed word wraps where the whole one will and never
    /// jumps lines.
    func hiddenTail(block index: Int, shown: Int) -> Int {
        let plain = blocks[index].plain
        guard shown < plain.count else { return 0 }
        var end = shown
        while end < plain.count, end - shown < Self.wordReach, !plain[end].isWhitespace { end += 1 }
        return end - shown
    }
    static let wordReach = 200

    /// How block `index` draws at `frame`: nil when it shows whole (or not at all: see `visibleBlocks`).
    func cut(block index: Int, frame: ChatTypingFrame) -> ChatTypingCut? {
        guard index < blocks.count, let shown = shown(block: index, of: frame.shown) else { return nil }
        let block = blocks[index]
        let caret = frame.caret > 0 && caretBlock(frame.shown) == index && block.isText
        guard shown < block.units || caret else { return nil }
        return ChatTypingCut(shown: shown, hidden: block.isText ? hiddenTail(block: index, shown: shown) : 0,
                             caret: caret ? frame.caret : nil)
    }

    /// A text block's rendered value cut after its first `shown` characters, and the `hidden` characters after them.
    static func split(_ value: AttributedString, shown: Int, hidden: Int) -> (shown: AttributedString, tail: AttributedString) {
        let characters = value.characters
        let count = characters.count
        let cut = characters.index(characters.startIndex, offsetBy: min(max(0, shown), count))
        let end = characters.index(cut, offsetBy: min(max(0, hidden), count - min(max(0, shown), count)))
        return (AttributedString(value[value.startIndex..<cut]), AttributedString(value[cut..<end]))
    }

    /// Characters laid out but not drawn: clear, without a background, link or underline that would still draw.
    static func hidden(_ tail: AttributedString) -> AttributedString {
        var tail = tail
        tail.foregroundColor = .clear
        tail.backgroundColor = nil
        tail.link = nil
        tail.underlineStyle = nil
        tail.strikethroughStyle = nil
        return tail
    }

    // MARK: Costs

    private static func jittered(_ cost: Double, at position: Int) -> Double {
        // SplitMix64 of the position: deterministic, so a frame drawn again is the same frame.
        var z = UInt64(position) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        let unit = Double(z >> 11) / Double(1 << 53)
        return cost * (1 - jitter + 2 * jitter * unit)
    }

    /// A text block's characters as drawn: the inline Markdown both apps render (`ChatMarkdown.safeInlineMarkdown`,
    /// `MobileChatMarkdown.text`) with its syntax gone. Kept by text, like the apps' own caches.
    @MainActor static func plain(_ inline: String) -> String {
        if let cached = plainCache[inline] { return cached }
        let visible = TextRendering.visible(inline)
        let value = (try? AttributedString(markdown: visible, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(visible)
        let plain = String(value.characters)
        if inline.utf8.count <= 8 * 1024 {
            if plainCache.count >= 1024 { plainCache.removeAll(keepingCapacity: true) }
            plainCache[inline] = plain
        }
        return plain
    }
    @MainActor private static var plainCache: [String: String] = [:]

    // MARK: What can show

    /// Where the arrived text stops being safe to show while it still streams: before a trailing line that could still
    /// become a block marker (`-`, `1.`, `##`, `>`, a fence, a table row), before the incomplete last line of an open
    /// code fence (code reveals by line), before lines that may be a table's header until its divider has come, and
    /// before an inline construct the last text block opened and has not closed (`` ` ``, `*`, `_`, `~`, `[`, a
    /// trailing `\`). What shows is then the same text, drawn the same way, as once the whole message has arrived.
    static func stableEnd(_ text: String) -> String.Index {
        var starts = [text.startIndex]
        var cursor = text.startIndex
        while let newline = text[cursor...].firstIndex(of: "\n") {
            cursor = text.index(after: newline)
            starts.append(cursor)
        }
        let trailingStart = starts[starts.count - 1]
        // Complete lines, without their newline.
        let complete: [Substring] = (0..<(starts.count - 1)).map { text[starts[$0]..<text.index(before: starts[$0 + 1])] }
        // Open fence after the complete lines (the parser's rule: three or more of a marker open, as many alone close).
        var fence: (marker: Character, length: Int)?
        for line in complete {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.prefix(while: { $0 == open.marker }).count >= open.length && trimmed.allSatisfy({ $0 == open.marker }) { fence = nil }
            } else if let marker = trimmed.first, marker == "`" || marker == "~", trimmed.prefix(while: { $0 == marker }).count >= 3 {
                fence = (marker, trimmed.prefix(while: { $0 == marker }).count)
            }
        }
        if fence != nil { return trailingStart }
        let trailing = text[trailingStart...]
        var end = ambiguous(trailing) ? trailingStart : text.endIndex
        // Lines a divider may still turn into a table's header: held while the line after them could be that divider.
        if end == trailingStart, trailing.trimmingCharacters(in: .whitespaces).allSatisfy({ "|:- ".contains($0) }) {
            var first = complete.count
            while first > 0, complete[first - 1].contains("|"), !complete[first - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                first -= 1
            }
            // A header and its divider among them: the table has begun, and its complete rows show.
            let established = first < complete.count - 1
                && (first..<(complete.count - 1)).contains { ChatMarkdownBlock.isTableDivider(String(complete[$0 + 1])) }
            if first < complete.count && !established { end = starts[first] }
        }
        // The last text block's open inline construct.
        guard end > text.startIndex else { return end }
        let lastShown = text.index(before: end)
        guard let lastLine = starts.lastIndex(where: { $0 <= lastShown }) else { return end }
        let completeLine = end != text.endIndex || text[lastShown] == "\n"
        func line(_ index: Int) -> Substring {
            index < complete.count ? complete[index] : trailing
        }
        let kind = lineKind(line(lastLine))
        if kind == .blank || (completeLine && kind != .plain) { return end }
        var blockStart = lastLine
        if kind == .plain {
            while blockStart > 0, lineKind(line(blockStart - 1)) == .plain { blockStart -= 1 }
        }
        let scanned = text[starts[blockStart]..<end]
        guard let open = openConstruct(scanned), open < end else { return end }
        // Cut there, unless that leaves the line a bare marker (`- `, `1. `): then before the line.
        let lineStart = starts.last { $0 <= open } ?? text.startIndex
        return ambiguous(text[lineStart..<open]) && lineStart < open ? lineStart : open
    }

    /// A trailing line that may still become a block marker, or is one with nothing after it yet (the parser reads
    /// `- ` alone as text): nothing yet, `-`, `**`, `___`, `12.`, `##`, `>`, one or two backticks or tildes, a fence's
    /// opening line, or a table row.
    private static func ambiguous(_ line: Substring) -> Bool {
        let trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
        guard let first = trimmed.first else { return true }
        if first == "|" { return true }
        if first == "`" || first == "~" {
            let run = trimmed.prefix { $0 == first }.count
            return run >= 3 || run == trimmed.count
        }
        if trimmed.count <= 3, trimmed.allSatisfy({ $0 == first }), "-*+_".contains(first) { return true }
        if trimmed.allSatisfy({ $0 == "#" }), trimmed.count <= 6 { return true }
        if trimmed == ">" { return true }
        // A list item whose content may still become a task's box (`- [`, `- [ ]`, `- [x]`): the parser draws `☐`
        // only once the space after the box has come.
        if let marker = trimmed.range(of: #"^(?:[-*+]|[0-9]+[.)]) "#, options: .regularExpression) {
            let content = trimmed[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            if !content.isEmpty, ["[ ]", "[x]", "[X]"].contains(where: { $0.hasPrefix(content) }) { return true }
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = trimmed.dropFirst(digits.count)
            return rest.isEmpty || rest == "." || rest == ")"
        }
        return false
    }

    private enum LineKind { case blank, plain, marker }
    /// A line that starts a one-line block (heading, quote, list item, rule, fence) is a marker; a paragraph's is plain.
    private static func lineKind(_ line: Substring) -> LineKind {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return .blank }
        if (first == "`" || first == "~") && trimmed.prefix(while: { $0 == first }).count >= 3 { return .marker }
        if trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 3 || trimmed == "***" || trimmed == "___" { return .marker }
        if first == "#", (1...6).contains(trimmed.prefix(while: { $0 == "#" }).count), trimmed.drop(while: { $0 == "#" }).first == " " { return .marker }
        if trimmed.hasPrefix("> ") || trimmed == ">" { return .marker }
        if trimmed.range(of: #"^(?:[-*+] |[0-9]+[.)] )"#, options: .regularExpression) != nil { return .marker }
        return .plain
    }

    /// Where `text` opens an inline construct it has not closed yet: a code span without its closing run, emphasis or
    /// strikethrough that could still open (a left-flanking `*`, `_` not inside a word, `~`) without a closer after
    /// it, a link's `[` before its `](…)` (parentheses in the URL balanced), an autolink's `<` before its `>`, a
    /// trailing backslash (or one before the last line break: a hard break). Nil when everything opened has closed. An opener more
    /// than `openReach` characters before the end is taken as text (`~/path`, a lone `[`): spans close sooner, and
    /// holding it would stop the paragraph typing until its end.
    static let openReach = 200

    /// The `)` closing a link destination that starts at `start`: parentheses inside it nest (`a_(b)`).
    private static func closingParenthesis(_ characters: [Character], from start: Int) -> Int? {
        var depth = 0, j = start
        while j < characters.count {
            switch characters[j] {
            case "\\": j += 1
            case "(": depth += 1
            case ")":
                if depth == 0 { return j }
                depth -= 1
            default: break
            }
            j += 1
        }
        return nil
    }
    private static func openConstruct(_ text: Substring) -> String.Index? {
        let characters = Array(text)
        var indices: [String.Index] = []
        indices.reserveCapacity(characters.count)
        var cursor = text.startIndex
        for _ in characters { indices.append(cursor); cursor = text.index(after: cursor) }
        func run(at i: Int) -> Int {
            var j = i
            while j < characters.count && characters[j] == characters[i] { j += 1 }
            return j - i
        }
        func near(_ i: Int) -> Bool { characters.count - i <= openReach }
        var i = 0
        while i < characters.count {
            let c = characters[i]
            switch c {
            case "\\":
                // A trailing backslash may escape what comes next; before the text's last line break it is a hard
                // break that only shows as one once the next line has come.
                if i + 1 >= characters.count || (characters[i + 1] == "\n" && i + 2 >= characters.count) { return indices[i] }
                i += 2
            case "<":
                // An autolink (`<https://…>`) shows its brackets until it closes.
                guard i + 1 >= characters.count || characters[i + 1].isLetter else { i += 1; continue }
                if let close = characters[(i + 1)...].firstIndex(of: ">") { i = close + 1 }
                else if near(i) { return indices[i] } else { i += 1 }
            case "`":
                let length = run(at: i)
                var j = i + length, closed: Int?
                while j < characters.count {
                    if characters[j] == "`" {
                        let other = run(at: j)
                        // A closing run that ends the text may still grow (and then not close).
                        if other == length { closed = j + other < characters.count ? j + other : nil; break }
                        j += other
                    } else { j += 1 }
                }
                if let closed { i = closed } else if near(i) { return indices[i] } else { i += length }
            case "[":
                // A link's text, then `](`, then `)`; text in brackets alone may still be followed by `(`.
                if let close = characters[(i + 1)...].firstIndex(of: "]"), close + 1 < characters.count {
                    if characters[close + 1] != "(" { i = close + 1 }
                    else if let paren = Self.closingParenthesis(characters, from: close + 2) { i = paren + 1 }
                    else if near(i) { return indices[i] } else { i += 1 }
                } else if near(i) { return indices[i] } else { i += 1 }
            case "*", "_", "~":
                let length = run(at: i)
                let next = i + length < characters.count ? characters[i + length] : nil
                let previous = i > 0 ? characters[i - 1] : nil
                guard let next else { return indices[i] }
                let opens = !next.isWhitespace && !(c == "_" && previous.map { $0.isLetter || $0.isNumber } == true)
                var after = i + length
                if opens {
                    // A closer: a later run of the same marker right after a non-space, as long as the opener and not
                    // still growing at the text's end. Scanning goes on after it.
                    var j = i + length, closer: Int?
                    while j < characters.count {
                        if characters[j] == c {
                            let other = run(at: j)
                            if !characters[j - 1].isWhitespace && other >= length && j + other < characters.count {
                                closer = j + other; break
                            }
                            j += other
                        } else { j += 1 }
                    }
                    if let closer { after = closer } else if near(i) { return indices[i] }
                }
                i = after
            default:
                i += 1
            }
        }
        return nil
    }
}

/// A message's reveal clock, pure and driven by the times it is given: where the reveal is (in units, fractional while
/// a unit types), how fast it goes, and what the caret shows. The rate aims to keep the reveal `lag` behind what has
/// arrived (backlog cost / lag), never under `minimumRate` while text waits, eased toward that target with time
/// constant `smoothing` so the speed never jumps; once the stream ended it aims at `lag × endingLag`. A unit shows as
/// soon as it starts typing, at full strength.
struct ChatTypingClock: Equatable {
    static let lag = 0.3
    static let minimumRate = 28.0
    static let smoothing = 0.16
    static let endingLag = 0.7
    /// The caret: solid while typing, blinking at `blinkRate` while caught up and the stream is quiet (steady after
    /// `blinkLimit` of quiet: a stalled stream draws nothing new), fading over `fade` once the message is complete.
    static let blinkRate = 1.1
    static let blinkLimit = 6.0
    static let fade = 0.3

    private(set) var position: Double
    private(set) var rate = 0.0
    private(set) var time: TimeInterval
    private(set) var ended = false
    /// When the reveal last caught up with what had arrived; nil while behind.
    private(set) var caughtUp: TimeInterval?
    /// When it caught up with the whole message (the stream had ended).
    private(set) var finished: TimeInterval?

    /// A clock at `position` units at `time`. One that starts behind starts at the typist's speed, not from rest.
    init(position: Double, at time: TimeInterval) {
        self.position = position
        self.time = time
        rate = Self.minimumRate
    }

    /// The message changed at `now` (more arrived, or its stream ended or went on): the clock takes it up from where
    /// it shows without typing the time it rested, so a reveal that had caught up, faded or stopped blinking types
    /// again. A message that has more to show types (from at least the typist's speed); one that is live again is no
    /// longer finished.
    mutating func resume(at now: TimeInterval, available: Int, ended: Bool) {
        time = max(time, now)
        self.ended = ended
        if position < Double(available) {
            caughtUp = nil
            finished = nil
            rate = max(rate, Self.minimumRate)
        } else if !ended {
            // Caught up and live: the caret blinks again, from a blink just begun.
            if finished != nil || caughtUp.map({ now - $0 >= Self.blinkLimit }) ?? true { caughtUp = now }
            finished = nil
        } else if finished == nil {
            finished = now
        }
    }

    /// The units showing: a unit shows once it starts typing.
    var shown: Int { Int(position.rounded(.up)) }

    /// Moves the clock to `now` with `costs` being every unit that has arrived; `ended` once the stream will add nothing.
    mutating func advance(to now: TimeInterval, costs: [Double], ended: Bool) {
        let dt = max(0, now - time)
        time = max(time, now)
        let available = Double(costs.count)
        if position > available { position = available }
        self.ended = ended
        var backlog = 0.0
        var unit = Int(position)
        if unit < costs.count {
            backlog += costs[unit] * (1 - (position - Double(unit)))
            unit += 1
        }
        while unit < costs.count { backlog += costs[unit]; unit += 1 }
        let target = backlog > 0 ? max(Self.minimumRate, backlog / (self.ended ? Self.lag * Self.endingLag : Self.lag)) : 0
        rate += (target - rate) * (1 - exp(-dt / Self.smoothing))
        var budget = rate * dt
        while budget > 0 && position < available {
            let index = Int(position)
            let left = (Double(index + 1) - position) * costs[index]
            if budget >= left { position = Double(index + 1); budget -= left }
            else { position += budget / costs[index]; budget = 0 }
        }
        if position >= available {
            if caughtUp == nil { caughtUp = now }
            // Complete from the moment the stream ended with everything showing: the caret fades from then.
            if self.ended, finished == nil { finished = now }
        } else { caughtUp = nil; finished = nil }
    }

    /// The caret's opacity at `now`: 1 while typing, 0.9 and 0.15 in turn while caught up with a quiet stream, fading to
    /// 0 once the whole message shows.
    func caret(at now: TimeInterval) -> Double {
        if let finished { return max(0, 1 - (now - finished) / Self.fade) }
        guard let caughtUp else { return 1 }
        let quiet = now - caughtUp
        if quiet >= Self.blinkLimit { return 0.9 }
        return cos(2 * .pi * Self.blinkRate * quiet) > -0.2 ? 0.9 : 0.15
    }

    /// What the clock still needs: every frame while typing or fading, blink steps while blinking, nothing after.
    enum Needs: Equatable { case frames, blink, nothing }
    func needs(at now: TimeInterval) -> Needs {
        if let finished { return now - finished < Self.fade ? .frames : .nothing }
        guard let caughtUp else { return .frames }
        return now - caughtUp < Self.blinkLimit ? .blink : .nothing
    }

    /// Done: the whole message shows and the caret has faded.
    func done(at now: TimeInterval) -> Bool { needs(at: now) == .nothing && finished != nil }
}

/// A typing reply with nothing to show yet (its first words are all a construct still arriving, `**Summary`): one
/// line of the text's height holding the caret alone, so its bubble is never drawn empty.
struct ChatTypingCaretLine: View {
    let caret: Double
    let color: Color
    var body: some View {
        Text(" ")
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle().fill(color.opacity(caret)).frame(width: 2).padding(.vertical, 2)
            }
            .accessibilityHidden(true)
    }
}

/// Where a typing message's block is cut (`ChatTypingLayout.cut`): its first `shown` units drawn; for a text block,
/// `hidden` more characters laid out but not drawn so the word being typed wraps as it will, and the caret's opacity
/// when the caret is after its shown characters.
struct ChatTypingCut: Equatable {
    let shown: Int
    let hidden: Int
    let caret: Double?
}

/// What a live message draws now: the units showing and the caret's opacity (0: none).
struct ChatTypingFrame: Equatable {
    var shown: Int
    var caret: Double
}

/// One live message's reveal: its layout, clock and what it draws. Views read `frame` (observed: they draw again as it
/// types) and draw `layout` cut at it; the store's display link advances it.
@MainActor @Observable
final class ChatTypingReveal {
    let id: String
    /// What it draws; changes as units show and the caret steps, never for a frame that draws the same.
    private(set) var frame: ChatTypingFrame
    @ObservationIgnored private(set) var layout: ChatTypingLayout
    @ObservationIgnored private(set) var clock: ChatTypingClock
    @ObservationIgnored private(set) var text: String
    @ObservationIgnored private var ended: Bool
    /// Views showing it: the clock runs only while one does. One that showed it and left (a row scrolled away, a tab
    /// switched) shows what has arrived when it comes back, then types from there.
    @ObservationIgnored private var mounts = 0
    @ObservationIgnored private(set) var left = false

    init(id: String, text: String, ended: Bool, fromStart: Bool, at now: TimeInterval) {
        self.id = id
        self.text = text
        self.ended = ended
        let layout = ChatTypingLayout(text, ended: ended)
        self.layout = layout
        // From the start: the first character shows with the row. Otherwise what has arrived shows, caught up.
        var clock = ChatTypingClock(position: fromStart ? min(Double(layout.total), 1e-6) : Double(layout.total), at: now)
        clock.advance(to: now, costs: layout.costs, ended: ended)
        self.clock = clock
        frame = ChatTypingFrame(shown: clock.shown, caret: (clock.caret(at: now) * 20).rounded() / 20)
    }

    /// The units showing and the caret as of the last step, within the current layout.
    var current: ChatTypingFrame { ChatTypingFrame(shown: min(clock.shown, layout.total), caret: frame.caret) }

    /// The message as it is now. A reveal that rested (caught up, faded, past its blink) takes up what is new from
    /// where it shows: the caller schedules the clock again.
    func feed(_ text: String, ended: Bool, at now: TimeInterval) {
        if left { snap(text, ended: ended, at: now); return }
        guard text != self.text || ended != self.ended else { return }
        self.text = text
        self.ended = ended
        layout = ChatTypingLayout(text, ended: ended)
        clock.resume(at: now, available: layout.total, ended: ended)
    }

    /// Shows what has arrived at once (a reveal shown again after it left), caught up: it types what comes next.
    private func snap(_ text: String, ended: Bool, at now: TimeInterval) {
        left = false
        self.text = text
        self.ended = ended
        layout = ChatTypingLayout(text, ended: ended)
        clock = ChatTypingClock(position: Double(layout.total), at: now)
        clock.advance(to: now, costs: layout.costs, ended: ended)
    }

    func step(to now: TimeInterval) {
        clock.advance(to: now, costs: layout.costs, ended: ended)
        let caret = (clock.caret(at: now) * 20).rounded() / 20
        let next = ChatTypingFrame(shown: clock.shown, caret: caret)
        if next != frame { frame = next }
    }

    /// Shown in a view now.
    var mounted: Bool { mounts > 0 && !left }
    func needs(at now: TimeInterval) -> ChatTypingClock.Needs { mounted ? clock.needs(at: now) : .nothing }
    func done(at now: TimeInterval) -> Bool { clock.done(at: now) }

    func appeared() { mounts += 1; left = false }
    func disappeared() {
        mounts = max(0, mounts - 1)
        if mounts == 0 { left = true }
    }
}

/// A conversation's live reveals, kept beside its view state (never in the model or persisted). A row asks for its
/// message's reveal as it draws (`reveal`): a message that is complete, not in the live turn, or first seen with its
/// text already there shows at once; one that arrived while the chat was shown (`began`, just now) types from its
/// start. One display link advances them all, and runs only while one is typing, blinking or fading.
@MainActor final class ChatTypingReveals {
    /// Off while testing: recorded tests wait on text and replay with no display time, so every message shows at once
    /// (`DISPATCH_TESTING`, or an XCTest host on the iPhone). A test of the reveal turns it on.
    static var enabled = !System.testing && System.environment("XCTestConfigurationFilePath") == nil
        && System.environment("XCTestSessionIdentifier") == nil
    /// The agents whose replies stream in deltas (Codex's `item/agentMessage/delta`, Pi's `text_delta`). Claude Code
    /// posts whole messages: they show as they come.
    static let streamingAgents: Set<String> = ["codex", "pi"]
    /// How long after its arrival a new message first drawn still types from its start; later it shows at once.
    static let arrivalWindow: TimeInterval = 2

    private var arrivals: [String: TimeInterval] = [:]
    private var reveals: [String: ChatTypingReveal] = [:]
    private var link: ChatTypingLink?
    /// A clock of the test's own (stepped with `step(to:)`; the display link then steps to it too); nil: the display's
    /// (`CACurrentMediaTime`, the link's frame times).
    var now: (() -> TimeInterval)?
    private var time: TimeInterval { now?() ?? CACurrentMediaTime() }
    /// Whether the store runs its own display link; tests step it.
    var drivesItself = true

    init() {}

    /// A message of a streaming agent arrived live while its chat shows: drawn soon, it types from its start.
    func began(_ rowID: String) {
        guard Self.enabled, reveals[rowID] == nil, arrivals[rowID] == nil else { return }
        let now = time
        arrivals = arrivals.filter { now - $0.value < Self.arrivalWindow }
        arrivals[rowID] = now
    }

    /// The reveal row `rowID` draws `text` through; nil draws it at once. `live`: the message belongs to the live turn;
    /// `ended`: nothing more will stream into it.
    func reveal(_ rowID: String, text: String, live: Bool, ended: Bool, reduceMotion: Bool) -> ChatTypingReveal? {
        guard Self.enabled, !reduceMotion else { reveals[rowID] = nil; return nil }
        let now = time
        if let reveal = reveals[rowID] {
            reveal.feed(text, ended: ended || !live, at: now)
            if reveal.done(at: now) && (ended || !live) { reveals[rowID] = nil; return nil }
            schedule()
            return reveal
        }
        guard live, !ended else { return nil }
        let arrived = arrivals.removeValue(forKey: rowID).map { now - $0 < Self.arrivalWindow } ?? false
        let reveal = ChatTypingReveal(id: rowID, text: text, ended: false, fromStart: arrived, at: now)
        guard !reveal.layout.truncated else { return nil }
        reveals[rowID] = reveal
        schedule()
        return reveal
    }

    func appeared(_ reveal: ChatTypingReveal) { reveal.appeared(); schedule() }
    func disappeared(_ reveal: ChatTypingReveal) { reveal.disappeared() }

    /// Advances every reveal to `time`; stops the display link once none needs it.
    func step(to time: TimeInterval) {
        var needs = ChatTypingClock.Needs.nothing
        for reveal in reveals.values where reveal.mounted {
            // Each shown reveal steps, so the one that just finished draws its last frame (no caret) too.
            reveal.step(to: time)
            switch reveal.needs(at: time) {
            case .frames: needs = .frames
            case .blink where needs == .nothing: needs = .blink
            default: break
            }
        }
        if needs == .nothing { link?.stop(); link = nil } else { link?.pace(needs) }
    }

    /// Whether the display link runs (tests).
    var running: Bool { link != nil }

    func reset() {
        link?.stop(); link = nil
        reveals.removeAll(); arrivals.removeAll()
    }

    /// A session closed while a reply typed (its tab closed) takes its display link with it.
    isolated deinit { link?.stop() }

    private func schedule() {
        guard drivesItself, link == nil else { return }
        let now = time
        guard reveals.values.contains(where: { $0.needs(at: now) != .nothing }) else { return }
        // A link outliving its store (released before its next frame) stops itself.
        link = ChatTypingLink { [weak self] time in
            guard let self else { return false }
            self.step(to: self.now?() ?? time)
            return true
        }
    }
}

/// The display link that steps the reveals: every frame while one types or fades, about ten a second while one only
/// blinks. It follows the main screen's refresh. A Mac without a screen to sync to steps on a timer at the same paces.
@MainActor final class ChatTypingLink: NSObject {
    /// Steps to the given time; false once there is nothing left to step (its store is gone): the link stops.
    private let action: (TimeInterval) -> Bool
    private var link: CADisplayLink?
    private var timer: Timer?
    private var paced: ChatTypingClock.Needs = .frames
    /// Links running now, for tests.
    private(set) static var running = 0

    init(_ action: @escaping (TimeInterval) -> Bool) {
        self.action = action
        super.init()
        Self.running += 1
        #if canImport(AppKit)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { startTimer(); return }
        let link = screen.displayLink(target: self, selector: #selector(fire(_:)))
        #else
        let link = CADisplayLink(target: self, selector: #selector(fire(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: paced == .blink ? 0.1 : 1.0 / 60, target: self, selector: #selector(tick(_:)),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func fire(_ link: CADisplayLink) { if !action(link.targetTimestamp) { stop() } }
    @objc private func tick(_ timer: Timer) { if !action(CACurrentMediaTime()) { stop() } }

    func pace(_ needs: ChatTypingClock.Needs) {
        guard needs != paced, link != nil || timer != nil else { return }
        paced = needs
        if let link {
            link.preferredFrameRateRange = needs == .blink ? CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10) : .default
        } else { startTimer() }
    }

    func stop() {
        guard link != nil || timer != nil else { return }
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
        Self.running -= 1
    }
}
