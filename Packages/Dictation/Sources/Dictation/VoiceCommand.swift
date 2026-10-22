import Foundation

/// A spoken navigation command: "Dispatch" (or "Captain") first, then where to go. The app resolves names against its spaces and
/// tabs (`VoiceMatch`); this only reads the words.
///
///     Dispatch, back                       return to the previous place
///     Dispatch, next space / previous tab  step, like ⇧⌘] and ⌘[
///     Dispatch, space 3 / third space / last space / space billing / billing space
///     Dispatch, tab 2 / second tab / last tab / tab claude / the vim tab
///     Dispatch, billing tab 2 / tab 2 in billing / claude in billing
///     Dispatch, billing                    a tab of the current space by that name, else a space
///     Dispatch, open / close / toggle sidebar   also show / hide; "side bar" too
///
/// and in a chat, mostly while it listens continuously (conversation mode):
///
///     Dispatch, send / steer               ↩ / ⌥↩
///     Dispatch, new line / scratch that / clear
///     Dispatch, stop                       interrupt the agent's turn
///     Dispatch, deny / option 2            the agent's permission request / question
///     Dispatch, listen / stop listening    conversation mode on / off
///     Dispatch, read that / quiet          read the last reply again / stop reading
///
/// "go to", "switch to", "open", "show", "jump to", "take me to", "the", "number" and "please" are filler. Numbers
/// are digits, words or ordinals.
public enum VoiceCommand: Equatable, Sendable {
    case back
    /// Next (1) or previous (-1).
    case step(Kind, Int)
    /// A space, a tab (of that space, else the current one), or both.
    case go(space: Reference?, tab: Reference?)
    /// A bare name: a tab of the current space, else a space.
    case named(String)
    /// Show (true), hide (false) or toggle (nil) the sidebar.
    case sidebar(Bool?)
    case send
    case steer
    case newLine
    /// Remove what the last utterance added.
    case scratch
    case clear
    /// Interrupt the agent's turn.
    case interrupt
    case deny
    /// Answer the agent's question with an option, from 1.
    case option(Int)
    case listen
    case stopListening
    case readAgain
    case quiet

    public enum Kind: Equatable, Sendable { case space, tab }

    public enum Reference: Equatable, Sendable {
        /// From 1.
        case number(Int)
        case last
        /// Normalized: lowercase words separated by single spaces.
        case name(String)
    }

    /// What a transcript is.
    public enum Reading: Equatable, Sendable {
        /// It doesn't start with "Dispatch": ordinary dictation.
        case text
        case command(VoiceCommand)
        /// "Dispatch" and words that aren't a command (the remainder, as said).
        case unrecognized(String)
    }

    /// The words a command starts with unless the user chose others (`WakeWords`). Two syllables each: recognizers drop
    /// or mishear a short word that opens a sentence ("Dash", "Helm", "Deck" and "Patch" all failed with Apple's engine
    /// or Whisper).
    public static let defaultWakeWords: [String] = ["dispatch", "captain"]

    /// Whether `transcript` starts with a wake word (after "hey" or "OK"): a command on its way.
    public static func addressed(_ transcript: String, wakeWords: [String] = defaultWakeWords) -> Bool {
        afterWakeWord(VoiceMatch.words(transcript), wakeWords) != nil
    }

    private static func afterWakeWord(_ words: [String], _ wakeWords: [String]) -> [String]? {
        var words = words
        if let first = words.first, ["hey", "ok", "okay"].contains(first) { words.removeFirst() }
        guard let first = words.first, wakeWords.contains(first) else { return nil }
        return Array(words.dropFirst())
    }

    public static func read(_ transcript: String, wakeWords: [String] = defaultWakeWords) -> Reading {
        guard let words = afterWakeWord(VoiceMatch.words(transcript), wakeWords) else { return .text }
        return parse(words).map(Reading.command) ?? .unrecognized(words.joined(separator: " "))
    }

    static let leadingFiller: Set<String> = ["go", "switch", "jump", "open", "show", "take", "me", "to", "please", "can", "you"]
    static let filler: Set<String> = ["the", "number", "please"]

