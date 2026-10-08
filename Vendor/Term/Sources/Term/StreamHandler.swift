// The app's stream handler (Ghostty's termio/stream_handler.zig): actions
// become terminal operations, replies to the program, and messages for the
// surface. Messages are queued; the embedder drains them.

/// What the surface (the app) is told (Ghostty's apprt.surface.Message).
public enum SurfaceMessage {
    public enum Clipboard: String { case standard, selection, primary }
    public struct ClipboardWrite { public var clipboardType: Clipboard, req: [UInt8] }
    public struct ColorChange { public var target: ColorTarget, color: RGB }
    /// A program's OSC 5522 read (MIME types up to 4, `.` asks for the listing) and a committed write.
    public struct KittyClipboardRead { public var location: Clipboard, mimes: [[UInt8]], list: Bool, id: [UInt8], pw: [UInt8], name: [UInt8], granted: Bool, terminator: Terminator }
    public struct KittyClipboardWrite { public var location: Clipboard, contents: [ClipboardContent], id: [UInt8], pw: [UInt8], name: [UInt8], granted: Bool, terminator: Terminator }
    case setTitle([UInt8]), reportTitle(SizeReport), setMouseShape(MouseShape)
    case clipboardRead(Clipboard), clipboardWrite(ClipboardWrite)
    case pwdChange([UInt8]), ringBell, colorChange(ColorChange)
    case desktopNotification(Notification), progressReport(Progress)
    case startCommand, stopCommand(UInt8)
    case kittyClipboardRead(KittyClipboardRead), kittyClipboardWrite(KittyClipboardWrite)
    /// From the search (Ghostty's search thread callback).
    case searchTotal(Int?), searchSelected(Int?)
}

/// Messages for the IO side (Ghostty's termio.Message); reports are encoded when drained.
public enum TermioMessage {
    case write([UInt8]), sizeReport(SizeReportStyle), colorSchemeReport(force: Bool), visibilityReport(visible: Bool, force: Bool)
    case linefeedMode(Bool), startSynchronizedOutput, focused(Bool)
    /// From the surface: a new size (the IO thread coalesces resizes; they run at the next drain),
    /// a viewport scroll, the selection-scroll timer on or off.
    case resize(RenderSize), scrollViewport(Terminal.ViewportScroll), selectionScroll(Bool)
}

public enum SizeReportStyle { case mode2048, csi14t, csi16t, csi18t }

public struct HandlerOptions {
    public enum ColorReportFormat { case none, bits8, bits16 }
    public enum ClipboardAccess: String { case allow, deny, ask }
    public var enquiryResponse: [UInt8] = []
    public var colorReportFormat = ColorReportFormat.bits16
    /// clipboard-write (the surface reads it too); Dispatch: ask.
    public var clipboardWrite = ClipboardAccess.ask
    /// clipboard-write-limit: the most a kitty clipboard write may hold (bytes).
    public var clipboardWriteLimit = 64 << 20
    public var cellWidth = 10, cellHeight = 20
    /// This machine's name: OSC 7 accepts file URLs only for it (or localhost).
    public var hostname: [UInt8] = []
    public var version = ""
    public init() {}
}

public struct StreamHandler: Handler {
    public let terminal: Terminal
    public var options: HandlerOptions
    /// The surface's grid (size reports and mode 3 use it, not the terminal's size).
    public var gridCols: Int, gridRows: Int
    public var termio: [TermioMessage] = []
    public var surface: [SurfaceMessage] = []
    var seenTitle = false
    /// The IO side's linefeed mode, set when its message is executed (like termio's thread flag).
    var linefeedMode = false
    /// The IO side's selection-scroll timer: a stopped timer fires once more (Thread.zig).
    public enum Timer { case off, on, stopping }
    public internal(set) var selectionScrollTimer = Timer.off
    var dcs = Dcs.inactive
    /// tmux control sessions started so far (DCS 1000p hooks).
    var controls = 0
    /// APC strings: kitty graphics and the glyph protocol (apc.zig).
    var apc = APC()
    /// tmux control mode goes here (Surface.control); nil: its DCS is ignored like any unknown one.
    var control: ((Control, Int) -> Void)?
    /// Kitty clipboard: the session's password grants (a full reset drops them) and the open write.
    var grants = KittyGrants()
    var kittyWrite: KittyWrite?
    enum Dcs { case inactive, ignore, xtgettcap([UInt8]), decrqss([UInt8]), control }

    public init(terminal: Terminal, options: HandlerOptions) {
        (self.terminal, self.options) = (terminal, options)
        (gridCols, gridRows) = (terminal.cols, terminal.rows)
    }

