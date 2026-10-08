// The part of z2d (the vector library Ghostty draws its sprites with) the sprites use, ported
// operation for operation so the pixels match: paths of lines, cubic curves and arcs; fill
// (non-zero winding, 4x4 multisampling); stroke (butt/round caps, miter/round joins); path offset
// (inner strokes). Ghostty's paths only ever carry a translation (the canvas padding).

import Foundation

extension Sprite {
    struct Point: Equatable { var x: Double, y: Double }

    /// z2d's default tolerance: how far flattened curves may stray, in pixels.
    static let tolerance = 0.1

    /// z2d Transformation as Ghostty uses it: a translation.
    struct Translation: Equatable {
        var tx = 0.0, ty = 0.0
        func apply(_ p: Point) -> Point { Point(x: p.x + tx, y: p.y + ty) }
    }

    enum Node { case move(Point), line(Point), curve(Point, Point, Point), close }

    /// z2d Path: user points go through `ctm` (clamped to the 24-bit range first) into device nodes.
    struct Path {
        var nodes: [Node] = [], initial: Point?, current: Point?, ctm = Translation()

        func device(_ x: Double, _ y: Double) -> Point {
            // std.math.clamp: @min/@max take the number over NaN.
            let clamp = { (v: Double) in Double.maximum(-8388608, Double.minimum(v, 8388607)) }
            return ctm.apply(Point(x: clamp(x), y: clamp(y)))
        }
        mutating func move(_ x: Double, _ y: Double) {
            let p = device(x, y)
            nodes.append(.move(p))
            (initial, current) = (p, p)
        }
        mutating func line(_ x: Double, _ y: Double) {
            guard current != nil else { return move(x, y) }
            let p = device(x, y)
            nodes.append(.line(p))
            current = p
        }
        mutating func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) {
            guard current != nil else { return }   // z2d: NoCurrentPoint (the sprites always start with a point)
            let p = device(x3, y3)
            nodes.append(.curve(device(x1, y1), device(x2, y2), p))
            current = p
        }
        /// A close and a move back to the start; the current point stays where it was.
        mutating func close() {
            guard current != nil, let p = initial else { return }
            nodes += [.close, .move(p)]
        }
        /// Path.arc: a line to the arc's start, then curves (halves of more than pi split first).
        mutating func arc(_ xc: Double, _ yc: Double, _ r: Double, _ a1: Double, _ a2: Double) {
            var a2 = a2
            while a2 < a1 { a2 += .pi * 2 }
            arc(xc, yc, r, from: a1, to: a2)
        }
        private mutating func arc(_ xc: Double, _ yc: Double, _ r: Double, from lo: Double, to hi: Double) {
            if hi - lo > .pi {
                let mid = lo + (hi - lo) / 2.0
                arc(xc, yc, r, from: lo, to: mid)
                arc(xc, yc, r, from: mid, to: hi)
                return
            }
            // z2d skips this line when it would not move (comparing device to user points); a line
            // that doesn't move adds nothing to fills or strokes.
            line(xc + r * cos(lo), yc + r * sin(lo))
            guard hi != lo else { return }
            let segments = Int((abs(hi - lo) / Self.maxAngle(Sprite.tolerance / r)).rounded(.up)), step = (hi - lo) / Double(segments)
            var a = lo
            for _ in 0..<Swift.max(0, segments - 1) {
                segment(xc, yc, r, a, a + step)
                a += step
            }
            segment(xc, yc, r, a, hi)
        }
        private mutating func segment(_ xc: Double, _ yc: Double, _ r: Double, _ a: Double, _ b: Double) {
            let (sa, ca, sb, cb) = (r * sin(a), r * cos(a), r * sin(b), r * cos(b))
            let h = 4.0 / 3.0 * tan((b - a) / 4.0)
            curve(xc + ca - h * sa, yc + sa + h * ca, xc + cb + h * sb, yc + sb - h * cb, xc + cb, yc + sb)
        }
        /// arc_max_angle_for_tolerance_normalized: the widest angle a curve covers within the error.
        static func maxAngle(_ tolerance: Double) -> Double {
            let errors = [0.0185185185185185036127, 0.000272567143730179811158, 2.38647043651461047433e-05, 4.2455377443222443279e-06,
                          1.11281001494389081528e-06, 3.72662000942734705475e-07, 1.47783685574284411325e-07, 6.63240432022601149057e-08,
                          3.2715520137536980553e-08, 1.73863223499021216974e-08, 9.81410988043554039085e-09]
            if let i = errors.firstIndex(where: { $0 < tolerance }) { return .pi / Double(i + 1) }
            var angle = 0.0
            for i in errors.count..<1000 {
                angle = .pi / Double(i)
                if 2.0 / 27.0 * pow(sin(angle / 4), 6) / pow(cos(angle / 4), 2) <= tolerance { break }
            }
            return angle
        }
    }

    /// Spline.decompose: a cubic curve from `a` as lines, halved until flat within the tolerance.
    /// (z2d's shortcut for a curve with control points on its ends, and its skip of the first
    /// piece's start, change nothing: both give lines to points already reached.)
    static func flatten(_ a: Point, _ b: Point, _ c: Point, _ d: Point, _ tolerance: Double, _ line: (Point) -> Void) {
        let half = { (p: Point, q: Point) in Point(x: p.x + (q.x - p.x) / 2, y: p.y + (q.y - p.y) / 2) }
        func split(_ k: [Point]) {
            if errorSquared(k) < tolerance * tolerance { return line(k[0]) }
            let (ab, bc, cd) = (half(k[0], k[1]), half(k[1], k[2]), half(k[2], k[3]))
            let (abbc, bccd) = (half(ab, bc), half(bc, cd))
            let mid = half(abbc, bccd)
            split([k[0], ab, abbc, mid])
            split([mid, bccd, cd, k[3]])
        }
        split([a, b, c, d])
        line(d)
    }

    /// Knots.errorSq: how far the control points stray from the chord.
    static func errorSquared(_ k: [Point]) -> Double {
        var (b, c) = (Point(x: k[1].x - k[0].x, y: k[1].y - k[0].y), Point(x: k[2].x - k[0].x, y: k[2].y - k[0].y))
        if k[0] != k[3] {
            let d = Point(x: k[3].x - k[0].x, y: k[3].y - k[0].y), dd = d.x * d.x + d.y * d.y
            let bd = b.x * d.x + b.y * d.y
            if bd >= dd { (b.x, b.y) = (b.x - d.x, b.y - d.y) } else { (b.x, b.y) = (b.x - bd / dd * d.x, b.y - bd / dd * d.y) }
            let cd = c.x * d.x + c.y * d.y
            if cd >= dd { (c.x, c.y) = (c.x - d.x, c.y - d.y) } else { (c.x, c.y) = (c.x - cd / dd * d.x, c.y - cd / dd * d.y) }
        }
        let (be, ce) = (b.x * b.x + b.y * b.y, c.x * c.x + c.y * c.y)
        return be > ce ? be : ce
    }

    /// point_buffer.zig PointBuffer: the first `split` points stay, the rest keep the latest ones.
    struct Points {
        let split: Int, capacity: Int
        var items: [Point] = []
        mutating func add(_ p: Point) {
            if items.count < capacity { items.append(p) } else { items.remove(at: split); items.append(p) }
        }
        func tail(_ n: Int) -> Point { items[items.count - n] }
    }

    /// A polygon's edges (scaled at insertion) for the rasterizer; horizontal edges are dropped.
    struct Polygon {
        struct Edge {
            var y0: Double, y1: Double, x: Double, inc: Double
            var top: Double { y0 < y1 ? y0 : y1 }
            var bottom: Double { y0 < y1 ? y1 : y0 }
            var dir: Int { y0 < y1 ? -1 : 1 }
        }
        var edges: [Edge] = [], scale = 1.0
        var top = 0.0, bottom = 0.0, left = 0.0, right = 0.0

        mutating func add(_ a: Point, _ b: Point) {
            let (p, q) = (Point(x: a.x * scale, y: a.y * scale), Point(x: b.x * scale, y: b.y * scale))
            let e: Edge
            if p.y < q.y { e = Edge(y0: p.y, y1: q.y, x: p.x, inc: (q.x - p.x) / (q.y - p.y)) }
            else if p.y > q.y { e = Edge(y0: p.y, y1: q.y, x: q.x, inc: (p.x - q.x) / (p.y - q.y)) }
            else { return }
            let (l, r) = p.x < q.x ? (p.x, q.x) : (q.x, p.x)
            if edges.isEmpty { (top, bottom, left, right) = (e.top, e.bottom, l, r) } else {
                if e.top < top { top = e.top }
                if e.bottom > bottom { bottom = e.bottom }
                if l < left { left = l }
                if r > right { right = r }
            }
            edges.append(e)
        }
        /// addEdgesFromContour: the corners in order, closed back to the first.
        mutating func add(contour c: [Point]) {
            for (a, b) in zip(c, c.dropFirst()) { add(a, b) }
            if let first = c.first, let last = c.last { add(last, first) }
        }
    }

    /// fill_plotter.plot: a closed path's edges, curves flattened, scaled by `scale`.
    static func fillPolygon(_ nodes: [Node], scale: Double, tolerance: Double) -> Polygon {
        var (poly, points) = (Polygon(scale: scale), Points(split: 1, capacity: 3))
        let line = { (p: Point) in
            if points.items.last! != p { poly.add(points.items.last!, p); points.add(p) }
        }
        for (i, node) in nodes.enumerated() {
            switch node {
            case .move(let p):
                if i == nodes.count - 1 { return poly }
                points.items = [p]
            case .line(let p): line(p)
            case .curve(let b, let c, let d): flatten(points.items.last!, b, c, d, tolerance, line)
            case .close:
                guard let first = points.items.first, let last = points.items.last, last != first else { continue }
                poly.add(last, first)
                points.add(first)
            }
        }
        return poly
    }

    /// Slope.zig: a direction, compared by angle.
    struct Slope: Equatable {
        var dx: Double, dy: Double
        init(dx: Double, dy: Double) { (self.dx, self.dy) = (dx, dy) }
        init(_ a: Point, _ b: Point) { (dx, dy) = (b.x - a.x, b.y - a.y) }

        var normalized: Slope {
            if dx == 0 { return Slope(dx: 0, dy: dy > 0 ? 1 : -1) }
            if dy == 0 { return Slope(dx: dx > 0 ? 1 : -1, dy: 0) }
            let mag = Sprite.hypot(dx, dy)
            return Slope(dx: dx / mag, dy: dy / mag)
        }
        /// Slope.compare: -1, 0 or 1 (differences within an epsilon snap to `a`'s value).
        func compare(_ b: Slope) -> Int {
            let snap = { (a: Double, b: Double) in abs(b - a) > Double.ulpOfOne ? b : a }
            let (bdy, bdx) = (snap(dy, b.dy), snap(dx, b.dx))
            let cmp = sign(dy * bdx - bdy * dx)
            if cmp != 0 { return cmp }
            if dx == 0 && dy == 0 && bdx == 0 && bdy == 0 { return 0 }
            if dx == 0 && dy == 0 { return 1 }
            if bdx == 0 && bdy == 0 { return -1 }
            if sign(dx) != sign(bdx) || sign(dy) != sign(bdy) { return dx > 0 || (dx == 0 && dy > 0) ? -1 : 1 }
            return 0
        }
        func sign(_ v: Double) -> Int { v > 0 ? 1 : v < 0 ? -1 : 0 }
    }

    /// std.math.hypot for f64 (Zig's own, fused multiply-adds), not the C library's.
    static func hypot(_ x: Double, _ y: Double) -> Double {
        if x.isInfinite || y.isInfinite { return .infinity }
        if x.isNaN || y.isNaN { return .nan }
        let (lower, upper) = (Double.leastNormalMagnitude.squareRoot(), (Double.greatestFiniteMagnitude / 2).squareRoot())
        let scale = Double.leastNonzeroMagnitude * upper
        var (major, minor) = (abs(x), abs(y))
        if minor > major { swap(&major, &minor) }
        if minor == 0 || major - minor == major { return major }
        let fused = { (x: Double, y: Double) -> Double in
            let r = (y * y).addingProduct(x, x).squareRoot(), rr = r * r, xx = x * x
            let z = (rr - xx).addingProduct(-y, y) + (-rr).addingProduct(r, r) - (-xx).addingProduct(x, x)
            return r - z / (2 * r)
        }
        if major > upper { return fused(major * scale, minor * scale) / scale }
        if minor < lower { return fused(major / scale, minor / scale) * scale }
        return fused(major, minor)
    }

    /// std.math.acos for f64 (Zig's own, from musl), not the C library's.
    static func acos(_ x: Double) -> Double {
        let (pio2Hi, pio2Lo) = (1.57079632679489655800e+00, 6.12323399573676603587e-17)
        let r = { (z: Double) -> Double in
            let p = z * (1.66666666666666657415e-01 + z * (-3.25565818622400915405e-01 + z * (2.01212532134862925881e-01
                + z * (-4.00555345006794114027e-02 + z * (7.91534994289814532176e-04 + z * 3.47933107596021167570e-05)))))
            let q = 1.0 + z * (-2.40339491173441421878e+00 + z * (2.02094576023350569471e+00 + z * (-6.88283971605453293030e-01 + z * 7.70381505559019352791e-02)))
            return p / q
        }
        let hx = UInt32(x.bitPattern >> 32), ix = hx & 0x7fff_ffff
        if ix >= 0x3ff0_0000 {
            if (ix - 0x3ff0_0000) | UInt32(truncatingIfNeeded: x.bitPattern) == 0 { return hx >> 31 != 0 ? 2.0 * pio2Hi + 0x1.0p-120 : 0 }
            return 0.0 / (x - x)
        }
        if ix < 0x3fe0_0000 {
            if ix <= 0x3c60_0000 { return pio2Hi + 0x1.0p-120 }
            return pio2Hi - (x - (pio2Lo - x * r(x * x)))
        }
        if hx >> 31 != 0 {
            let z = (1.0 + x) * 0.5, s = z.squareRoot()
            return 2 * (pio2Hi - (s + (r(z) * s - pio2Lo)))
        }
        let z = (1.0 - x) * 0.5, s = z.squareRoot()
        let df = Double(bitPattern: s.bitPattern & 0xffff_ffff_0000_0000)
        let c = (z - df * df) / (s + df)
        return 2.0 * (df + (r(z) * s + c))
    }
}