    static func parse(_ input: [String]) -> VoiceCommand? {
        // How both engines hear "tab two".
        var words = input.flatMap { $0 == "tattoo" ? ["tab", "two"] : [$0] }
        if words == ["back"] || words == ["go", "back"] || words == ["go", "to", "back"] { return .back }
        if let sidebar = sidebar(words) { return sidebar }
        if let chat = chat(words.filter { $0 != "the" && $0 != "please" }) { return chat }
        while let first = words.first, leadingFiller.contains(first) { words.removeFirst() }
        words.removeAll { filler.contains($0) }
        guard !words.isEmpty else { return nil }
        if words == ["back"] { return .back }
        if words.count == 2, let delta = ["next": 1, "previous": -1, "prev": -1][words[0]] {
            if let kind = kind(words[1]) { return .step(kind, delta) }
        }
        // "<tab> in <space>"
        if let split = words.firstIndex(where: { $0 == "in" || $0 == "on" }), split > 0, split < words.count - 1 {
            let tabWords = Array(words[..<split]), spaceWords = Array(words[(split + 1)...])
            guard let tab = reference(tabWords, keyword: "tab", bare: true),
                  let space = reference(spaceWords, keyword: "space", bare: true) else { return nil }
            return .go(space: space, tab: tab)
        }
        if let index = words.firstIndex(where: { kind($0) == .tab }) {
            let before = Array(words[..<index]), after = Array(words[(index + 1)...])
            // "tab 2", "billing tab 2", "space 3 tab 2"; else "second tab", "billing second tab", "the vim tab".
            let (spaceWords, tab): ([String], Reference?)
            if !after.isEmpty {
                (spaceWords, tab) = (before, value(after))
            } else if let last = before.last, let number = number(last) {
                (spaceWords, tab) = (Array(before.dropLast()), number)
            } else {
                (spaceWords, tab) = ([], value(before))
            }
            guard let tab else { return nil }
            if spaceWords.isEmpty { return .go(space: nil, tab: tab) }
            guard let space = reference(spaceWords, keyword: "space", bare: true) else { return nil }
            return .go(space: space, tab: tab)
        }
        if words.contains(where: { kind($0) == .space }) {
            guard let space = reference(words, keyword: "space", bare: false) else { return nil }
            return .go(space: space, tab: nil)
        }
        // A bare number or ordinal says neither space nor tab.
        if words.count == 1, number(words[0]) != nil { return nil }
        return .named(words.joined(separator: " "))
    }

    static let phrases: [[String]: VoiceCommand] = {
        var phrases: [[String]: VoiceCommand] = [:]
        func add(_ command: VoiceCommand, _ forms: String...) { for form in forms { phrases[form.split(separator: " ").map(String.init)] = command } }
        add(.send, "send", "send it", "send that", "send this", "send message", "submit")
        add(.steer, "steer", "steer it", "steer now", "send now")
        add(.newLine, "new line", "newline", "next line", "line break", "new paragraph")
        add(.scratch, "scratch that", "scratch", "strike that", "delete that", "undo", "undo that")
        add(.clear, "clear", "clear it", "clear draft", "clear all", "start over")
        add(.interrupt, "stop", "stop it", "stop agent", "stop turn", "interrupt", "cancel turn")
        add(.deny, "deny", "deny it", "deny that", "reject", "reject it", "don t allow", "do not allow")
        add(.listen, "listen", "start listening", "keep listening", "conversation mode")
        add(.stopListening, "stop listening", "stop dictation", "end conversation", "done listening")
        add(.readAgain, "read that", "read it", "read again", "read that again", "read reply", "read aloud", "repeat", "repeat that")
        add(.quiet, "quiet", "be quiet", "stop reading", "silence", "hush", "shut up")
        return phrases
    }()

    /// The chat's commands; "option 2", "answer two", "choose the second option".
    private static func chat(_ words: [String]) -> VoiceCommand? {
        if let command = phrases[words] { return command }
        var rest = words
        guard let first = rest.first, ["option", "answer", "choose", "pick", "select"].contains(first) else {
            // "second option"
            if words.count == 2, words[1] == "option", case .number(let number)? = number(words[0]) { return .option(number) }
            return nil
        }
        rest.removeFirst()
        if rest.first == "option" { rest.removeFirst() }
        if rest.count == 2, rest[1] == "option" { rest.removeLast() }
        guard rest.count == 1, case .number(let number)? = number(rest[0]) else { return nil }
        return .option(number)
    }