    /// Runs the IO work queued since the last drain: replies in order (reports are encoded now)
    /// go to `reply`, what the IO side doesn't handle itself to `event`. The queue keeps its capacity.
    public mutating func drain(reply: ([UInt8]) -> Void, event: (TermioMessage) -> Void) {
        let t = terminal
        for m in termio {
            switch m {
            // Pty writes turn every CR into CR LF while linefeed mode is on (termio's copy of LNM).
            case .write(let b): reply(linefeedMode ? b.flatMap { $0 == 0x0D ? [0x0D, 0x0A] : [$0] } : b)
            case .linefeedMode(let on): linefeedMode = on
            case .sizeReport(let s): reply(sizeReport(s))
            case .colorSchemeReport(let force): if force || t.modes.get(.reportColorScheme) { reply(ascii("\u{1B}[?997;1n")) }
            case .visibilityReport(let visible, let force):
                if force || t.modes.get(.reportVisibility) { reply(ascii(visible ? "\u{1B}[?999;1n" : "\u{1B}[?999;2n")) }
            case .focused(let on): if t.modes.get(.focusEvent) { reply(ascii(on ? "\u{1B}[I" : "\u{1B}[O")) }
            // Termio.resize: the grid, the terminal, then the in-band size report.
            case .resize(let size):
                (gridCols, gridRows) = size.grid
                (options.cellWidth, options.cellHeight) = size.cell
                t.resize(cols: gridCols, rows: gridRows, cellWidth: size.cell.width, cellHeight: size.cell.height)
                if t.modes.get(.inBandSizeReports) { reply(sizeReport(.mode2048)) }
            case .scrollViewport(let v): t.scrollViewport(v)
            case .selectionScroll(let on): selectionScrollTimer = on ? .on : selectionScrollTimer == .on ? .stopping : .off
            default: event(m)
            }
        }
        termio.removeAll(keepingCapacity: true)
    }

    func sizeReport(_ s: SizeReportStyle) -> [UInt8] {
        let (w, h) = (options.cellWidth, options.cellHeight)
        switch s {
        case .mode2048: return ascii("\u{1B}[48;\(gridRows);\(gridCols);\(gridRows * h);\(gridCols * w)t")
        case .csi14t: return ascii("\u{1B}[4;\(gridRows * h);\(gridCols * w)t")
        case .csi16t: return ascii("\u{1B}[6;\(h);\(w)t")
        case .csi18t: return ascii("\u{1B}[8;\(gridRows);\(gridCols)t")
        }
    }

    mutating func reply(_ s: String) { termio.append(.write(ascii(s))) }

    /// The terminal is borrowed for the action (it is ours and alive): no retain/release per action.
    public mutating func vt(_ action: Action) {
        Unmanaged.passUnretained(terminal)._withUnsafeGuaranteedRef { apply(action, $0) }
    }

