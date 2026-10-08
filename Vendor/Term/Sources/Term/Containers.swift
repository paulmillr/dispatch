// The page's own containers, inside the page block (Ghostty's
// ref_counted_set.zig, bitmap_allocator.zig, hash_map.zig). Where they report
// "full" decides when a page grows, which the scrollback byte limit sees; so
// the rules that decide that are Ghostty's exactly.
//
// A container is a view: offsets into its page's memory plus a pointer to its
// few counters, which live in the same block after Ghostty's layout (not counted
// by the byte limit). So containers are immutable values: no copy-on-write, no
// reference counting and no exclusivity checks when the page uses them.

enum PageFull: Error { case outOfMemory, needsRehash }

/// What a ref-counted set needs to know about its values.
protocol SetContext {
    associatedtype Value: BitwiseCopyable
    func hash(_ v: Value) -> UInt64
    func eql(_ a: Value, _ b: Value) -> Bool
    func deleted(_ v: Value)
}

/// Values with stable ids and reference counts; a robin-hood table (hash -> id)
/// finds existing values. Item = value, then bucket, psl, ref (u16 each) at the end.
struct RefCountedSet<Value: BitwiseCopyable> {
    struct Counters { var maxPSL = 0, living = 0, nextID = 1 }
    static var stateBytes: Int { MemoryLayout<Counters>.stride + 32 * MemoryLayout<Int>.stride }
    let layout: SetLayout, table: Int, items: Int, stride: Int
    let counters: UnsafeMutablePointer<Counters>, pslStats: UnsafeMutablePointer<Int>
    var maxPSL: Int { get { counters.pointee.maxPSL } nonmutating set { counters.pointee.maxPSL = newValue } }
    var living: Int { get { counters.pointee.living } nonmutating set { counters.pointee.living = newValue } }
    var nextID: Int { get { counters.pointee.nextID } nonmutating set { counters.pointee.nextID = newValue } }

    init(_ m: UnsafeMutableRawPointer, at start: Int, _ layout: SetLayout, stride: Int, state: UnsafeMutableRawPointer) {
        (self.layout, table, items, self.stride) = (layout, start + layout.tableStart, start + layout.itemsStart, stride)
        counters = state.bindMemory(to: Counters.self, capacity: 1)
        counters.initialize(to: Counters())
        pslStats = (state + MemoryLayout<Counters>.stride).bindMemory(to: Int.self, capacity: 32)
        pslStats.initialize(repeating: 0, count: 32)
        for id in 0..<layout.cap { reset(m, id) }
    }

    private func meta(_ id: Int, _ field: Int) -> Int { items + id * stride + stride - 6 + 2 * field }
    func bucket(_ m: UnsafeMutableRawPointer, _ id: Int) -> Int { Int(m.load(fromByteOffset: meta(id, 0), as: UInt16.self)) }
    func psl(_ m: UnsafeMutableRawPointer, _ id: Int) -> Int { Int(m.load(fromByteOffset: meta(id, 1), as: UInt16.self)) }
    func refCount(_ m: UnsafeMutableRawPointer, _ id: Int) -> Int { Int(m.load(fromByteOffset: meta(id, 2), as: UInt16.self)) }
    func setMeta(_ m: UnsafeMutableRawPointer, _ id: Int, _ field: Int, _ v: Int) { m.storeBytes(of: UInt16(v), toByteOffset: meta(id, field), as: UInt16.self) }
    func get(_ m: UnsafeMutableRawPointer, _ id: Int) -> Value { m.loadUnaligned(fromByteOffset: items + id * stride, as: Value.self) }
    func slot(_ m: UnsafeMutableRawPointer, _ p: Int) -> Int { Int(m.load(fromByteOffset: table + 2 * p, as: UInt16.self)) }
    func setSlot(_ m: UnsafeMutableRawPointer, _ p: Int, _ id: Int) { m.storeBytes(of: UInt16(id), toByteOffset: table + 2 * p, as: UInt16.self) }
    private func reset(_ m: UnsafeMutableRawPointer, _ id: Int) { setMeta(m, id, 0, 0xFFFF); setMeta(m, id, 1, 0); setMeta(m, id, 2, 0) }

    func use(_ m: UnsafeMutableRawPointer, _ id: Int, _ n: Int = 1) { setMeta(m, id, 2, refCount(m, id) + n) }
    func release(_ m: UnsafeMutableRawPointer, _ id: Int, _ n: Int = 1) {
        setMeta(m, id, 2, refCount(m, id) - n)
        if refCount(m, id) == 0 { living -= 1 }
    }