extension Sprite {
    enum Cap { case butt, round }
    enum Join { case miter, round }

    /// tess/Face.zig: a segment and its two sides, half the line width away.
    struct Face {
        let p0: Point, p1: Point, slope: Slope, width: Double, ctm: Translation
        let p0cw: Point, p0ccw: Point, p1cw: Point, p1ccw: Point

        init(_ p0: Point, _ p1: Point, _ width: Double, _ ctm: Translation) {
            (self.p0, self.p1, self.width, self.ctm, slope) = (p0, p1, width, ctm, Slope(p0, p1).normalized)
            // A transformed stroke measures its width in user space (normalized again there).
            let side = ctm == Translation() ? slope : slope.normalized, half = width / 2
            let (ox, oy) = (-side.dy * half, side.dx * half)
            (p0cw, p0ccw) = (Point(x: p0.x + ox, y: p0.y + oy), Point(x: p0.x + -ox, y: p0.y + -oy))
            (p1cw, p1ccw) = (Point(x: p1.x + ox, y: p1.y + oy), Point(x: p1.x + -ox, y: p1.y + -oy))
        }

        /// Face.intersect: where the outer sides of this face and `out` meet (a miter tip).
        func intersect(_ out: Face, _ clockwise: Bool) -> Point {
            let (a, b) = (clockwise ? p1ccw : p1cw, clockwise ? out.p0ccw : out.p0cw)
            let (i, o) = (slope.normalized, out.slope.normalized)
            let y = ((b.x - a.x) * i.dy * o.dy - b.y * o.dx * i.dy + a.y * i.dx * o.dy) / (i.dx * o.dy - o.dx * i.dy)
            let x = abs(i.dy) >= abs(o.dy) ? (y - a.y) * i.dx / i.dy + a.x : (y - b.y) * o.dx / o.dy + b.x
            return Point(x: x, y: y)
        }

