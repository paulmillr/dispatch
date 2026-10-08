// CSI and ESC sequences: one row per sequence, keyed by final byte and
// intermediates (private markers included), as Ghostty's stream.zig maps them.

public struct Mode: Equatable, Sendable {
    public let index: Int
    public var name: String { modeTable[index].name }

    /// Ghostty's modeFromInt (as on macOS: no mode is disabled there).
    static func from(_ value: UInt16, ansi: Bool) -> Mode? {
        modeTable.firstIndex { $0.value == value && $0.ansi == ansi }.map(Mode.init)
    }
}

public struct DeviceStatusRequest { public let index: Int; public var name: String { deviceStatusTable[index].name } }
public struct MouseShape { public let index: Int; public var name: String { mouseShapeNames[index] } }

extension Stream {
    mutating func csiDispatch(_ c: UInt8, _ p: UnsafeBufferPointer<UInt16>) {
        let k = inter, n = p.count, p0 = p.first ?? 0, p1 = n > 1 ? p[p.startIndex + 1] : 0
        /// 0 params -> default, 1 -> the value, more -> the sequence is dropped.
        func one(_ d: UInt16 = 1) -> UInt16? { n == 0 ? d : n == 1 ? p0 : nil }
        func move(_ f: (Movement) -> Action, _ then: Action? = nil) {
            guard let v = one() else { return }
            emit(f(Movement(value: v)))
            if let then { emit(then) }
        }
        func count(_ f: (UInt16) -> Action) { if let v = one() { emit(f(v)) } }
        func modes(_ ansi: Bool, _ f: (ModeRef) -> Action) {
            for v in p { if let m = Mode.from(v, ansi: ansi) { emit(f(ModeRef(mode: m))) } }
        }
        func margin(_ f: (Margin) -> Action, _ none: Action) {
            if n == 0 { emit(none) } else if n <= 2 { emit(f(Margin(topLeft: p0, bottomRight: p1))) }
        }
        func kitty(_ f: (KittyFlags) -> Action) {
            let v = n >= 1 ? p0 : 0
            if v <= 31 { emit(f(KittyFlags(flags: KittyKeyFlags(v)))) }
        }
        switch (c, k) {
        case (0x41, 0), (0x6B, 0): move(Action.cursorUp)                       // A k
        case (0x42, 0): move(Action.cursorDown)                                 // B
        case (0x43, 0): move(Action.cursorRight)                                // C
        case (0x44, 0), (0x6A, 0): move(Action.cursorLeft)                     // D j
        case (0x45, 0): move(Action.cursorDown, .carriageReturn)                // E
        case (0x46, 0): move(Action.cursorUp, .carriageReturn)                  // F
        case (0x47, 0), (0x60, 0): move(Action.cursorCol)                      // G `
        case (0x61, 0): move(Action.cursorColRelative)                          // a
        case (0x64, 0): move(Action.cursorRow)                                  // d
        case (0x65, 0): move(Action.cursorRowRelative)                          // e
        case (0x48, 0), (0x66, 0): if n <= 2 { emit(.cursorPos(CursorPos(row: n > 0 ? p0 : 1, col: n > 1 ? p1 : 1))) } // H f
        case (0x49, 0): count(Action.horizontalTab)                             // I
        case (0x5A, 0): count(Action.horizontalTabBack)                         // Z
        case (0x4C, 0): count(Action.insertLines)                               // L
        case (0x4D, 0): count(Action.deleteLines)                               // M
        case (0x50, 0): count(Action.deleteChars)                               // P
        case (0x53, 0): count(Action.scrollUp)                                  // S
        case (0x54, 0): count(Action.scrollDown)                                // T
        case (0x58, 0): count(Action.eraseChars)                                // X
        case (0x62, 0): count(Action.printRepeat)                               // b
        case (0x40, 0): if n <= 1 { emit(.insertBlanks(n == 0 ? 1 : max(1, p0))) } // @
        case (0x4A, 0), (0x4A, 0x3F):                                           // J, ?J
            let f: ((Bool) -> Action)? = switch p0 { case 0: Action.eraseDisplayBelow; case 1: Action.eraseDisplayAbove
                case 2: Action.eraseDisplayComplete; case 3: Action.eraseDisplayScrollback; case 22: Action.eraseDisplayScrollComplete; default: nil }
            if n <= 1, let f { emit(f(k != 0)) }
        case (0x4B, 0), (0x4B, 0x3F):                                           // K, ?K
            let f: ((Bool) -> Action)? = switch p0 { case 0: Action.eraseLineRight; case 1: Action.eraseLineLeft; case 2: Action.eraseLineComplete; default: nil }
            if n <= 1, let f { emit(f(k != 0)) }
        case (0x57, 0):                                                         // W
            if n == 0 || (n == 1 && p0 == 0) { emit(.tabSet) }
            else if n == 1 && p0 == 2 { emit(.tabClearCurrent) } else if n == 1 && p0 == 5 { emit(.tabClearAll) }
        case (0x57, 0x3F): if n == 1 && p0 == 5 { emit(.tabReset) }             // ?W
        case (0x67, 0): if n == 1 && p0 == 0 { emit(.tabClearCurrent) } else if n == 1 && p0 == 3 { emit(.tabClearAll) } // g
        case (0x63, 0): emit(.deviceAttributes(.primary))                       // c
        case (0x63, 0x3E): emit(.deviceAttributes(.secondary))                  // >c
        case (0x63, 0x3D): emit(.deviceAttributes(.tertiary))                   // =c
        case (0x68, 0): modes(true, Action.setMode)                            // h
        case (0x68, 0x3F): modes(false, Action.setMode)                        // ?h
        case (0x6C, 0): modes(true, Action.resetMode)                          // l
        case (0x6C, 0x3F): modes(false, Action.resetMode)                      // ?l
        case (0x72, 0x3F): modes(false, Action.restoreMode)                    // ?r
        case (0x73, 0x3F): modes(false, Action.saveMode)                       // ?s
        case (0x6D, 0): var sgr = SGR(params: p, colons: colons); while let a = sgr.next() { emit(.setAttribute(a)) } // m
        case (0x6D, 0x3E):                                                      // >m
            let f: ModifyKeyFormat? = switch p0 { case 0: .legacy; case 1: .cursorKeys; case 2: .functionKeys; case 4: .otherKeysNone; default: nil }
            if n == 0 { emit(.modifyKeyFormat(.legacy)) }
            else if n <= 2, let f { emit(.modifyKeyFormat(f == .otherKeysNone && n == 2 && p1 == 2 ? .otherKeysNumeric : f)) }
        case (0x6E, 0x3E): emit(.modifyKeyFormat(.otherKeysNumericExcept))      // >n
        case (0x6E, _) where k == 0 || k >> UInt32(8 * (interCount - 1)) == 0x3F:                      // n, ?n
            guard n == 1, k == 0 || k == 0x3F else { return }
            if let i = deviceStatusTable.firstIndex(where: { $0.value == p0 && $0.question == (k != 0) }) {
                emit(.deviceStatus(DeviceStatus(request: DeviceStatusRequest(index: i))))
            }
        case (0x70, 0x3F24):                                                    // ?$p DECRQM
            guard n == 1 else { return }
            emit(Mode.from(p0, ansi: false).map { .requestMode(ModeRef(mode: $0)) } ?? .requestModeUnknown(RawMode(mode: p0, ansi: false)))
        case (0x71, 0x20):                                                      // SP q DECSCUSR
            if n <= 1, p0 <= 6, let s = CursorStyle(rawValue: p0) { emit(.cursorStyle(s)) }
        case (0x71, 0x22):                                                      // " q DECSCA
            if n == 0 || (n == 1 && (p0 == 0 || p0 == 2)) { emit(.protectedModeOff) } else if n == 1 && p0 == 1 { emit(.protectedModeDec) }
        case (0x71, 0x3E): emit(.xtversion)                                     // >q
        case (0x72, 0): margin(Action.topAndBottomMargin, .topAndBottomMargin(Margin(topLeft: 0, bottomRight: 0))) // r
        case (0x73, 0): margin(Action.leftAndRightMargin, .leftAndRightMarginAmbiguous) // s
        case (0x73, 0x3E): if n == 0 || (n == 1 && p0 <= 1) { emit(.mouseShiftCapture(n == 1 && p0 == 1)) } // >s
        case (0x74, 0) where n > 0:                                             // t
            let r: SizeReport? = switch p0 { case 14: .csi14t; case 16: .csi16t; case 18: .csi18t; case 21: .csi21t; default: nil }
            if n == 1, let r { emit(.sizeReport(r)) }
            else if (p0 == 22 || p0 == 23), n == 2 || n == 3, p1 == 0 || p1 == 2 {
                let i = n == 3 ? p[p.startIndex + 2] : 0
                emit(p0 == 22 ? .titlePush(i) : .titlePop(i))
            }
        case (0x75, 0): emit(.restoreCursor)                                    // u
        case (0x75, 0x3F): emit(.kittyKeyboardQuery)                            // ?u
        case (0x75, 0x3E): if n != 1 || p0 <= 31 { emit(.kittyKeyboardPush(KittyFlags(flags: KittyKeyFlags(n == 1 ? p0 : 0)))) } // >u
        case (0x75, 0x3C): emit(.kittyKeyboardPop(n == 1 ? p0 : 1))             // <u
        case (0x75, 0x3D):                                                      // =u
            let f: ((KittyFlags) -> Action)? = switch n >= 2 ? p1 : 1 { case 1: Action.kittyKeyboardSet; case 2: Action.kittyKeyboardSetOr; case 3: Action.kittyKeyboardSetNot; default: nil }
            if let f { kitty(f) }
        case (0x7D, 0x24): if n == 1 && p0 <= 1 { emit(.activeStatusDisplay(p0 == 0 ? .main : .statusLine)) } // $}
        default: break
        }
    }