    func add<C: SetContext>(_ m: UnsafeMutableRawPointer, _ v: Value, _ ctx: C) throws(PageFull) -> Int where C.Value == Value {
        while nextID > 1, refCount(m, nextID - 1) == 0 { nextID -= 1; delete(m, nextID, ctx) }
        if let id = lookup(m, v, ctx) { ctx.deleted(v); use(m, id); return id }
        if pslStats[31] > 0 { throw .outOfMemory }
        if nextID >= layout.cap { throw living < Int(Double(layout.cap) * 0.9) ? .needsRehash : .outOfMemory }
        let id = insert(m, v, nextID, ctx)
        use(m, id)
        living += 1
        if id == nextID { nextID += 1 }
        return id
    }

    /// Add wanting a specific id (page clones keep ids); nil = got that id.
    func add<C: SetContext>(_ m: UnsafeMutableRawPointer, _ v: Value, id: Int, _ ctx: C) throws(PageFull) -> Int? where C.Value == Value {
        if id < nextID {
            if refCount(m, id) == 0 {
                if let e = lookup(m, v, ctx) { ctx.deleted(v); use(m, e); return e }
                if pslStats[31] > 0 { throw .outOfMemory }
                delete(m, id, ctx)
                let added = insert(m, v, id, ctx)
                use(m, added)
                living += 1
                return added == id ? nil : added
            }
            if ctx.eql(v, get(m, id)) { ctx.deleted(v); use(m, id); return nil }
        }
        return try add(m, v, ctx)
    }

    func lookup<C: SetContext>(_ m: UnsafeMutableRawPointer, _ v: Value, _ ctx: C) -> Int? where C.Value == Value {
        guard layout.tableCap > 0 else { return nil }
        let h = ctx.hash(v)
        for i in 0...maxPSL {
            let id = slot(m, Int(truncatingIfNeeded: (h &+ UInt64(i)) & UInt64(layout.tableMask)))
            if id == 0 || psl(m, id) < i { return nil }
            if psl(m, id) == i, refCount(m, id) > 0, ctx.eql(v, get(m, id)) { return id }
        }
        return nil
    }

    private func insert<C: SetContext>(_ m: UnsafeMutableRawPointer, _ v: Value, _ newID: Int, _ ctx: C) -> Int where C.Value == Value {
        let h = ctx.hash(v)
        // The held item: the new one first, then whichever item it displaced.
        var (held, heldPSL, heldRef, chosen, newBucket, newPSL) = (newID, 0, 0, newID, 0, 0)
        for i in 0..<layout.tableCap - 1 {
            let p = Int(truncatingIfNeeded: (h &+ UInt64(i)) & UInt64(layout.tableMask)), id = slot(m, p)
            if id == 0 { place(m, p, held, heldPSL, newID, &newBucket, &newPSL); break }
            if refCount(m, id) == 0 {
                ctx.deleted(get(m, id))
                pslStats[psl(m, id)] -= 1
                reset(m, id)
                if id < newID { chosen = id }
                place(m, p, held, heldPSL, newID, &newBucket, &newPSL)
                break
            }
            if psl(m, id) < heldPSL || psl(m, id) == heldPSL && refCount(m, id) < heldRef {
                let displaced = (id, psl(m, id), refCount(m, id))
                place(m, p, held, heldPSL, newID, &newBucket, &newPSL)
                (held, heldPSL, heldRef) = displaced
                pslStats[heldPSL] -= 1
            }
            heldPSL += 1
        }
        setSlot(m, newBucket, chosen)
        m.storeBytes(of: v, toByteOffset: items + chosen * stride, as: Value.self)
        setMeta(m, chosen, 0, newBucket); setMeta(m, chosen, 1, newPSL); setMeta(m, chosen, 2, 0)
        return chosen
    }

    /// Puts the held item into bucket p (the new item only records where it went).
    private func place(_ m: UnsafeMutableRawPointer, _ p: Int, _ held: Int, _ heldPSL: Int, _ newID: Int, _ newBucket: inout Int, _ newPSL: inout Int) {
        precondition(heldPSL < 32)   // add() throws before a probe sequence can get this long
        setSlot(m, p, held)
        if held == newID { (newBucket, newPSL) = (p, heldPSL) } else { setMeta(m, held, 0, p); setMeta(m, held, 1, heldPSL) }
        pslStats[heldPSL] += 1
        maxPSL = max(maxPSL, heldPSL)
    }