    private mutating func apply(_ action: Action, _ t: Terminal) {
        switch action {
        case .print(let c): t.print(c)
        case .printSlice(let cps): t.printSlice(cps)
        case .printBytes(let b): t.printBytes(b)
        case .printRepeat(let n): t.printRepeat(Int(n))
        case .bell: surface.append(.ringBell)
        case .backspace: t.backspace()
        case .horizontalTab(let n): for _ in 0..<n { let x = t.cursor.x; t.horizontalTab(); if x == t.cursor.x { break } }
        case .horizontalTabBack(let n): for _ in 0..<n { let x = t.cursor.x; t.horizontalTabBack(); if x == t.cursor.x { break } }
        case .linefeed: t.index()
        case .carriageReturn: t.carriageReturn()
        case .enquiry: termio.append(.write(options.enquiryResponse))
        // Ghostty passes the action's `locking` as `single` (ESC N/O are single shifts, ESC n/o locking).
        case .invokeCharset(let v): t.invokeCharset(v.bank, v.charset, single: v.locking)
        case .configureCharset(let v): t.configureCharset(v.slot, v.charset)
        case .cursorUp(let m): t.cursorUp(Int(m.value))
        case .cursorDown(let m): t.cursorDown(Int(m.value))
        case .cursorLeft(let m): t.cursorLeft(Int(m.value))
        case .cursorRight(let m): t.cursorRight(Int(m.value))
        case .cursorPos(let p): t.setCursorPos(Int(p.row), Int(p.col))
        case .cursorCol(let m): t.setCursorPos(t.cursor.y + 1, Int(m.value))
        case .cursorRow(let m): t.setCursorPos(Int(m.value), t.cursor.x + 1)
        case .cursorColRelative(let m): t.setCursorPos(t.cursor.y + 1, t.cursor.x + 1 + Int(m.value))
        case .cursorRowRelative(let m): t.setCursorPos(t.cursor.y + 1 + Int(m.value), t.cursor.x + 1)
        case .cursorStyle(let s): t.setCursorStyle(s)
        case .eraseDisplayBelow(let p): t.eraseDisplay(.below, protected: p)
        case .eraseDisplayAbove(let p): t.eraseDisplay(.above, protected: p)
        case .eraseDisplayComplete(let p): t.scrollViewport(.bottom); t.eraseDisplay(.complete, protected: p)
        case .eraseDisplayScrollback(let p): t.eraseDisplay(.scrollback, protected: p)
        case .eraseDisplayScrollComplete(let p): t.eraseDisplay(.scrollComplete, protected: p)
        case .eraseLineRight(let p): t.eraseLine(.right, protected: p)
        case .eraseLineLeft(let p): t.eraseLine(.left, protected: p)
        case .eraseLineComplete(let p): t.eraseLine(.complete, protected: p)
        case .eraseLineRightUnlessPendingWrap(let p): t.eraseLine(.rightUnlessPendingWrap, protected: p)
        case .deleteChars(let n): t.deleteChars(Int(n))
        case .eraseChars(let n): t.eraseChars(Int(n))
        case .insertLines(let n): t.insertLines(Int(n))
        case .insertBlanks(let n): t.insertBlanks(Int(n))
        case .deleteLines(let n): t.deleteLines(Int(n))
        case .scrollUp(let n): t.scrollUp(Int(n))
        case .scrollDown(let n): t.scrollDown(Int(n))
        case .tabClearCurrent: t.tabClear(all: false)
        case .tabClearAll: t.tabClear(all: true)
        case .tabSet: t.tabSet()
        case .tabReset: t.tabReset()
        case .index: t.index()
        case .nextLine: t.index(); t.carriageReturn()
        case .reverseIndex: t.reverseIndex()
        case .fullReset:
            t.fullReset()
            setMouseShape("text")
            grants = KittyGrants()
            termio.append(.colorSchemeReport(force: false))
            surface.append(.progressReport(Progress(state: .remove, progress: nil)))
        case .setMode(let m): setMode(m.mode, true)
        case .resetMode(let m): setMode(m.mode, false)
        case .saveMode(let m): t.modes.save(m.mode)
        case .restoreMode(let m): setMode(m.mode, t.modes.restore(m.mode))
        case .requestMode(let m): modeReport(modeTable[m.mode.index].value, modeTable[m.mode.index].ansi)
        case .requestModeUnknown(let m): modeReport(m.mode & 0x7FFF, m.ansi)
        case .topAndBottomMargin(let m): t.setTopAndBottomMargin(Int(m.topLeft), Int(m.bottomRight))
        case .leftAndRightMargin(let m): t.setLeftAndRightMargin(Int(m.topLeft), Int(m.bottomRight))
        case .leftAndRightMarginAmbiguous: if t.modes.get(.enableLeftAndRightMargin) { t.setLeftAndRightMargin(0, 0) } else { t.saveCursor() }
        case .saveCursor: t.saveCursor()
        case .restoreCursor: t.restoreCursor()
        case .modifyKeyFormat(let f): t.flags.modifyOtherKeys2 = f == .otherKeysNumeric
        case .protectedModeOff: t.setProtectedMode(.off)
        case .protectedModeIso: t.setProtectedMode(.iso)
        case .protectedModeDec: t.setProtectedMode(.dec)
        case .mouseShiftCapture(let v): t.flags.mouseShiftCapture = v ? .true : .false
        case .sizeReport(let s):
            switch s {
            case .csi14t: termio.append(.sizeReport(.csi14t))
            case .csi16t: termio.append(.sizeReport(.csi16t))
            case .csi18t: termio.append(.sizeReport(.csi18t))
            case .csi21t: surface.append(.reportTitle(.csi21t))
            }
        case .xtversion: termio.append(.write(ascii("\u{1B}P>|ghostty \(options.version)\u{1B}\\")))
        case .deviceAttributes(let d):
            switch d {
            case .primary: reply(options.clipboardWrite != .deny ? "\u{1B}[?62;22;52c" : "\u{1B}[?62;22c")
            case .secondary: reply("\u{1B}[>1;10;0c")
            case .tertiary: break
            }
        case .deviceStatus(let d): deviceStatus(d.request.name)
        case .kittyKeyboardQuery:
            let f = t.active.kittyKeyboard.current
            reply("\u{1B}[?\([f.disambiguate, f.reportEvents, f.reportAlternates, f.reportAll, f.reportAssociated].enumerated().reduce(0) { $0 | ($1.element ? 1 << $1.offset : 0) })u")
        case .kittyKeyboardPush(let f): t.active.kittyKeyboard.push(f.flags)
        case .kittyKeyboardPop(let n): t.active.kittyKeyboard.pop(Int(n))
        case .kittyKeyboardSet(let f): t.active.kittyKeyboard.set(f.flags) { _, v in v }
        case .kittyKeyboardSetOr(let f): t.active.kittyKeyboard.set(f.flags) { $0 | $1 }
        case .kittyKeyboardSetNot(let f): t.active.kittyKeyboard.set(f.flags) { $0 & ~$1 }
        case .kittyColorReport(let r): kittyColorReport(r)
        case .colorOperation(let op): colorOperation(op)
        case .endHyperlink: t.active.endHyperlink()
        case .activeStatusDisplay(let d): t.statusDisplay = d
        case .decaln: t.decaln()
        case .windowTitle(let v): windowTitle(v.title)
        case .reportPwd(let v): reportPwd(v.url)
        case .showDesktopNotification(let n): surface.append(.desktopNotification(Notification(title: cString(n.title, 63), body: cString(n.body, 255))))
        case .progressReport(let p): surface.append(.progressReport(p))
        case .startHyperlink(let h): try? t.active.startHyperlink(h.uri, h.id)
        case .clipboardContents(let c):
            let kind: SurfaceMessage.Clipboard = c.kind == 0x73 ? .selection : c.kind == 0x70 ? .primary : .standard
            surface.append(c.data == [0x3F] ? .clipboardRead(kind) : .clipboardWrite(.init(clipboardType: kind, req: c.data)))
        case .semanticPrompt(let p):
            if p.action == .endInputStartOutput { surface.append(.startCommand) }
            if p.action == .endCommand { surface.append(.stopCommand(p.exitCode.map { (0...255).contains($0) ? UInt8($0) : 1 } ?? 0)) }
            t.semanticPrompt(p)
        case .mouseShape(let s): setMouseShape(s)
        case .setAttribute(let a): if case .unknown = a {} else { t.setAttribute(a) }
        case .dcsHook(let d): dcsHook(d)
        case .dcsPut(let b): dcsPut(b)
        case .dcsUnhook: dcsUnhook()
        case .kittyClipboard(let k): kittyClipboard(k)
        case .apcStart: apc.start(kitty: t.kittyGraphicsEnabled)
        case .apcPut(let b): apc.feed(CollectionOfOne(b))
        case .apcPutSlice(let b): apc.feed(b)
        case .apcEnd: apcEnd()
        // Ghostty's app handler leaves these unimplemented too.
        case .kittyDnd, .titlePush, .titlePop: break
        }
    }