        /// Face.cap (for the p1 end): butt, or round with the pen's vertices.
        func cap(_ mode: Cap, _ clockwise: Bool, _ pen: Pen?) -> [Point] {
            let (first, last) = clockwise ? (p1ccw, p1cw) : (p1cw, p1ccw)
            guard mode == .round, let pen else { return [first, last] }
            let turn = pen.vertices(from: slope, to: Slope(dx: -slope.dx, dy: -slope.dy), clockwise: clockwise)
            return [first] + turn.map { Point(x: p1.x + $0.x, y: p1.y + $0.y) } + [last]
        }
    }

    /// tess/Pen.zig: a polygon approximating the circle of the line width, for round caps and joins.
    struct Pen {
        let points: [Point], cw: [Slope], ccw: [Slope]

        init(_ width: Double) {
            let r = width / 2
            let n: Int
            if Sprite.tolerance >= r * 4 { n = 1 } else if Sprite.tolerance >= r { n = 4 } else {
                let delta = Sprite.acos(1 - Sprite.tolerance / r)
                let m = delta == 0 ? 4 : Int((2 * .pi / delta).rounded(.up))
                n = m < 4 ? 4 : m % 2 != 0 ? m + 1 : m
            }
            points = (0..<n).map { i in
                let theta = 2 * .pi * Double(i) / Double(n)
                return Point(x: r * cos(theta), y: r * sin(theta))
            }
            let pts = points
            cw = (0..<n).map { Slope(pts[($0 + n - 1) % n], pts[$0]) }
            ccw = (0..<n).map { Slope(pts[$0], pts[($0 + 1) % n]) }
        }