    private func delete<C: SetContext>(_ m: UnsafeMutableRawPointer, _ id: Int, _ ctx: C) where C.Value == Value {
        let b = bucket(m, id)
        guard b <= layout.tableCap else { return }
        ctx.deleted(get(m, id))
        pslStats[psl(m, id)] -= 1
        setSlot(m, b, 0)
        reset(m, id)
        // Backward shift: pull following entries one slot closer to home.
        var (p, n) = (b, (b + 1) & layout.tableMask)
        while slot(m, n) != 0, psl(m, slot(m, n)) > 0 {
            let moved = slot(m, n)
            pslStats[psl(m, moved)] -= 1
            setMeta(m, moved, 0, p); setMeta(m, moved, 1, psl(m, moved) - 1)
            pslStats[psl(m, moved)] += 1
            setSlot(m, p, moved)
            (p, n) = (n, (n + 1) & layout.tableMask)
        }
        while maxPSL > 0, pslStats[maxPSL] == 0 { maxPSL -= 1 }
        setSlot(m, p, 0)
    }
}

/// First-fit allocator of fixed-size chunks; one bit per chunk (1 = free).
struct BitmapAllocator {
    let bitmap: Int, count: Int, chunks: Int, chunk: Int
    let state: UnsafeMutablePointer<Int>
    var searchStart: Int { get { state.pointee } nonmutating set { state.pointee = newValue } }

    init(_ m: UnsafeMutableRawPointer, at start: Int, _ l: AllocLayout, chunk: Int, state: UnsafeMutableRawPointer) {
        (bitmap, count, chunks, self.chunk) = (start + l.bitmapStart, l.bitmapCount, start + l.chunksStart, chunk)
        self.state = state.bindMemory(to: Int.self, capacity: 1)
        self.state.initialize(to: 0)
        for i in 0..<count { setWord(m, i, ~0) }
    }

    func word(_ m: UnsafeMutableRawPointer, _ i: Int) -> UInt64 { m.load(fromByteOffset: bitmap + 8 * i, as: UInt64.self) }
    func setWord(_ m: UnsafeMutableRawPointer, _ i: Int, _ v: UInt64) { m.storeBytes(of: v, toByteOffset: bitmap + 8 * i, as: UInt64.self) }
    func chunks(bytes: Int) -> Int { (bytes + chunk - 1) / chunk }

    /// Byte offset (from the page start) of `bytes` bytes, or nil when no run of free chunks fits.
    func alloc(_ m: UnsafeMutableRawPointer, bytes: Int) -> Int? {
        let n = chunks(bytes: bytes), start = min(searchStart, count)
        guard let rel = findFree(m, from: start, n) else { return nil }
        searchStart = start
        while searchStart < count, word(m, searchStart) == 0 { searchStart += 1 }
        return chunks + (start * 64 + rel) * chunk
    }

    func free(_ m: UnsafeMutableRawPointer, at offset: Int, bytes: Int) {
        let index = (offset - chunks) / chunk
        searchStart = min(searchStart, index / 64)
        for c in index..<index + chunks(bytes: bytes) { setWord(m, c / 64, word(m, c / 64) | 1 << UInt64(c % 64)) }
    }

    func usedBytes(_ m: UnsafeMutableRawPointer) -> Int {
        (0..<count).reduce(count * 64) { $0 - word(m, $1).nonzeroBitCount } * chunk
    }

    /// Ghostty's findFreeChunks over words [from, count) for runs of at most 64 chunks (graphemes
    /// need <= 16, strings <= 64: OSC capture limit), so its multi-word path is not needed.
    private func findFree(_ m: UnsafeMutableRawPointer, from: Int, _ n: Int) -> Int? {
        precondition(n <= 64)
        for i in from..<count {
            let w = word(m, i), fits = (1..<n).reduce(w) { $0 & w >> UInt64($1) }
            if fits == 0 { continue }
            let bit = fits.trailingZeroBitCount
            setWord(m, i, w ^ ((~0 >> UInt64(64 - n)) << UInt64(bit)))
            return (i - from) * 64 + bit
        }
        return nil
    }
}

/// Open addressing map from a cell's byte offset to a small value; linear probing,
/// backward-shift deletion. Only its fullness rule is Ghostty's (count <= capacity * load%).
struct OffsetMap<Value: BitwiseCopyable> {
    let meta: Int, keys: Int, vals: Int, capacity: Int, maxLoad: Int
    let state: UnsafeMutablePointer<Int>
    var count: Int { get { state.pointee } nonmutating set { state.pointee = newValue } }

    init(_ m: UnsafeMutableRawPointer, at start: Int, _ l: MapLayout, load: Int, state: UnsafeMutableRawPointer) {
        (meta, keys, vals, capacity) = (start + 16, start + 16 + l.keysStart, start + 16 + l.valsStart, l.capacity)
        maxLoad = capacity * load / 100
        self.state = state.bindMemory(to: Int.self, capacity: 1)
        self.state.initialize(to: 0)
    }