    private mutating func modeReport(_ value: UInt16, _ ansi: Bool) {
        let state: Int
        if !ansi, value == 117 { state = 4 } else if let m = Mode.from(value, ansi: ansi) { state = terminal.modes.get(m) ? 1 : 2 } else { state = 0 }
        reply("\u{1B}[\(ansi ? "" : "?")\(value);\(state)$y")
    }

    private mutating func deviceStatus(_ name: String) {
        let t = terminal
        switch name {
        case "operating_status": reply("\u{1B}[0n")
        case "cursor_position":
            let origin = t.modes.get(.origin)
            let x = origin ? max(0, t.cursor.x - t.scrollingRegion.left) : t.cursor.x, y = origin ? max(0, t.cursor.y - t.scrollingRegion.top) : t.cursor.y
            reply("\u{1B}[\(y + 1);\(x + 1)R")
        case "color_scheme": termio.append(.colorSchemeReport(force: true))
        default: termio.append(.visibilityReport(visible: t.flags.visible, force: true))
        }
    }

    public mutating func setMode(_ m: Mode, _ on: Bool) {
        let t = terminal
        if m == .cursorBlinking, t.cursorDefaults.defaultBlink != nil { return }
        t.modes.set(m, on)
        switch m {
        case .origin: t.setCursorPos(1, 1)
        case .reverseColors: t.dirty.reverseColors = true
        case .enableLeftAndRightMargin: if !on { (t.scrollingRegion.left, t.scrollingRegion.right) = (0, t.cols - 1) }
        case .altScreenLegacy: t.switchScreenMode(.m47, on)
        case .altScreen: t.switchScreenMode(.m1047, on)
        case .altScreenSaveCursorClearEnter: t.switchScreenMode(.m1049, on)
        case .saveCursor: if on { t.saveCursor() } else { t.restoreCursor() }
        case .enableMode3: t.resize(cols: gridCols, rows: gridRows)
        case .mode132Column: t.deccolm(on)
        case .synchronizedOutput: if on { termio.append(.startSynchronizedOutput) }
        case .linefeed: termio.append(.linefeedMode(on))
        case .inBandSizeReports: if on { termio.append(.sizeReport(.mode2048)) }
        case .reportVisibility: if on { termio.append(.visibilityReport(visible: t.flags.visible, force: true)) }
        case .focusEvent: if on { termio.append(.focused(t.flags.focused)) }
        case .mouseEventX10, .mouseEventNormal, .mouseEventButton, .mouseEventAny:
            t.flags.mouseEvent = !on ? .none : m == .mouseEventX10 ? .x10 : m == .mouseEventNormal ? .normal : m == .mouseEventButton ? .button : .any
            setMouseShape(on ? "default" : "text")
        case .mouseFormatUtf8: t.flags.mouseFormat = on ? .utf8 : .x10
        case .mouseFormatSgr: t.flags.mouseFormat = on ? .sgr : .x10
        case .mouseFormatUrxvt: t.flags.mouseFormat = on ? .urxvt : .x10
        case .mouseFormatSgrPixels: t.flags.mouseFormat = on ? .sgrPixels : .x10
        default: break
        }
    }

