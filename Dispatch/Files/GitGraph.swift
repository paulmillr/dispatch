import Foundation

/// The Commits tab's graph (F4a), drawn by the app from the log's parents rather than `git log --graph`: lanes are
/// assigned top-down, each row says where its commit's dot sits and which lines cross it. Pure, so the view only
/// draws and the tests read the lanes.
///
/// A lane holds the hash it waits for. A commit takes the leftmost lane waiting for it (a tip takes the first free
/// lane); every other lane waiting for it ends in its dot. Its first parent continues in its lane, unless another
/// lane already waits for that parent, in which case the line joins that lane and the commit's lane frees; later
/// parents (a merge's) join a lane waiting for them or open the first free one. Freed lanes are reused, so a
/// finished branch gives its column back.
struct GitGraph: Hashable, Sendable {
    /// How many lanes are drawn; deeper ones collapse into a count at the row's left edge.
    static let maxLanes = 8

    struct Line: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// The top edge to the bottom edge in one lane: a branch passing the row.
            case pass
            /// The top edge at `from` into the dot at `to`: the commit's child line, or a branch that forked here.
            case into
            /// The dot at `from` to the bottom edge at `to`: a parent line, curving when it changes lane.
            case out
        }

        var kind: Kind
        var from: Int
        var to: Int
        /// On the current branch's first-parent chain: drawn green, the rest slate.
        var current: Bool
    }

    struct Row: Hashable, Sendable {
        /// The dot's lane; at or beyond `maxLanes` the dot is not drawn and `hidden` counts it.
        var lane: Int
        var current: Bool
        /// Only lines within the drawn lanes.
        var lines: [Line]
        /// Lanes beyond `maxLanes` with something in this row, shown as a count at the left edge.
        var hidden: Int
    }

    var rows: [Row]
    /// The uncommitted changes' hollow dot over the log: its lane (HEAD's) and whether a line runs down to HEAD. Nil
    /// when asked for none.
    var top: Row?
    /// The widest row's drawn lanes: the graph column's width.
    var lanes: Int

    static let empty = GitGraph(rows: [], top: nil, lanes: 0)

    /// The graph of `commits` in log order. `head` (a full or abbreviated hash) marks the current branch: its
    /// first-parent chain is green. `uncommitted` adds the hollow dot above, joined to HEAD. `linked` false draws
    /// each commit alone in the first lane: a filtered log's parents are mostly not in it, and lines to them would
    /// run to the bottom.
    static func layout(_ commits: [GitCommit], head: String?, uncommitted: Bool = false, linked: Bool = true,
                       maxLanes: Int = maxLanes) -> GitGraph {
        let headHash = head.flatMap { head in commits.first { !head.isEmpty && $0.hash.hasPrefix(head) }?.hash }
        let current = mainline(commits, from: headHash)
        guard linked else {
            let rows = commits.map { Row(lane: 0, current: current.contains($0.hash), lines: [], hidden: 0) }
            let top = uncommitted ? Row(lane: 0, current: true, lines: [], hidden: 0) : nil
            return GitGraph(rows: rows, top: top, lanes: commits.isEmpty && top == nil ? 0 : 1)
        }

        // Each lane: the hash it waits for and whether the line into it is the current branch's.
        var lanes: [(hash: String, current: Bool)?] = []
        var top: Row?
        if uncommitted {
            if let headHash {
                lanes = [(headHash, true)]
                top = Row(lane: 0, current: true, lines: [Line(kind: .out, from: 0, to: 0, current: true)], hidden: 0)
            } else {
                // HEAD is not loaded (another scope, or an unborn branch): the dot stands alone.
                top = Row(lane: 0, current: true, lines: [], hidden: 0)
            }
        }

        func freeLane() -> Int {
            if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
            lanes.append(nil)
            return lanes.count - 1
        }

        var rows: [Row] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            let onCurrent = current.contains(commit.hash)
            let waiting = lanes.indices.filter { lanes[$0]?.hash == commit.hash }
            // The current branch keeps its own lane when two lines meet at its commit.
            let lane = waiting.first { lanes[$0]?.current == true } ?? waiting.first ?? freeLane()
            var lines: [Line] = []
            for index in lanes.indices {
                guard let waiter = lanes[index] else { continue }
                if waiter.hash == commit.hash {
                    lines.append(Line(kind: .into, from: index, to: lane, current: waiter.current))
                } else {
                    lines.append(Line(kind: .pass, from: index, to: index, current: waiter.current))
                }
            }
            for index in waiting { lanes[index] = nil }

            for (position, parent) in commit.parents.enumerated() {
                let edgeCurrent = onCurrent && position == 0
                let existing = lanes.firstIndex { $0?.hash == parent }
                if position == 0 {
                    // The first parent stays in this lane unless a lane already waits for it; the current branch's
                    // line keeps its lane even then (the two meet at the parent), so it does not wander right.
                    if let existing, !(edgeCurrent && lanes[existing]?.current == false) {
                        lines.append(Line(kind: .out, from: lane, to: existing, current: edgeCurrent))
                    } else {
                        lanes[lane] = (parent, edgeCurrent)
                        lines.append(Line(kind: .out, from: lane, to: lane, current: edgeCurrent))
                    }
                } else if let existing {
                    lines.append(Line(kind: .out, from: lane, to: existing, current: false))
                } else {
                    let slot = freeLane()
                    lanes[slot] = (parent, false)
                    lines.append(Line(kind: .out, from: lane, to: slot, current: false))
                }
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }

            var deep: Set<Int> = lane >= maxLanes ? [lane] : []
            for line in lines {
                if line.from >= maxLanes { deep.insert(line.from) }
                if line.to >= maxLanes { deep.insert(line.to) }
            }
            rows.append(Row(lane: lane, current: onCurrent,
                            lines: lines.filter { $0.from < maxLanes && $0.to < maxLanes }, hidden: deep.count))
        }

        var widest = top == nil ? 0 : 1
        for row in rows {
            widest = max(widest, row.lane + 1)
            for line in row.lines { widest = max(widest, line.from + 1, line.to + 1) }
        }
        return GitGraph(rows: rows, top: top, lanes: min(widest, maxLanes))
    }

    /// HEAD and its first parents, as far as the log reaches.
    static func mainline(_ commits: [GitCommit], from head: String?) -> Set<String> {
        guard let head else { return [] }
        let parents = Dictionary(commits.map { ($0.hash, $0.parents.first) }, uniquingKeysWith: { first, _ in first })
        var chain: Set<String> = []
        var next: String? = head
        while let hash = next, parents[hash] != nil, chain.insert(hash).inserted {
            next = parents[hash] ?? nil
        }
        return chain
    }

    /// The checked-out commit: the one carrying the current branch's or HEAD's ref, else the status's HEAD, else the
    /// first commit of a log of this branch (which starts at HEAD).
    static func head(in commits: [GitCommit], status: GitStatus?, scope: GitLogScope) -> String? {
        if let marked = commits.first(where: { $0.refs.contains { $0.current || $0.kind == .head } }) {
            return marked.hash
        }
        if let short = status?.head, !short.isEmpty { return short }
        return scope == .branch ? commits.first?.hash : nil
    }
}
