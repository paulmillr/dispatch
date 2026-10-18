import Foundation

/// Program output for tests, previews and benchmarks: the M6a screen, full-screen programs drawn the way `vim` and
/// `htop` draw (alternate screen, absolute cursor moves, SGR colours), vttest-style checks of the emulator's basics,
/// and a large file as `cat` writes it. Colours are the `dispatch` palette's ANSI indices where the mockup uses
/// them (green 2, yellow 3, blue 4, grey 8) and true colour for the mockup's greys outside the palette.
enum TerminalFixtures {
    static let esc = "\u{1B}"
    static func csi(_ body: String) -> String { esc + "[" + body }
    static func sgr(_ codes: String) -> String { csi(codes + "m") }
    static let reset = sgr("0")
    /// The mockup's dim grey (#6f6f78) and white (#fff), which the palette does not have.
    static let dim = sgr("38;2;111;111;120")
    static let white = sgr("38;2;255;255;255")

    static func data(_ text: String) -> Data { Data(text.utf8) }

    /// The mockup's terminal (M6a): a prompt, `pnpm dev` and vite's output, the cursor on a fresh line.
    static var viteDev: Data {
        let green = sgr("32"), yellow = sgr("33"), blue = sgr("34"), grey = sgr("90")
        let hmr = { (time: String, file: String) in "  \(grey)\(time)\(reset) \(green)hmr\(reset) update \(file)\r\n" }
        var s = "\(green)~/src/app\(reset) \(dim)$\(reset) \(white)pnpm dev\(reset)\r\n\r\n"
        s += "  \(dim)vite\(reset) v6.1.0  ready in \(yellow)412\(reset) ms\r\n"
        s += "  \(dim)➜\(reset)  Local:   \(blue)http://localhost:5173/\(reset)\r\n"
        s += "  \(dim)➜\(reset)  Network: \(blue)http://10.0.0.12:5173/\(reset)\r\n\r\n"
        s += hmr("09:01:52", "src/routes/billing.ts")
        s += hmr("09:02:08", "src/lib/stripe.ts")
        s += "  \(grey)09:02:11\(reset) \(yellow)warn\(reset) stripe-retry-count header\r\n           is deprecated\r\n"
        s += hmr("09:37:40", "src/lib/idempotent.ts")
        s += hmr("09:37:41", "src/routes/invoices.ts")
        return data(s)
    }

    /// A `vim`-like screen at `columns` x `rows`: the alternate screen, numbered Swift source with syntax colours,
    /// `~` past the end, the reversed status line and `-- INSERT --`, the cursor in the text.
    static func vim(columns: Int, rows: Int) -> Data {
        let source: [[(String, String?)]] = [
            [("import", "35"), (" Foundation", nil)],
            [],
            [("/// Retries a request with jitter.", "90;3")],
            [("struct", "35"), (" ", nil), ("Retry", "34"), (" {", nil)],
            [("    let", "35"), (" attempts: ", nil), ("Int", "34")],
            [("    let", "35"), (" base: ", nil), ("Duration", "34"), (" = .", nil), ("milliseconds", nil), ("(", nil), ("200", "33"), (")", nil)],
            [],
            [("    func", "35"), (" delay(", nil), ("for", "35"), (" n: ", nil), ("Int", "34"), (") -> ", nil), ("Duration", "34"), (" {", nil)],
            [("        base * ", nil), ("Double", "34"), ("(", nil), ("1", "33"), (" << n) * .random(in: ", nil), ("0.5", "33"), ("...", nil), ("1.5", "33"), (")", nil)],
            [("    }", nil)],
            [("}", nil)],
            [],
            [("let", "35"), (" header = ", nil), ("\"stripe-retry-count\"", "32")],
        ]
        var s = csi("?1049h") + csi("H") + csi("2J")
        let textRows = max(1, rows - 2)
        for y in 0..<textRows {
            s += csi("\(y + 1);1H")
            if y < source.count {
                let number = String(y + 1)
                var line = sgr("90") + String(repeating: " ", count: max(0, 3 - number.count)) + number + " " + reset
                var width = 4
                for (text, codes) in source[y] {
                    let visible = String(text.prefix(max(0, columns - width)))
                    width += visible.count
                    line += codes.map { sgr($0) + visible + reset } ?? visible
                }
                s += line
            } else {
                s += sgr("34") + "~" + reset
            }
        }
        let name = " Sources/App/Retry.swift [+]"
        let position = "9,21          All "
        let gap = max(1, columns - name.count - position.count)
        s += csi("\(rows - 1);1H") + sgr("7") + String((name + String(repeating: " ", count: gap) + position).prefix(columns)) + reset
        s += csi("\(rows);1H") + sgr("1") + "-- INSERT --" + reset
        s += csi("9;25H")
        return data(s)
    }