    private mutating func setMouseShape(_ name: String) { setMouseShape(MouseShape(name)) }

    private mutating func setMouseShape(_ s: MouseShape) {
        if terminal.mouseShape.index == s.index { return }
        terminal.mouseShape = s
        surface.append(.setMouseShape(s))
    }

    private mutating func windowTitle(_ title: [UInt8]) {
        guard title.count < 256 else { return }
        terminal.title = title
        if title.isEmpty {
            surface.append(.setTitle(cString(terminal.pwd.count < 256 ? terminal.pwd : [], 255)))
            seenTitle = false
            return
        }
        seenTitle = true
        surface.append(.setTitle(cString(title, 255)))
    }

    private mutating func reportPwd(_ url: [UInt8]) {
        if url.isEmpty {
            terminal.pwd = []
            if !seenTitle { windowTitle([]) }
            surface.append(.pwdChange([]))
            return
        }
        guard let uri = URI.parse(url, rawPath: url.starts(with: Array("kitty-shell-cwd://".utf8))),
              uri.scheme == Array("file".utf8) || uri.scheme == Array("kitty-shell-cwd".utf8),
              let host = uri.host.map(URI.decoded), host == Array("localhost".utf8) || host == options.hostname else { return }
        let path = uri.rawPath ? uri.path : URI.decoded(uri.path)
        terminal.pwd = path
        surface.append(.pwdChange(path))
        if !seenTitle {
            windowTitle(path)
            seenTitle = false
        }
    }

    private mutating func colorOperation(_ op: ColorOperation) {
        let t = terminal
        var response: [UInt8] = []
        for req in op.requests {
            switch req {
            case .set(let s):
                switch s.target {
                case .palette(let i): t.dirty.palette = true; t.colors.palette.set(Int(i), s.color)
                case .dynamic(.foreground): t.colors.foreground.override = s.color
                case .dynamic(.background): t.colors.background.override = s.color
                case .dynamic(.cursor): t.colors.cursor.override = s.color
                default: break
                }
                surface.append(.colorChange(.init(target: s.target, color: s.color)))
            case .reset(let target):
                switch target {
                case .palette(let i):
                    t.dirty.palette = true; t.colors.palette.reset(Int(i))
                    surface.append(.colorChange(.init(target: target, color: t.colors.palette.current[Int(i)])))
                case .dynamic(.foreground):
                    t.colors.foreground.override = nil
                    if let c = t.colors.foreground.default { surface.append(.colorChange(.init(target: target, color: c))) }
                case .dynamic(.background):
                    t.colors.background.override = nil
                    if let c = t.colors.background.default { surface.append(.colorChange(.init(target: target, color: c))) }
                case .dynamic(.cursor):
                    t.colors.cursor.override = nil
                    if let c = t.colors.cursor.default { surface.append(.colorChange(.init(target: target, color: c))) }
                default: break
                }
            case .resetPalette:
                for i in 0..<256 where t.colors.palette.mask[i] {
                    t.dirty.palette = true; t.colors.palette.reset(i)
                    surface.append(.colorChange(.init(target: .palette(UInt8(i)), color: t.colors.palette.current[i])))
                }
            case .resetSpecial: break
            case .query(let target):
                guard options.colorReportFormat != .none else { break }
                let color: RGB, prefix: String
                switch target {
                case .palette(let i): (color, prefix) = (t.colors.palette.current[Int(i)], "4;\(i)")
                case .dynamic(.foreground): (color, prefix) = (t.colors.foreground.value!, "10")
                case .dynamic(.background): (color, prefix) = (t.colors.background.value!, "11")
                case .dynamic(.cursor): (color, prefix) = (t.colors.cursor.value ?? t.colors.foreground.value!, "12")
                default: continue
                }
                let bits16 = options.colorReportFormat == .bits16
                let hex = { (v: UInt8) in bits16 ? hex4(UInt16(v) * 257) : hex2(v) }
                response += ascii("\u{1B}]\(prefix);rgb:\(hex(color.r))/\(hex(color.g))/\(hex(color.b))") + terminator(op.terminator)
            }
        }
        if !response.isEmpty { termio.append(.write(response)) }
    }