        /// vertexIteratorFor: the vertices turning from one direction to the other.
        func vertices(from: Slope, to: Slope, clockwise: Bool) -> [Point] {
            let n = points.count
            // The first vertex past `from`, then the last one before `to` (searching once around).
            let first = clockwise ? { (i: Int) in cw[i].compare(from) < 0 } : { (i: Int) in from.compare(ccw[i]) < 0 }
            let past = clockwise ? { (j: Int) in cw[j].compare(to) > 0 } : { (j: Int) in to.compare(ccw[j]) > 0 }
            var (low, high) = (0, n), i = (low + high) >> 1
            while high - low > 1 {
                if first(i) { low = i } else { high = i }
                i = (low + high) >> 1
            }
            if first(i) { i = i + 1 == n ? 0 : i + 1 }
            let start = i
            if clockwise ? to.compare(ccw[i]) >= 0 : cw[i].compare(to) <= 0 {
                (low, high) = (i, i + n)
                i = (low + high) >> 1
                while high - low > 1 {
                    if past(i >= n ? i - n : i) { high = i } else { low = i }
                    i = (low + high) >> 1
                }
                if i >= n { i -= n }
            }
            var (out, idx) = ([Point](), start)
            while idx != i {
                out.append(points[idx])
                idx = clockwise ? (idx + 1 == n ? 0 : idx + 1) : (idx == 0 ? n - 1 : idx - 1)
            }
            return out
        }
    }