    /// An utterance that ends in a command after what it says: "Fix the login bug. Dispatch, send." Only commands that
    /// act on the draft or the conversation qualify, and the command must be all that follows "Dispatch".
    public static func trailing(_ transcript: String, wakeWords: [String] = defaultWakeWords)
        -> (text: String, command: VoiceCommand)? {
        let source = transcript as NSString
        let search = NSRange(location: 0, length: source.length)
        var last: NSRange?
        for word in wakeWords {
            var search = search
            while true {
                let found = source.range(of: word, options: [.caseInsensitive], range: search)
                guard found.location != NSNotFound else { break }
                let before = found.location == 0 ? nil : source.substring(with: NSRange(location: found.location - 1, length: 1))
                if found.location > 0, before?.rangeOfCharacter(from: .letters) == nil, found.location > last?.location ?? -1 {
                    last = found
                }
                search = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
            }
        }
        guard let last, case .command(let command) = read(source.substring(from: last.location), wakeWords: wakeWords) else {
            return nil
        }
        switch command {
        case .send, .steer, .newLine, .clear, .interrupt, .stopListening, .readAgain, .quiet: break
        default: return nil
        }
        let text = source.substring(to: last.location).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (text, command)
    }

    /// "open the sidebar", "hide side bar", "toggle sidebar", "sidebar off".
    private static func sidebar(_ input: [String]) -> VoiceCommand? {
        var words = input.filter { $0 != "the" && $0 != "please" }
        if let index = words.firstIndex(of: "side"), words.indices.contains(index + 1), words[index + 1] == "bar" {
            words.replaceSubrange(index...index + 1, with: ["sidebar"])
        }
        guard let index = words.firstIndex(of: "sidebar") else { return nil }
        let rest = words.filter { $0 != "sidebar" }
        guard rest.count <= 1, index == 0 || index == words.count - 1 else { return nil }
        switch rest.first {
        case nil, "toggle", "switch": return .sidebar(nil)
        case "open", "show", "reveal", "on": return .sidebar(true)
        case "close", "hide", "off": return .sidebar(false)
        default: return nil
        }
    }

    private static func kind(_ word: String) -> Kind? {
        switch word {
        case "space", "spaces": .space
        // "tap": how recognizers often hear "tab".
        case "tab", "tabs", "tap": .tab
        default: nil
        }
    }

    /// "space 3", "third space", "space billing", "billing space"; with `bare`, also "billing" and "3".
    private static func reference(_ words: [String], keyword: String, bare: Bool) -> Reference? {
        var words = words
        if let first = words.first, kind(first) == kind(keyword) { words.removeFirst() }
        else if let last = words.last, kind(last) == kind(keyword) { words.removeLast() }
        else if !bare { return nil }
        return value(words)
    }

    /// A number, "last", or a name.
    private static func value(_ words: [String]) -> Reference? {
        guard !words.isEmpty else { return nil }
        if words.count == 1, let number = number(words[0]) { return number }
        return .name(words.joined(separator: " "))
    }

    static func number(_ word: String) -> Reference? {
        if word == "last" { return .last }
        if let value = Int(word), value > 0 { return .number(value) }
        let digits = word.prefix { $0.isNumber }
        if !digits.isEmpty, ["st", "nd", "rd", "th"].contains(String(word.dropFirst(digits.count))), let value = Int(digits), value > 0 {
            return .number(value)
        }
        let cardinals = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
                        "eleventh", "twelfth"]
        // What recognizers write for a lone number word.
        let homophones = ["won": 1, "to": 2, "too": 2, "tree": 3, "for": 4, "fore": 4, "ate": 8]
        if let index = cardinals.firstIndex(of: word) ?? ordinals.firstIndex(of: word) { return .number(index + 1) }
        return homophones[word].map(Reference.number)
    }
}

/// Finds what a spoken name means among the app's names: exactly, then ignoring spaces ("api server" is
/// "api-server"), then as a unique start ("bill" is "billing"), then every word in it, then off by a letter or two
/// (recognizers misspell names they don't know).
public enum VoiceMatch {
    public enum Outcome<ID: Hashable>: Equatable {
        case none
        case one(ID)
        /// Several equally good matches.
        case several([ID])
    }

    /// Lowercase words of letters and digits.
    public static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    public static func normalize(_ text: String) -> String { words(text).joined(separator: " ") }