    private mutating func kittyColorReport(_ r: KittyColor) {
        let t = terminal
        var out: [UInt8] = []
        for item in r.list {
            switch item {
            case .query(let key):
                if out.isEmpty { out = ascii("\u{1B}]21") }
                let color: RGB?
                switch key {
                case .palette(let i): color = t.colors.palette.current[Int(i)]
                case .special(.foreground): color = t.colors.foreground.value
                case .special(.background): color = t.colors.background.value
                case .special(.cursor): color = t.colors.cursor.value
                default: continue
                }
                out += ascii(";\(kittyKeyName(key))=") + (color.map { ascii("rgb:\(hex2($0.r))/\(hex2($0.g))/\(hex2($0.b))") } ?? [])
            case .set(let s):
                switch s.key {
                case .palette(let i): t.dirty.palette = true; t.colors.palette.set(Int(i), s.color)
                case .special(.foreground): t.colors.foreground.override = s.color
                case .special(.background): t.colors.background.override = s.color
                case .special(.cursor): t.colors.cursor.override = s.color
                default: continue
                }
            case .reset(let key):
                switch key {
                case .palette(let i): t.dirty.palette = true; t.colors.palette.reset(Int(i))
                case .special(.foreground): t.colors.foreground.override = nil
                case .special(.background): t.colors.background.override = nil
                case .special(.cursor): t.colors.cursor.override = nil
                default: continue
                }
            }
        }
        if !out.isEmpty { termio.append(.write(out + terminator(r.terminator))) }
    }

    /// A finished APC string: kitty graphics and glyph protocol replies go to the program.
    private mutating func apcEnd() {
        switch apc.end() {
        case .kitty(let cmd): if let r = terminal.kittyGraphics(cmd)?.encoded, r.count > 2 { termio.append(.write(r)) }
        case .glyph(let r):
            if let reply = terminal.glossary.execute(r) { termio.append(.write(reply)) }
            if r.verb == .register || r.verb == .clear { terminal.dirty.glyphGlossary = true }
        case nil: break
        }
    }

    // DCS: XTGETTCAP (DCS + q), DECRQSS (DCS $ q), tmux control mode (DCS 1000p) to the host.

    private mutating func dcsHook(_ d: DCS) {
        if d.intermediates == [0x2B], d.final == 0x71 { dcs = .xtgettcap([]) } else if d.intermediates == [0x24], d.final == 0x71 { dcs = .decrqss([]) }
        else if d.intermediates.isEmpty, d.final == 0x70, d.params == [1000], let control { dcs = .control; controls += 1; control(.start, controls) } else { dcs = .ignore }
    }

    /// A run of payload: a query's string grows in place without DEL (Ghostty's parser drops it) and
    /// is dropped whole past its limit (XTGETTCAP 1 MiB, DECRQSS 2 bytes); tmux's goes to the host as is.
    private mutating func dcsPut(_ b: UnsafeBufferPointer<UInt8>) {
        func grow(_ data: inout [UInt8], _ limit: Int) -> Bool {
            data.append(contentsOf: b.lazy.filter { $0 != 0x7F })
            return data.count <= limit
        }
        switch dcs {
        case .xtgettcap(var data): dcs = .ignore; if grow(&data, 1024 * 1024) { dcs = .xtgettcap(data) }
        case .decrqss(var data): dcs = .ignore; if grow(&data, 2) { dcs = .decrqss(data) }
        case .control: control?(.data(b), controls)
        default: break
        }
    }

    private mutating func dcsUnhook() {
        defer { dcs = .inactive }
        switch dcs {
        case .control: control?(.end, controls)
        case .xtgettcap(let data):
            let upper = data.map { (0x61...0x7A).contains($0) ? $0 - 32 : $0 }
            var rest = upper[...]
            while !rest.isEmpty {
                let key = rest.prefix { $0 != 0x3B }
                rest = rest.dropFirst(key.count + 1)
                if let r = xtgettcapReplies[String(decoding: key, as: UTF8.self)] { termio.append(.write(ascii(r))) }
            }
        case .decrqss(let data):
            let t = terminal
            var body = ""
            switch data {
            case [0x6D]: body = t.printAttributes() + "m"
            case [0x72]: body = "\(t.scrollingRegion.top + 1);\(t.scrollingRegion.bottom + 1)r"
            case [0x73]: if t.modes.get(.enableLeftAndRightMargin) { body = "\(t.scrollingRegion.left + 1);\(t.scrollingRegion.right + 1)s" }
            case [0x20, 0x71]:
                let blink = t.modes.get(.cursorBlinking)
                let n: Int
                switch t.cursor.cursorStyle {
                case .block, .blockHollow: n = blink ? 1 : 2
                case .underline: n = blink ? 3 : 4
                case .bar: n = blink ? 5 : 6
                }
                body = "\(n) q"
            default: break
            }
            reply("\u{1B}P\(body.isEmpty ? 0 : 1)$r\(body)\u{1B}\\")
        default: break
        }
    }
}

func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

