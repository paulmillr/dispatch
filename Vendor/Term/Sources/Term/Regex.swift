// A backtracking matcher for the oniguruma syntax Ghostty's link regexes use (config/url.zig):
// literals and escapes, classes with ranges and \w \d, groups, alternation, greedy and lazy
// quantifiers (* + ? {m,n}), look-ahead and look-behind (any length). Leftmost match, first
// alternative first, like oniguruma's search; \w and \d are oniguruma's own sets (from the
// oracle's tables). Like oniguruma, matching stops after 100000 retries so a pathological terminal
// line cannot hold the UI thread indefinitely.

public struct Regex {
    static let searchRetryLimit = 100_000
    static let searchDepthLimit = 4_096

    indirect enum Node {
        case char(UInt32), set([Item], negated: Bool), seq([Node]), alt([Node])
        case loop(Node, min: Int, max: Int?, greedy: Bool), look(Node, ahead: Bool, negated: Bool)
    }
    enum Item { case char(UInt32), range(UInt32, UInt32), word, digit }

    let root: Node

    /// nil: syntax this matcher doesn't know.
    public init?(_ pattern: String) {
        var p = Parser(cps: pattern.unicodeScalars.map(\.value))
        guard let n = p.alternation(), p.i == p.cps.count else { return nil }
        root = n
    }

    /// The first match at or after `from` in `s` (code points), as a range of code point indices.
    public func search(_ s: [UInt32], from: Int = 0) -> Range<Int>? {
        search(s, from: from, retryLimit: Self.searchRetryLimit).match
    }

    @_spi(Test)
    public func searchForTest(
        _ s: [UInt32],
        from: Int = 0,
        retryLimit: Int
    ) -> (match: Range<Int>?, exhausted: Bool) {
        search(s, from: from, retryLimit: retryLimit)
    }

    private func search(
        _ s: [UInt32],
        from: Int,
        retryLimit: Int
    ) -> (match: Range<Int>?, exhausted: Bool) {
        guard from >= 0, from <= s.count, retryLimit > 0 else {
            return (nil, retryLimit <= 0)
        }

        let budget = MatchBudget(retries: retryLimit, depth: Self.searchDepthLimit)
        let m = Matcher(s: s, budget: budget)
        for start in from...s.count {
            var end = -1
            if m.match(root, start, { end = $0; return true }) { return (start..<end, false) }
            if budget.exhausted { break }
        }
        return (nil, budget.exhausted)
    }

    struct Parser {
        let cps: [UInt32]
        var i = 0

        func peek(_ c: Character) -> Bool { i < cps.count && cps[i] == c.unicodeScalars.first!.value }
        mutating func eat(_ c: Character) -> Bool { if peek(c) { i += 1; return true }; return false }

        mutating func alternation() -> Node? {
            var branches: [Node] = []
            repeat { guard let s = sequence() else { return nil }; branches.append(s) } while eat("|")
            return branches.count == 1 ? branches[0] : .alt(branches)
        }

        mutating func sequence() -> Node? {
            var items: [Node] = []
            while i < cps.count, !peek("|"), !peek(")") {
                guard var atom = atom() else { return nil }
                while let (lo, hi) = quantifier() { atom = .loop(atom, min: lo, max: hi, greedy: !eat("?")) }
                items.append(atom)
            }
            return items.count == 1 ? items[0] : .seq(items)
        }

        mutating func quantifier() -> (Int, Int?)? {
            if eat("*") { return (0, nil) }
            if eat("+") { return (1, nil) }
            if eat("?") { return (0, 1) }
            let save = i
            guard eat("{"), let lo = number() else { i = save; return nil }
            let hi = eat(",") ? number() : lo   // {m,}: no maximum
            guard eat("}") else { i = save; return nil }
            return (lo, hi)
        }

        mutating func number() -> Int? {
            var n: Int?
            while i < cps.count, (0x30...0x39).contains(cps[i]) { n = (n ?? 0) * 10 + Int(cps[i] - 0x30); i += 1 }
            return n
        }