    public static func best<ID: Hashable>(_ spoken: String, among candidates: [(id: ID, name: String)]) -> Outcome<ID> {
        let query = normalize(spoken)
        guard !query.isEmpty else { return .none }
        let squeezedQuery = query.replacingOccurrences(of: " ", with: "")
        var best = 0, found: [ID] = []
        for candidate in candidates {
            let name = normalize(candidate.name)
            guard !name.isEmpty else { continue }
            let score = Self.score(query: query, squeezed: squeezedQuery, name: name)
            guard score > 0 else { continue }
            if score > best { best = score; found = [candidate.id] }
            else if score == best, !found.contains(candidate.id) { found.append(candidate.id) }
        }
        switch found.count {
        case 0: return .none
        case 1: return .one(found[0])
        default: return .several(found)
        }
    }

    private static func score(query: String, squeezed: String, name: String) -> Int {
        let squeezedName = name.replacingOccurrences(of: " ", with: "")
        if name == query { return 5 }
        if squeezedName == squeezed { return 4 }
        if squeezed.count >= 2, squeezedName.hasPrefix(squeezed) { return 3 }
        let nameWords = Set(name.split(separator: " ").map(String.init))
        if query.split(separator: " ").allSatisfy({ nameWords.contains(String($0)) }) { return 2 }
        let allowed = squeezed.count >= 8 ? 2 : squeezed.count >= 4 ? 1 : 0
        if allowed > 0, distance(squeezed, squeezedName, limit: allowed) <= allowed { return 1 }
        return 0
    }

    /// Levenshtein distance, giving up past `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// The user's wake words (Settings › Dictation): typed as a list, checked before they are used. A wake word is one
/// word that commands never use and sentences rarely start with; one of a single syllable works but is often dropped
/// or misheard by the recognizers, so it only draws a warning.
public enum WakeWords {
    public struct Checked: Equatable, Sendable {
        /// The words to use, lowercase, in the order typed; empty when none can be used.
        public var words: [String]
        /// Why typed words were left out.
        public var problems: [String]
        /// Words that are used but may not be heard reliably.
        public var warnings: [String]
    }

    /// Words of the commands themselves: a wake word among them would read its own commands wrongly.
    static let reserved: Set<String> = {
        var words: Set<String> = ["send", "steer", "tab", "tabs", "tap", "space", "spaces", "back", "next", "previous", "prev",
                                  "last", "stop", "clear", "scratch", "strike", "undo", "delete", "deny", "reject", "option",
                                  "answer", "choose", "pick", "select", "listen", "quiet", "silence", "hush", "read", "repeat",
                                  "sidebar", "side", "bar", "open", "close", "hide", "show", "toggle", "reveal", "go", "switch",
                                  "jump", "take", "new", "line", "newline", "in", "on", "off", "number", "interrupt", "submit"]
        words.formUnion(["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "first", "second",
                         "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"])
        return words
    }()

    /// Words sentences often start with.
    static let common: Set<String> = ["a", "an", "and", "the", "i", "it", "is", "to", "this", "that", "so", "yes", "no", "hi",
                                      "hello", "hey", "ok", "okay", "please", "thanks", "what", "how", "why", "can", "you",
                                      "we", "let", "lets", "now", "then", "also", "but", "or", "if", "my", "our", "just", "well"]

    /// The words of `text` (separated by commas or spaces) that can be wake words.
    public static func check(_ text: String) -> Checked {
        var result = Checked(words: [], problems: [], warnings: [])
        let entries = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for entry in entries {
            let words = VoiceMatch.words(entry)
            guard words.count == 1, let word = words.first else {
                result.problems.append("“\(entry)” is more than one word")
                continue
            }
            if word.allSatisfy(\.isNumber) { result.problems.append("“\(entry)” is a number"); continue }
            if reserved.contains(word) { result.problems.append("“\(entry)” is a command word"); continue }
            if common.contains(word) { result.problems.append("“\(entry)” starts too many sentences"); continue }
            guard !result.words.contains(word) else { continue }
            result.words.append(word)
            if syllables(word) < 2 { result.warnings.append("“\(entry)” is short: recognizers often drop or mishear one syllable") }
        }
        return result
    }

    /// Vowel groups, less a silent final e: near enough to tell one syllable from two.
    static func syllables(_ word: String) -> Int {
        let vowels = Set("aeiouy")
        var count = 0, previous = false
        for character in word {
            let vowel = vowels.contains(character)
            if vowel && !previous { count += 1 }
            previous = vowel
        }
        if word.hasSuffix("e"), !word.hasSuffix("le"), count > 1 { count -= 1 }
        return max(1, count)
    }
}