/// A string as Ghostty's fixed NUL-terminated message buffers hold it: at most `capacity`
/// bytes, not cutting a UTF-8 sequence, ending at the first NUL.
func cString(_ s: [UInt8], _ capacity: Int) -> [UInt8] {
    var n = min(s.count, capacity)
    while n > 0, n < s.count, s[n] & 0xC0 == 0x80 { n -= 1 }
    return Array(s[..<n].prefix { $0 != 0 })
}
func hex2(_ v: UInt8) -> String { let h = String(v, radix: 16); return h.count < 2 ? "0" + h : h }
func hex4(_ v: UInt16) -> String { String(repeating: "0", count: 4 - String(v, radix: 16).count) + String(v, radix: 16) }
func terminator(_ t: Terminator) -> [UInt8] { t == .bel ? [0x07] : [0x1B, 0x5C] }

/// Kitty color protocol key names (OSC 21): palette index or special name.
func kittyKeyName(_ k: KittyKind) -> String {
    switch k {
    case .palette(let i): return String(i)
    case .special(let s):
        return ["foreground", "background", "selection_foreground", "selection_background", "cursor", "cursor_text", "visual_bell", "second_transparent_background"][
            [KittySpecial.foreground, .background, .selectionForeground, .selectionBackground, .cursor, .cursorText, .visualBell, .secondTransparentBackground].firstIndex { $0 == s }!]
    }
}

extension KittyKeyStack {
    mutating func push(_ f: KittyKeyFlags) { idx = (idx + 1) & 7; flags[idx] = f }
    mutating func pop(_ n: Int) {
        if n >= 8 { idx = 0; flags = [KittyKeyFlags](repeating: KittyKeyFlags(0), count: 8); return }
        for _ in 0..<n { flags[idx] = KittyKeyFlags(0); idx = (idx + 7) & 7 }
    }
    mutating func set(_ f: KittyKeyFlags, _ op: (UInt16, UInt16) -> UInt16) { flags[idx] = KittyKeyFlags(op(flags[idx].bits, f.bits)) }
}

extension KittyKeyFlags {
    var bits: UInt16 { [disambiguate, reportEvents, reportAlternates, reportAll, reportAssociated].enumerated().reduce(0) { $0 | ($1.element ? 1 << $1.offset : 0) } }
}

extension SemanticPrompt {
    /// The first `key=value` option with this key (Ghostty's Option.read): nil when absent or invalid.
    func option(_ key: String) -> [UInt8]? {
        for part in optionsUnvalidated.split(separator: 0x3B, omittingEmptySubsequences: false) {
            guard let eq = part.firstIndex(of: 0x3D), Array(part[..<eq]) == Array(key.utf8) else { continue }
            return Array(part[(eq + 1)...])
        }
        return nil
    }
    var promptKind: Screen.PromptKind? {
        guard let v = option("k"), v.count == 1 else { return nil }
        return [0x69: .initial, 0x72: .right, 0x63: .continuation, 0x73: .secondary][v[0]]
    }
    var redraw: Screen.Redraw? { option("redraw").flatMap { ["0": .false, "1": .true, "last": .last][String(decoding: $0, as: UTF8.self)] } }
    var clickEvents: ClickEvents? { option("click_events").flatMap { $0 == [0x31] ? .absolute : $0 == [0x32] ? .relative : nil } }
    var click: Click? { option("cl").flatMap { ["line": .line, "m": .multiple, "v": .conservativeVertical, "w": .smartVertical][String(decoding: $0, as: UTF8.self)] } }
    /// The exit code: the first option parsed as an i32 (Zig parseInt rules).
    var exitCode: Int? {
        let f = optionsUnvalidated.prefix { $0 != 0x3B }
        if f.first == 0x2D { return zigInt(f.dropFirst(), base: 10, max: 1 << 31).map { -Int($0) } }
        return zigInt(f.first == 0x2B ? f.dropFirst() : f, base: 10, max: UInt64(Int32.max)).map { Int($0) }
    }
}

/// The parts of a URL OSC 7 needs, parsed like Zig's std.Uri.parse plus Ghostty's
/// os/uri.zig as on macOS (raw kitty-shell-cwd paths; no MAC address hosts).
struct URI {
    var scheme: [UInt8], host: [UInt8]? = nil, path: [UInt8] = [], rawPath = false