    /// An `htop`-like screen at `columns` x `rows`: CPU and memory meters, the process table with its green header
    /// and a selected row, the function-key bar.
    static func htop(columns: Int, rows: Int) -> Data {
        let barWidth = max(8, columns / 2 - 8)
        func meter(_ label: String, _ fraction: Double, _ text: String) -> String {
            let filled = Int((Double(barWidth) * fraction).rounded())
            let green = filled * 2 / 3, red = filled - green
            let pad = max(0, barWidth - filled - text.count)
            return sgr("36") + label + reset + sgr("1") + "[" + reset + sgr("32") + String(repeating: "|", count: green) + reset
                + sgr("31") + String(repeating: "|", count: red) + reset + String(repeating: " ", count: pad) + sgr("90") + text + reset
                + sgr("1") + "]" + reset
        }
        func clip(_ line: String, _ width: Int) -> String {
            line.count >= width ? String(line.prefix(width)) : line + String(repeating: " ", count: width - line.count)
        }
        var s = csi("?1049h") + csi("?25l") + csi("H") + csi("2J")
        let side = [("Tasks: ", "142, 581 thr; 2 running"), ("Load average: ", "1.42 1.10 0.98"), ("Uptime: ", "3 days, 04:12:55")]
        let meters = [meter("  0", 0.45, "45.2%"), meter("  1", 0.21, "21.0%"), meter("Mem", 0.42, "3.21G/7.63G"), meter("Swp", 0, "0K/2.00G")]
        for (y, line) in meters.enumerated() {
            s += csi("\(y + 1);1H") + line
            if y < side.count, columns > barWidth + 14 {
                s += csi("\(y + 1);\(barWidth + 10)H") + sgr("36") + side[y].0 + reset + sgr("1") + String(side[y].1.prefix(max(0, columns - barWidth - 9 - side[y].0.count))) + reset
            }
        }
        let header = "  PID USER       CPU% MEM%   TIME+  Command"
        s += csi("6;1H") + sgr("30;42") + clip(header, columns) + reset
        let processes = [
            (" 4211", "paul", "12.3", " 2.7", " 1:02.33", "node vite"),
            (" 3807", "paul", " 8.1", " 5.9", "12:40.07", "claude"),
            ("  912", "root", " 2.0", " 0.4", " 9:12.51", "dockerd"),
            (" 4302", "paul", " 1.3", " 0.2", " 0:03.88", "htop"),
            ("    1", "root", " 0.0", " 0.1", " 0:04.12", "/sbin/init"),
            ("  644", "root", " 0.0", " 0.3", " 0:21.40", "sshd: /usr/sbin/sshd"),
            (" 2210", "paul", " 0.0", " 0.6", " 0:00.91", "tmux new -s app"),
            (" 2211", "paul", " 0.0", " 0.1", " 0:00.12", "-zsh"),
        ]
        for (i, p) in processes.enumerated() where 7 + i < rows {
            let line = "\(p.0) \(p.1.padding(toLength: 10, withPad: " ", startingAt: 0)) \(p.2) \(p.3) \(p.4)  \(p.5)"
            s += csi("\(7 + i);1H") + (i == 0 ? sgr("30;46") + clip(line, columns) + reset : clip(line, columns))
        }
        var keys = ""
        var width = 0
        for (key, label) in [("F1", "Help  "), ("F2", "Setup "), ("F3", "Search"), ("F5", "Tree  "), ("F6", "SortBy"), ("F9", "Kill  "), ("F10", "Quit")] {
            guard width + key.count + label.count <= columns else { break }
            keys += sgr("0") + key + sgr("30;46") + label + reset
            width += key.count + label.count
        }
        s += csi("\(rows);1H") + keys + sgr("30;46") + String(repeating: " ", count: max(0, columns - width)) + reset
        return data(s)
    }