    /// tess/stroke_plotter.zig: a path's outline as polygon contours (outer side forward, inner side
    /// backward), joined at corners, capped at open ends; curves flattened with round joins.
    struct Stroker {
        let width: Double, cap: Cap, join: Join, ctm: Translation, scale: Double
        var pen: Pen?
        var points = Points(split: 2, capacity: 5), clockwise: Bool?
        var result = Polygon(), outer: [Point] = [], inner: [Point] = []   // inner: in plot order (it grows backward)

        init(width: Double, cap: Cap, join: Join, ctm: Translation, scale: Double) {
            (self.width, self.cap, self.join, self.ctm, self.scale) = (width, cap, join, ctm, scale)
            if join == .round || cap == .round { pen = Pen(width) }
        }

        mutating func run(_ nodes: [Node]) -> Polygon {
            for node in nodes {
                switch node {
                case .move(let p):
                    if !points.items.isEmpty { finish() }
                    points.items = [p]
                case .line(let p): line(join, p)
                case .curve(let b, let c, let d):
                    if pen == nil { pen = Pen(width) }
                    Sprite.flatten(points.items.last!, b, c, d, Sprite.tolerance) { line(.round, $0) }
                case .close:
                    let p = points.items
                    switch p.count {
                    case 0: break
                    case 1: dot(p[0])
                    case 2: single(p[0], p[1])
                    default:
                        let (p1, p2) = (points.tail(2), points.tail(1))
                        if p2 != p[0] {
                            corner(join, p1, p2, p[0])
                            corner(join, p2, p[0], p[1])
                        } else { corner(join, p1, p[0], p[1]) }
                        emit([outer, inner.reversed()])
                    }
                    points.items = []
                }
            }
            finish()
            return result
        }

        mutating func line(_ mode: Join, _ p: Point) {
            guard points.items.last! != p else { return }
            points.add(p)
            if points.items.count > 2 { corner(mode, points.tail(3), points.tail(2), points.tail(1)) }
        }