        mutating func atom() -> Node? {
            if eat("(") {
                var look: (ahead: Bool, negated: Bool)?
                if eat("?") {
                    let ahead = !eat("<")
                    if ahead, eat(":") {} else if eat("=") { look = (ahead, false) } else if eat("!") { look = (ahead, true) } else { return nil }
                }
                guard let inner = alternation(), eat(")") else { return nil }
                return look.map { .look(inner, ahead: $0.ahead, negated: $0.negated) } ?? inner
            }
            if eat("[") {
                let negated = eat("^")
                var items: [Item] = []
                while i < cps.count, !peek("]") {
                    guard let a = classAtom() else { return nil }
                    if case .char(let lo) = a, peek("-"), i + 1 < cps.count, cps[i + 1] != 0x5D {
                        i += 1
                        guard case .char(let hi)? = classAtom() else { return nil }
                        items.append(.range(lo, hi))
                    } else { items.append(a) }
                }
                guard eat("]") else { return nil }
                return .set(items, negated: negated)
            }
            guard let a = classAtom() else { return nil }
            if case .char(let c) = a { return .char(c) }
            return .set([a], negated: false)
        }

        /// A character or an escape (\w \d, or an escaped symbol).
        mutating func classAtom() -> Item? {
            guard i < cps.count else { return nil }
            let c = cps[i]
            i += 1
            guard c == 0x5C else { return .char(c) }
            guard i < cps.count else { return nil }
            let e = cps[i]
            i += 1
            switch e {
            case 0x77: return .word
            case 0x64: return .digit
            case 0x6E: return .char(0x0A)
            case 0x74: return .char(0x09)
            case _ where (0x41...0x5A).contains(e) || (0x61...0x7A).contains(e) || (0x30...0x39).contains(e): return nil
            default: return .char(e)
            }
        }
    }

    final class MatchBudget {
        private var retries: Int
        private let depthLimit: Int
        private var depth = 0
        private(set) var exhausted = false

        init(retries: Int, depth: Int) {
            self.retries = retries
            self.depthLimit = depth
        }

        func enter() -> Bool {
            guard !exhausted, retries > 0, depth < depthLimit else {
                exhausted = true
                return false
            }
            retries -= 1
            depth += 1
            return true
        }

        func leave() { depth -= 1 }
    }

    struct Matcher {
        let s: [UInt32]
        let budget: MatchBudget

        func match(_ n: Node, _ i: Int, _ k: (Int) -> Bool) -> Bool {
            guard budget.enter() else { return false }
            defer { budget.leave() }

            switch n {
            case .char(let c): return i < s.count && s[i] == c && k(i + 1)
            case .set(let items, let negated): return i < s.count && Self.contains(items, s[i]) != negated && k(i + 1)
            case .seq(let nodes): return sequence(nodes[...], i, k)
            case .alt(let nodes): return nodes.contains { match($0, i, k) }
            case .loop(let x, let lo, let hi, let greedy):
                // Iterations past the minimum must consume something (oniguruma's empty-loop check).
                func iterate(_ count: Int, _ j: Int) -> Bool {
                    if count < lo { return match(x, j) { iterate(count + 1, $0) } }
                    guard hi.map({ count < $0 }) ?? true else { return k(j) }
                    if greedy { return match(x, j) { $0 != j && iterate(count + 1, $0) } || k(j) }
                    return k(j) || match(x, j) { $0 != j && iterate(count + 1, $0) }
                }
                return iterate(0, i)
            case .look(let x, let ahead, let negated):
                let found = ahead ? match(x, i) { _ in true } : (0...i).reversed().contains { start in match(x, start) { $0 == i } }
                return found != negated && k(i)
            }
        }

        func sequence(_ nodes: ArraySlice<Node>, _ i: Int, _ k: (Int) -> Bool) -> Bool {
            guard let first = nodes.first else { return k(i) }
            return match(first, i) { sequence(nodes.dropFirst(), $0, k) }
        }

        static func contains(_ items: [Item], _ c: UInt32) -> Bool {
            items.contains {
                switch $0 {
                case .char(let x): x == c
                case .range(let lo, let hi): (lo...hi).contains(c)
                case .word: Unicode.isWord(c)
                case .digit: Unicode.isDigit(c)
                }
            }
        }
    }
}