    /// DECALN (`ESC # 8`): every cell an `E`, the cursor home.
    static let screenAlignment = data(esc + "#8")
    /// Absolute and relative cursor moves, each leaving a marker: `A` at (0,0), `B` at (9,4), `C` at (4,1), `D` at (2,5).
    static let cursorMoves = data(csi("H") + "A" + csi("5;10H") + "B" + csi("3A") + csi("6D") + "C" + csi("4B") + csi("3D") + "D")
    /// A scroll region of rows 2-4: line feeds at its bottom scroll only it; rows 1 and 5 stay.
    static let scrollRegion = data(csi("H") + "top" + csi("5;1H") + "bottom" + csi("2;4r") + csi("2;1H") + "one\r\ntwo\r\nthree\r\nfour" + csi("r"))
    /// Autowrap: `columns + 3` characters fill a row and wrap three onto the next.
    static func autowrap(columns: Int) -> Data { data(csi("H") + String(repeating: "x", count: columns) + "abc") }
    /// Erase in line from the cursor (EL 0) and insert/delete characters (ICH, DCH).
    static let eraseInsertDelete = data(csi("H") + "0123456789" + csi("1;5H") + csi("K") + csi("2;1H") + "abcdef" + csi("2;3H") + csi("2@")
                                        + csi("3;1H") + "abcdef" + csi("3;2H") + csi("2P"))
    /// SGR: bold, palette red, 256-colour 196, true colour, inverse; then reset.
    static let colours = data(sgr("1") + "B" + reset + sgr("31") + "R" + reset + sgr("38;5;196") + "P" + reset
                              + sgr("38;2;1;2;3") + "T" + reset + sgr("7") + "I" + reset + "N")
    /// Wide characters take two cells each.
    static let wide = data(csi("H") + "漢字ab")
    /// The alternate screen keeps the primary screen's text for its return.
    static let alternateScreen = data(csi("H") + "primary" + csi("?1049h") + csi("H") + csi("2J") + "alternate")
    static let alternateScreenExit = data(csi("?1049l"))

    /// `count` bytes of a source file as `cat` writes it: numbered lines of about 80 columns, LF only (the pty's
    /// ONLCR is the multiplexer's, so the emulator sees CR LF).
    static func largeFile(bytes count: Int) -> Data {
        var out = Data()
        out.reserveCapacity(count + 128)
        var n = 0
        let words = ["let", "value", "=", "compute(index:", "request", "await", "response.body", "// keep the order", "guard", "else",
                     "return", "try", "decoder.decode(Page.self,", "from:", "data)", "if", "cache[key]", "!=", "nil", "{", "}"]
        while out.count < count {
            n += 1
            var line = String(format: "%6d  ", n)
            var i = n
            while line.count < 72 {
                line += words[Int(UInt(bitPattern: i) % UInt(words.count))] + " "
                i = i &* 31 &+ 7
            }
            out.append(contentsOf: Array(line.utf8))
            out.append(contentsOf: [0x0D, 0x0A])
        }
        return out.prefix(count)
    }
}