        mutating func finish() {
            let p = points.items
            if p.count == 2 { single(p[0], p[1]) }
            guard p.count > 2 else { return }
            let (start, end) = (Face(p[0], p[1], width, ctm), Face(points.tail(2), points.tail(1), width, ctm))
            let cw = clockwise ?? true
            outer = scaled(Face(start.p1, start.p0, width, ctm).cap(cap, cw, pen)) + outer + scaled(end.cap(cap, cw, pen)) + inner.reversed()
            emit([outer])
        }

        /// A closed path of one point: a round dot.
        mutating func dot(_ p: Point) {
            guard cap == .round, let pen else { return }
            emit([scaled(pen.points.map { Point(x: p.x + $0.x, y: p.y + $0.y) })])
        }

        mutating func single(_ a: Point, _ b: Point) {
            let f = Face(a, b, width, ctm)
            emit([scaled(Face(b, a, width, ctm).cap(cap, true, pen) + f.cap(cap, true, pen))])
        }

        mutating func emit(_ contours: [[Point]]) {
            for c in contours { result.add(contour: c) }
            (outer, inner, clockwise) = ([], [], nil)
        }

        func scaled(_ p: [Point]) -> [Point] { p.map { Point(x: $0.x * scale, y: $0.y * scale) } }

        /// join: the corner at p1 between p0-p1 and p1-p2 (miter within the limit, else bevel; or round).
        /// Consecutive points are never equal here (lines that don't move are dropped).
        mutating func corner(_ mode: Join, _ p0: Point, _ p1: Point, _ p2: Point) {
            let (a, b) = (Face(p0, p1, width, ctm), Face(p1, p2, width, ctm))
            let turn = a.slope.compare(b.slope), cw = turn < 0
            let poly = clockwise ?? cw
            var (out, inn) = ([Point](), [Point]())
            if turn == 0 {
                out = [cw ? a.p1ccw : a.p1cw]
                inn = [cw ? a.p1cw : a.p1ccw]
            } else {
                if mode == .round, let pen {
                    out = [cw ? a.p1ccw : a.p1cw] + pen.vertices(from: a.slope, to: b.slope, clockwise: cw).map { Point(x: p1.x + $0.x, y: p1.y + $0.y) }
                        + [cw ? b.p0ccw : b.p0cw]
                } else if Sprite.miterFits(a.slope, b.slope) {
                    out = [a.intersect(b, cw)]
                } else {
                    out = [cw ? a.p1ccw : a.p1cw, cw ? b.p0ccw : b.p0cw]
                }
                inn = [cw ? a.p1cw : a.p1ccw, p1, cw ? b.p0cw : b.p0ccw]
            }
            // A corner turning against the path's direction swaps the sides.
            if cw != poly { swap(&out, &inn) }
            outer += scaled(out)
            inner += scaled(inn)
            if clockwise == nil { clockwise = poly }
        }
    }

    /// Slope.compare_for_miter_limit with the limit 10: whether a miter tip stays short enough.
    static func miterFits(_ a: Slope, _ b: Slope) -> Bool {
        let (i, o) = (a.normalized, b.normalized)
        return 2 <= 10.0 * 10.0 * (1 + (i.dx * o.dx + i.dy * o.dy))
    }
}

extension Sprite {
    /// path_fx/offset.zig: each contour moved sideways by `offset` (negative: inward for Ghostty's
    /// shapes); corners go where the moved sides meet. Curves are flattened first.
    static func offset(_ nodes: [Node], by offset: Double) -> [Node] {
        var result = Path()
        for c in contours(nodes) {
            let s = c.segments
            let pts: [Point]
            if c.closed {
                // (z2d starts from the leftmost segment: the same polygon.)
                let cw = s[0].orientation == 1
                pts = [corner(s[s.count - 1], s[0], offset, cw)] + (1..<s.count).map { corner(s[$0 - 1], s[$0], offset, cw) }
            } else if s[0].orientation == 0 {
                pts = [side(s[0].p0, s[0].slope, offset, true), side(s[0].p1, s[0].slope, offset, true)]
            } else {
                let cw = s[0].orientation == 1
                pts = [side(s[0].p0, s[0].slope, offset, cw)] + (1..<s.count).map { corner(s[$0 - 1], s[$0], offset, cw) }
                    + [side(s[s.count - 1].p1, s[s.count - 1].slope, offset, cw)]
            }
            // OutputSet.recordPath
            guard pts.count > 1 else { continue }
            result.move(pts[0].x, pts[0].y)
            for p in pts.dropFirst() { result.line(p.x, p.y) }
            if c.closed { result.close() }
        }
        return result.nodes
    }

