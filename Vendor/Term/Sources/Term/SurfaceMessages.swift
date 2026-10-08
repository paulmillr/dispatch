// What the program's output asks of the surface (Ghostty's Surface.handleMessage): titles,
// colors, clipboard, bells, notifications, progress and command timing become host actions and
// clipboard requests. The embedder runs `handle` for the stream's queued messages between inputs.

extension Surface {
    /// The messages the stream queued since the last call, in order (messages queued while
    /// `body` runs wait for the next call).
    public func takeMessages(_ body: (SurfaceMessage) -> Void) {
        swap(&taken, &handler.surface)
        for m in taken { body(m) }
        taken.removeAll(keepingCapacity: true)
    }

    /// Surface.handleMessage.
    public func handle(_ m: SurfaceMessage) {
        switch m {
        case .setTitle(let t):
            title = t   // the embedded runtime keeps it for title reports
            _ = host?.perform(.setTitle(t))
        case .reportTitle: break   // title-report is off by default
        case .colorChange(let c):
            let kind: SurfaceAction.ColorKind? = switch c.target {
            case .palette(let i): .palette(i)
            case .dynamic(.foreground): .foreground
            case .dynamic(.background): .background
            case .dynamic(.cursor): .cursor
            default: nil
            }
            if let kind { _ = host?.perform(.colorChange(kind, c.color)) }
        case .setMouseShape(let s): _ = host?.perform(.mouseShape(s))
        case .clipboardRead(let c): if config.clipboardRead != .deny { _ = startClipboardRequest(.standard, .osc52Read(c)) }
        // Under ask the host confirms the write.
        case .clipboardWrite(let w):
            guard handler.options.clipboardWrite != .deny, let data = Base64.decodeStrict(w.req) else { break }
            host?.setClipboard(w.clipboardType, [ClipboardContent(mime: ascii("text/plain"), data: data)], confirm: handler.options.clipboardWrite == .ask)
        // Kitty clipboard reads and writes: unless denied, the host serves reads or can't, and
        // completes writes (a location it can't write: ENOSYS).
        case .kittyClipboardRead(let r):
            if config.clipboardRead == .deny { return handler.kittyStatus("read", "EPERM", r.id, r.terminator) }
            switch startClipboardRequest(r.location, .kittyRead(r)) {
            case .started: break
            case .unavailable: kittyRead(r, [], [])
            case .unsupported: handler.kittyStatus("read", "ENOSYS", r.id, r.terminator)
            }
        case .kittyClipboardWrite(let w):
            if handler.options.clipboardWrite == .deny { return handler.kittyStatus("write", "EPERM", w.id, w.terminator) }
            if startClipboardRequest(w.location, .kittyWrite(w)) != .started { handler.kittyStatus("write", "ENOSYS", w.id, w.terminator) }
        case .searchTotal(let n): _ = host?.perform(.searchTotal(n))
        case .searchSelected(let n): _ = host?.perform(.searchSelected(n))
        case .pwdChange(let p): _ = host?.perform(.pwd(p))
        case .ringBell:
            let t = now()
            if let last = lastBell, t - last < 100_000_000 { break }
            lastBell = t
            _ = host?.perform(.ringBell)
        case .desktopNotification(let n):
            // At most one a second, and the same one again only after five.
            let (t, digest) = (now(), wyhash(n.title + n.body))
            if let last = lastNotification, t - last.time < 1_000_000_000 || last.digest == digest && t - last.time < 5_000_000_000 { break }
            lastNotification = (t, digest)
            _ = host?.perform(.desktopNotification(title: n.title, body: n.body))
        case .progressReport(let p): _ = host?.perform(.progressReport(p))
        case .startCommand: commandStart = now()
        case .stopCommand(let code):
            guard let start = commandStart else { break }
            commandStart = nil
            _ = host?.perform(.commandFinished(exitCode: code, duration: now() - start))
        }
    }

    /// After each frame (Ghostty's renderer sends the scrollbar when it changed): a changed
    /// scrollbar goes to the host.
    public func reportScrollbar() {
        let s = screen.scrollbar
        guard s != reported else { return }
        reported = s
        _ = host?.perform(.scrollbar(s))
    }

    /// Surface.completeClipboardReadOSC52: the clipboard's text as an OSC 52 reply (under ask: once confirmed).
    func osc52Reply(_ data: [UInt8], _ c: SurfaceMessage.Clipboard, confirmed: Bool) throws {
        guard confirmed || config.clipboardRead != .ask else { throw ClipboardError.unauthorized }
        write(ascii("\u{1B}]52;\(c == .standard ? "c" : c == .selection ? "s" : "p");") + Base64.encode(data) + ascii("\u{1B}\\"))
    }
}

extension Base64 {
    /// Ghostty's simd.base64.decodeStrict: the standard alphabet only, `=` only as the last one
    /// or two bytes (then the length is a multiple of 4), never a lone trailing character; with
    /// padding required, always whole groups.
    static func decodeStrict(_ s: [UInt8], paddingRequired: Bool = false) -> [UInt8]? {
        let pad = s.suffix(2).reversed().prefix { $0 == 0x3D }.count
        if paddingRequired || pad > 0 ? s.count % 4 != 0 : s.count % 4 == 1 { return nil }
        var (out, acc, bits) = ([UInt8](), UInt32(0), 0)
        for c in s.dropLast(pad) {
            guard let v = value(c) else { return nil }
            (acc, bits) = (acc << 6 | v, bits + 6)
            if bits >= 8 { bits -= 8; out.append(UInt8(truncatingIfNeeded: acc >> UInt32(bits))) }
        }
        return out
    }

    /// A character's value in the standard alphabet.
    static func value(_ c: UInt8) -> UInt32? {
        switch c {
        case 0x41...0x5A: UInt32(c - 0x41)
        case 0x61...0x7A: UInt32(c - 0x61 + 26)
        case 0x30...0x39: UInt32(c - 0x30 + 52)
        case 0x2B: 62
        case 0x2F: 63
        default: nil
        }
    }
}
