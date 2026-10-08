// Ghostty's glyph atlas (font/Atlas.zig): a square texture where glyphs are packed along a skyline
// of nodes (the place whose top edge ends lowest wins, then the narrowest node), keeping a 1 pixel
// border; when full, the renderer doubles it and the old pixels move down by the border row.
// Same packing as Ghostty, so the GPU gets the same texture.

public struct Atlas {
    public static let maxSize = 2048
    public enum Format: String { case grayscale, bgr, bgra
        public var depth: Int { self == .grayscale ? 1 : self == .bgr ? 3 : 4 }
    }
    /// Public only so that the renderer module can lay out an Atlas value (Dispatch links the modules
    /// as frameworks, which export no internal types).
    public struct Node { var x: Int, y: Int, width: Int }

    public let format: Format
    public private(set) var size: Int, data: [UInt8]
    var nodes: [Node] = []
    /// Bumped on every change / growth (the renderer re-uploads the texture).
    public private(set) var modified = 0, resized = 0

    public init(size: Int, format: Format) {
        (self.size, self.format, data) = (min(max(size, 2), Self.maxSize), format, [])
        clear()
    }

    public mutating func clear() {
        modified += 1
        data = [UInt8](repeating: 0, count: size * size * format.depth)
        nodes = [Node(x: 1, y: 1, width: size - 2)]
    }

    /// A place for a width x height region (nil: full). An empty region is (0, 0) and takes no space.
    public mutating func reserve(_ width: Int, _ height: Int) -> (x: Int, y: Int)? {
        if width == 0 && height == 0 { return (0, 0) }
        var (chosen, bestHeight, bestWidth, region): (Int?, Int, Int, (x: Int, y: Int)) = (nil, Int(UInt32.max), Int(UInt32.max), (0, 0))
        for i in nodes.indices {
            guard let y = fit(i, width, height) else { continue }
            let n = nodes[i]
            if y + height < bestHeight || y + height == bestHeight && n.width > 0 && n.width < bestWidth {
                (chosen, bestWidth, bestHeight, region) = (i, n.width, y + height, (n.x, y))
            }
        }
        guard let best = chosen else { return nil }
        nodes.insert(Node(x: region.x, y: region.y + height, width: width), at: best)
        // The nodes right of it lose what the new one covers.
        let i = best + 1
        while i < nodes.count {
            let prev = nodes[i - 1]
            guard nodes[i].x < prev.x + prev.width else { break }
            let shrink = prev.x + prev.width - nodes[i].x
            nodes[i].x += shrink
            nodes[i].width = max(nodes[i].width - shrink, 0)
            guard nodes[i].width == 0 else { break }
            nodes.remove(at: i)
        }
        // Neighbors at the same height become one node.
        var j = 0
        while j < nodes.count - 1 {
            if nodes[j].y == nodes[j + 1].y { nodes[j].width += nodes.remove(at: j + 1).width } else { j += 1 }
        }
        return region
    }

    /// The y where a region fits on node `idx` and the nodes it spans, nil when it leaves the atlas.
    func fit(_ idx: Int, _ width: Int, _ height: Int) -> Int? {
        if nodes[idx].x + width > size - 1 { return nil }
        var (y, i, left) = (nodes[idx].y, idx, width)
        while left > 0 {
            y = max(y, nodes[i].y)
            if y + height > size - 1 { return nil }
            left = max(left - nodes[i].width, 0)
            i += 1
        }
        return y
    }

    /// Copies `pixels` (rows of width x depth bytes, starting at row `from`) into a region.
    public mutating func set(x: Int, y: Int, width: Int, height: Int, _ pixels: [UInt8], from: Int = 0) {
        let d = format.depth, row = width * d
        for r in 0..<height {
            let at = ((y + r) * size + x) * d, src = (from + r) * row
            data.replaceSubrange(at..<at + row, with: pixels[src..<src + row])
        }
        modified += 1
    }

    /// Atlas.grow: a bigger texture with the old one's rows 1...size-2 at the same place (x from 0),
    /// the new space as one node on the right.
    public mutating func grow(to newSize: Int) {
        let newSize = min(max(newSize, size), Self.maxSize)
        guard newSize > size else { return }
        let (old, oldSize) = (data, size)
        (size, data) = (newSize, [UInt8](repeating: 0, count: newSize * newSize * format.depth))
        set(x: 0, y: 1, width: oldSize, height: oldSize - 2, old, from: 1)
        nodes.append(Node(x: oldSize - 1, y: 1, width: newSize - oldSize))
        (modified, resized) = (modified + 1, resized + 1)
    }
}