    private func used(_ m: UnsafeMutableRawPointer, _ i: Int) -> Bool { m.load(fromByteOffset: meta + i, as: UInt8.self) != 0 }
    private func key(_ m: UnsafeMutableRawPointer, _ i: Int) -> UInt32 { m.load(fromByteOffset: keys + 4 * i, as: UInt32.self) }
    private func home(_ k: UInt32) -> Int { Int(truncatingIfNeeded: mx3(UInt64(k))) & (capacity - 1) }

    /// Slots from k's home on, at most one round (a 100% map can be completely full).
    private func probe(_ k: UInt32) -> LazyMapSequence<Range<Int>, Int> { let h = home(k); return (0..<capacity).lazy.map { (h + $0) & (capacity - 1) } }

    private func index(_ m: UnsafeMutableRawPointer, _ k: UInt32) -> Int? {
        guard count > 0 else { return nil }
        for i in probe(k) { if !used(m, i) { return nil }; if key(m, i) == k { return i } }
        return nil
    }

    func get(_ m: UnsafeMutableRawPointer, _ k: UInt32) -> Value? {
        index(m, k).map { m.load(fromByteOffset: vals + $0 * MemoryLayout<Value>.stride, as: Value.self) }
    }

    /// Insert or replace; false when k is new and the map is full.
    func set(_ m: UnsafeMutableRawPointer, _ k: UInt32, _ v: Value) -> Bool {
        guard let i = index(m, k) ?? (count < maxLoad ? probe(k).first { !used(m, $0) } : nil) else { return false }
        if !used(m, i) {
            m.storeBytes(of: 1, toByteOffset: meta + i, as: UInt8.self)
            m.storeBytes(of: k, toByteOffset: keys + 4 * i, as: UInt32.self)
            count += 1
        }
        m.storeBytes(of: v, toByteOffset: vals + i * MemoryLayout<Value>.stride, as: Value.self)
        return true
    }

    func remove(_ m: UnsafeMutableRawPointer, _ k: UInt32) {
        guard var hole = index(m, k) else { return }
        var j = hole
        for _ in 0..<capacity - 1 {
            j = (j + 1) & (capacity - 1)
            if !used(m, j) { break }
            let h = home(key(m, j))
            if (hole &- h) & (capacity - 1) < (j &- h) & (capacity - 1) {
                m.storeBytes(of: key(m, j), toByteOffset: keys + 4 * hole, as: UInt32.self)
                let s = MemoryLayout<Value>.stride
                m.storeBytes(of: m.load(fromByteOffset: vals + j * s, as: Value.self), toByteOffset: vals + hole * s, as: Value.self)
                hole = j
            }
        }
        m.storeBytes(of: 0, toByteOffset: meta + hole, as: UInt8.self)
        count -= 1
    }
}

/// A hash map from 64-bit keys (callers pack their fields into one) to values: open addressing,
/// linear probing, Fibonacci hashing (no SipHash per lookup), doubled at 3/4 full, never shrunk.
/// For the renderer's caches, which look up per cell and per glyph. Inlinable: other modules get
/// it specialized (unspecialized generic code instantiates metadata at run time).
@frozen public struct Map<Value> {
    @usableFromInline var slots: [(key: UInt64, value: Value)?] = Array(repeating: nil, count: 16)
    @usableFromInline var shift = 60
    @usableFromInline var used = 0
    public var count: Int { used }
    @inlinable public init() {}

    @inlinable func slot(_ key: UInt64) -> Int { Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> UInt64(shift)) }

    @inlinable public subscript(_ key: UInt64) -> Value? {
        var i = slot(key)
        while let s = slots[i] {
            if s.key == key { return s.value }
            i = (i + 1) & (slots.count - 1)
        }
        return nil
    }

    /// Sets `key` (existing or new).
    @inlinable public mutating func set(_ key: UInt64, _ value: Value) {
        if (used + 1) * 4 > slots.count * 3 { grow() }
        var i = slot(key)
        while let s = slots[i] {
            if s.key == key { slots[i] = (key, value); return }
            i = (i + 1) & (slots.count - 1)
        }
        slots[i] = (key, value)
        used += 1
    }

    /// Empties the map, keeping its capacity.
    @inlinable public mutating func clear() {
        for i in slots.indices { slots[i] = nil }
        used = 0
    }

    @inlinable mutating func grow() {
        let old = slots
        slots = Array(repeating: nil, count: old.count * 2)
        (shift, used) = (shift - 1, 0)
        for case let s? in old { set(s.key, s.value) }
    }
}