    /// InputSet segment: a line with its unit direction and which way the path turns into it
    /// (1 clockwise, -1 counterclockwise, 0 not known).
    struct Segment {
        var p0: Point, p1: Point, slope: Slope, orientation = 0
        init(_ p0: Point, _ p1: Point) {
            (self.p0, self.p1) = (p0, p1)
            let (dx, dy) = (p1.x - p0.x, p1.y - p0.y)
            if dx == 0 { slope = Slope(dx: 0, dy: dy > 0 ? 1 : -1) } else if dy == 0 { slope = Slope(dx: dx > 0 ? 1 : -1, dy: 0) } else {
                let mag = Sprite.hypot(dx, dy)
                slope = Slope(dx: dx / mag, dy: dy / mag)
            }
        }
        /// InputSet Slope.compare: the turn from this segment to `b` (no tie breaks).
        func turn(_ b: Segment) -> Int {
            let snap = { (a: Double, b: Double) in abs(b - a) > Double.ulpOfOne ? b : a }
            let v = slope.dy * snap(slope.dx, b.slope.dx) - snap(slope.dy, b.slope.dy) * slope.dx
            return v > 0 ? 1 : v < 0 ? -1 : 0
        }
    }

    /// InputSet.fromNodes: the path's contours as segments; straight continuations merge.
    static func contours(_ nodes: [Node]) -> [(segments: [Segment], closed: Bool)] {
        var (out, segs, points) = ([(segments: [Segment], closed: Bool)](), [Segment](), Points(split: 1, capacity: 2))
        // Contour.plot: a segment turning -1 is clockwise; no turn extends the last segment.
        func plot(_ p: Point) {
            var s = Segment(segs[segs.count - 1].p1, p)
            let t = segs[segs.count - 1].turn(s)
            guard t != 0 else { segs[segs.count - 1].p1 = p; return }
            s.orientation = -t
            if segs.count == 1 { segs[0].orientation = s.orientation }
            segs.append(s)
        }
        let line = { (p: Point) in
            guard let last = points.items.last, last != p else { return }
            if segs.isEmpty { segs = [Segment(last, p)] } else { plot(p) }
            points.add(p)
        }
        for (i, node) in nodes.enumerated() {
            switch node {
            case .move(let p):
                if !segs.isEmpty {
                    out.append((segs, false))
                    (segs, points.items) = ([], [])
                }
                if i == nodes.count - 1 { break }
                points.add(p)
            case .line(let p): line(p)
            case .curve(let b, let c, let d): flatten(points.items.last!, b, c, d, tolerance, line)
            case .close:
                guard points.items.count >= 2 else { continue }
                // Contour.close: a segment back to the start unless already there.
                let (last, first) = (segs[segs.count - 1], segs[0])
                if last.p1 != first.p0 {
                    var s = Segment(last.p1, first.p0)
                    let t = last.turn(s)
                    if t == 0 { segs[segs.count - 1].p1 = first.p0 } else {
                        s.orientation = -t
                        segs.append(s)
                    }
                }
                segs[0].orientation = segs[segs.count - 1].turn(segs[0]) < 0 ? 1 : -1
                out.append((segs, true))
                (segs, points.items) = ([], [])
            }
        }
        if !segs.isEmpty { out.append((segs, false)) }
        return out
    }

    /// offset.zig intersect: where the two segments' moved lines cross.
    static func corner(_ a: Segment, _ b: Segment, _ offset: Double, _ cw: Bool) -> Point {
        let (p, q) = (side(a.p1, a.slope, offset, cw), side(b.p0, b.slope, offset, cw))
        let (dx1, dy1, dx2, dy2) = (a.slope.dx, a.slope.dy, b.slope.dx, b.slope.dy)
        let t = ((q.x - p.x) * dy2 - (q.y - p.y) * dx2) / (dx1 * dy2 - dy1 * dx2)
        return Point(x: p.x + t * dx1, y: p.y + t * dy1)
    }

    /// offset.zig offsetSingle: a point moved sideways from a direction.
    static func side(_ p: Point, _ s: Slope, _ offset: Double, _ cw: Bool) -> Point {
        let (ox, oy) = (-s.dy * offset, s.dx * offset)
        return cw ? Point(x: p.x - ox, y: p.y - oy) : Point(x: p.x + ox, y: p.y + oy)
    }
}