    mutating func escDispatch(_ c: UInt8) {
        let k = inter
        let slot: CharsetSlot? = switch k { case 0x28: .G0; case 0x29: .G1; case 0x2A: .G2; case 0x2B: .G3; default: nil }  // ( ) * +
        let set: Charset? = switch c { case 0x42: .ascii; case 0x41: .british; case 0x30: .decSpecial; default: nil }          // B A 0
        func invoke(_ bank: CharsetBank, _ slot: CharsetSlot, _ locking: Bool) {
            emit(.invokeCharset(InvokeCharset(bank: bank, charset: slot, locking: locking)))
        }
        if let set {
            if interCount == 1, let slot { emit(.configureCharset(ConfigureCharset(slot: slot, charset: set))) }
            return
        }
        switch (c, k) {
        case (0x37, 0): emit(.saveCursor)                                       // 7
        case (0x38, 0): emit(.restoreCursor)                                    // 8
        case (0x38, 0x23): emit(.decaln)                                        // #8
        case (0x44, 0): emit(.index)                                            // D
        case (0x45, 0): emit(.nextLine)                                         // E
        case (0x48, 0): emit(.tabSet)                                           // H
        case (0x4D, 0): emit(.reverseIndex)                                     // M
        case (0x4E, 0): invoke(.GL, .G2, true)                                  // N
        case (0x4F, 0): invoke(.GL, .G3, true)                                  // O
        case (0x6E, 0): invoke(.GL, .G2, false)                                 // n
        case (0x6F, 0): invoke(.GL, .G3, false)                                 // o
        case (0x7E, 0): invoke(.GR, .G1, false)                                 // ~
        case (0x7D, 0): invoke(.GR, .G2, false)                                 // }
        case (0x7C, 0): invoke(.GR, .G3, false)                                 // |
        case (0x56, 0): emit(.protectedModeIso)                                 // V
        case (0x57, 0): emit(.protectedModeOff)                                 // W
        case (0x5A, 0): emit(.deviceAttributes(.primary))                       // Z
        case (0x63, 0): emit(.fullReset)                                        // c
        case (0x3D, 0): emit(.setMode(ModeRef(mode: .keypadKeys)))            // =
        case (0x3E, 0): emit(.resetMode(ModeRef(mode: .keypadKeys)))          // >
        default: break
        }
    }
}