    static func parse(_ text: [UInt8], rawPath: Bool) -> URI? {
        let alpha = { (c: UInt8) in (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) }
        guard let colon = text.firstIndex(of: 0x3A), let f = text.first, alpha(f),
              text[1..<colon].allSatisfy({ alpha($0) || (0x30...0x39).contains($0) || $0 == 0x2B || $0 == 0x2D || $0 == 0x2E }) else { return nil }
        var u = URI(scheme: Array(text[..<colon]))
        let rest = text[(colon + 1)...]
        var i = rest.startIndex
        if rest.starts(with: [0x2F, 0x2F]) {
            i = rest[(i + 2)...].firstIndex { $0 == 0x2F || $0 == 0x3F || $0 == 0x23 } ?? rest.endIndex
            let auth = rest[(rest.startIndex + 2)..<i]
            if auth.isEmpty {
                if !rest.dropFirst(2).starts(with: [0x2F]) { return nil }
            } else if let start = Optional(auth.firstIndex(of: 0x40).map { $0 + 1 } ?? auth.startIndex), start < auth.endIndex {
                if auth[start] == 0x5D { return nil }
                var end = auth.endIndex
                if auth[start] == 0x5B {
                    guard let b = auth.lastIndex(of: 0x5D) else { return nil }
                    end = b + 1
                }
                if let c = auth.lastIndex(of: 0x3A), c >= (auth[start] == 0x5B ? end : start) {
                    end = min(end, c)
                    guard zigInt(auth[(c + 1)...], base: 10, max: 65535, signed: true) != nil else { return nil }
                }
                if start >= end { return nil }
                u.host = Array(auth[start..<end])
            }
        }
        u.path = Array(rawPath ? rest[i...] : rest[i..<(rest[i...].firstIndex { $0 == 0x3F || $0 == 0x23 } ?? rest.endIndex)])
        u.rawPath = rawPath
        return u
    }

    /// Percent-decoding like Zig's Component.formatRaw.
    static func decoded(_ s: [UInt8]) -> [UInt8] {
        var (out, i) = ([UInt8](), 0)
        while i < s.count {
            if s[i] == 0x25, i + 3 <= s.count, let v = zigInt(s[(i + 1)..<(i + 3)], base: 16, max: 255, signed: true) {
                out.append(UInt8(v))
                i += 3
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }
}

extension StreamHandler {
    /// The kitty clipboard protocol's termio side (stream_handler.zig kittyClipboard*): reads go to
    /// the surface, writes collect `wdata`/`walias` until the empty `wdata` commits them; failures
    /// answer with a status and end the write.
    mutating func kittyClipboard(_ k: KittyString) {
        let meta: KittyMetadata
        do {
            guard let m = try KittyMetadata.parse(k.metadata) else { return }
            meta = m
        } catch {
            if let op = KittyMetadata.operation(k.metadata), op == .wdata || op == .walias { kittyWriteEnd("EINVAL", k.terminator) }
            return
        }
        let payload = k.payload ?? []
        switch meta.op {
        case .read:
            guard let d = Base64.decodeStrict(payload, paddingRequired: true), isUTF8(d) else { return }
            var (mimes, list) = ([[UInt8]](), false)
            for m in d.split(whereSeparator: { [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C].contains($0) }).map(Array.init) {
                if m == [0x2E] { list = true } else if mimes.count < 4 { mimes.append(m) }
            }
            let pw = meta.name.isEmpty ? [] : meta.pw
            let granted = !mimes.isEmpty && grants.use(pw, read: true)
            surface.append(.kittyClipboardRead(.init(location: meta.primary ? .primary : .standard, mimes: mimes, list: list, id: meta.id, pw: pw,
                                                     name: meta.name, granted: granted, terminator: k.terminator)))
        case .write:
            kittyWrite = nil
            if options.clipboardWrite == .deny { return kittyStatus("write", "EPERM", meta.id, k.terminator) }
            kittyWrite = KittyWrite(meta, maxSize: options.clipboardWriteLimit)
        case .wdata:
            guard kittyWrite != nil else { return }
            guard !meta.mime.isEmpty else { return kittyCommit(k.terminator) }
            do { try kittyWrite!.data(meta.mime, payload) } catch { kittyWriteEnd(error as? KittyWrite.Failure == .tooLarge ? "EFBIG" : "EINVAL", k.terminator) }
        case .walias:
            guard kittyWrite != nil else { return }
            guard !meta.mime.isEmpty else { return kittyWriteEnd("EINVAL", k.terminator) }
            do { try kittyWrite!.alias(meta.mime, payload) } catch { kittyWriteEnd("EINVAL", k.terminator) }
        }
    }

    /// The committed write goes to the surface (granted when its name's password allows writes).
    mutating func kittyCommit(_ t: Terminator) {
        guard let contents = try? kittyWrite!.commit() else { return kittyWriteEnd("EINVAL", t) }
        let w = kittyWrite!, pw = w.name.isEmpty ? [] : w.pw
        let granted = grants.use(pw, read: false)
        surface.append(.kittyClipboardWrite(.init(location: w.primary ? .primary : .standard, contents: contents, id: w.id, pw: pw, name: w.name,
                                                  granted: granted, terminator: t)))
        kittyWrite = nil
    }

    /// Ends an open write with a status.
    mutating func kittyWriteEnd(_ status: String, _ t: Terminator) {
        guard let w = kittyWrite else { return }
        kittyWrite = nil
        kittyStatus("write", status, w.id, t)
    }

    /// A single status reply to a read or write.
    mutating func kittyStatus(_ op: String, _ status: String, _ id: [UInt8], _ t: Terminator) {
        termio.append(.write(KittyClipboard.response(op, status, id: id, terminator: t)))
    }
}
