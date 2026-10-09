// What the stream hands to its handler: Ghostty's `stream.Action` vocabulary.
// Names and payload shapes follow Ghostty so both can be compared 1:1.

public protocol Handler {
    mutating func vt(_ action: Action)
}

public enum Action {
    case print(UInt32)
    case printSlice(UnsafeBufferPointer<UInt32>)
    /// Printable ASCII (0x20-0x7F) as bytes: each one narrow cell (Ghostty has code points only).
    case printBytes(UnsafeBufferPointer<UInt8>)
    case printRepeat(UInt16)
    case bell, backspace, carriageReturn, linefeed, enquiry
    case horizontalTab(UInt16), horizontalTabBack(UInt16)
    case invokeCharset(InvokeCharset)
    case configureCharset(ConfigureCharset)
    case cursorUp(Movement), cursorDown(Movement), cursorLeft(Movement), cursorRight(Movement)
    case cursorCol(Movement), cursorRow(Movement), cursorColRelative(Movement), cursorRowRelative(Movement)
    case cursorPos(CursorPos)
    case cursorStyle(CursorStyle)
    case eraseDisplayBelow(Bool), eraseDisplayAbove(Bool), eraseDisplayComplete(Bool)
    case eraseDisplayScrollback(Bool), eraseDisplayScrollComplete(Bool)
    case eraseLineRight(Bool), eraseLineLeft(Bool), eraseLineComplete(Bool), eraseLineRightUnlessPendingWrap(Bool)
    case deleteChars(UInt16), eraseChars(UInt16), insertLines(UInt16), insertBlanks(UInt16)
    case deleteLines(UInt16), scrollUp(UInt16), scrollDown(UInt16)
    case setMode(ModeRef), resetMode(ModeRef), saveMode(ModeRef), restoreMode(ModeRef), requestMode(ModeRef)
    case requestModeUnknown(RawMode)
    case topAndBottomMargin(Margin), leftAndRightMargin(Margin), leftAndRightMarginAmbiguous
    case modifyKeyFormat(ModifyKeyFormat)
    case mouseShiftCapture(Bool)
    case sizeReport(SizeReport)
    case titlePush(UInt16), titlePop(UInt16)
    case deviceAttributes(DeviceAttributes)
    case deviceStatus(DeviceStatus)
    case kittyKeyboardQuery, kittyKeyboardPop(UInt16)
    case kittyKeyboardPush(KittyFlags), kittyKeyboardSet(KittyFlags), kittyKeyboardSetOr(KittyFlags), kittyKeyboardSetNot(KittyFlags)
    case index, nextLine, reverseIndex, saveCursor, restoreCursor, fullReset, decaln, xtversion
    case tabSet, tabClearCurrent, tabClearAll, tabReset
    case protectedModeOff, protectedModeIso, protectedModeDec
    case activeStatusDisplay(StatusDisplay)
    case setAttribute(Attribute)
    /// DCS payload in runs (Ghostty's dcs_put is one byte; its parser drops DEL, here the handler does).
    case dcsHook(DCS), dcsPut(UnsafeBufferPointer<UInt8>), dcsUnhook
    case apcStart, apcPut(UInt8), apcPutSlice(UnsafeBufferPointer<UInt8>), apcEnd(ApcEnd)
    // OSC
    case windowTitle(Title)
    case reportPwd(Pwd)
    case mouseShape(MouseShape)
    case startHyperlink(Hyperlink), endHyperlink
    case clipboardContents(Clipboard)
    case showDesktopNotification(Notification)
    case progressReport(Progress)
    case semanticPrompt(SemanticPrompt)
    case colorOperation(ColorOperation)
    case kittyColorReport(KittyColor)
    case kittyClipboard(KittyString), kittyDnd(KittyString)
    /// OSC 7501 (not Ghostty's): a program status report, clear or query.
    case programStatus(ProgramStatusCommand)
}

public struct Movement { public var value: UInt16 }
public struct CursorPos { public var row: UInt16, col: UInt16 }
public struct Margin { public var topLeft: UInt16, bottomRight: UInt16 }
public struct ModeRef { public var mode: Mode }
public struct RawMode { public var mode: UInt16, ansi: Bool }
public struct DeviceStatus { public var request: DeviceStatusRequest }
public struct KittyFlags { public var flags: KittyKeyFlags }
public struct DCS { public var intermediates: [UInt8], params: [UInt16], final: UInt8 }
public struct ApcEnd { public var terminated: Bool }

public struct KittyKeyFlags {
    public var disambiguate, reportEvents, reportAlternates, reportAll, reportAssociated: Bool
    init(_ v: UInt16) {
        (disambiguate, reportEvents, reportAlternates, reportAll, reportAssociated) =
            (v & 1 != 0, v & 2 != 0, v & 4 != 0, v & 8 != 0, v & 16 != 0)
    }
    var isEmpty: Bool { !(disambiguate || reportEvents || reportAlternates || reportAll || reportAssociated) }
}

public enum CharsetBank: String { case GL, GR }
public enum CharsetSlot: String { case G0, G1, G2, G3 }
public enum Charset { case utf8, ascii, british, decSpecial }
public struct InvokeCharset { public var bank: CharsetBank, charset: CharsetSlot, locking: Bool }
public struct ConfigureCharset { public var slot: CharsetSlot, charset: Charset }

public enum CursorStyle: UInt16 {
    case `default`, blinkingBlock, steadyBlock, blinkingUnderline, steadyUnderline, blinkingBar, steadyBar
}
public enum ModifyKeyFormat {
    case legacy, cursorKeys, functionKeys, otherKeysNone, otherKeysNumericExcept, otherKeysNumeric
}
public enum SizeReport: String { case csi14t = "csi_14_t", csi16t = "csi_16_t", csi18t = "csi_18_t", csi21t = "csi_21_t" }
public enum DeviceAttributes { case primary, secondary, tertiary }
public enum StatusDisplay: UInt16 { case main, statusLine }

// SGR attributes (Ghostty's `sgr.Attribute`).
public enum Attribute {
    case unset, unknown(UnknownSGR), bold, resetBold, italic, resetItalic, faint
    case underline(Underline), underlineColor(RGB), underlineColor256(UInt8), resetUnderlineColor
    case overline, resetOverline, blink, resetBlink, inverse, resetInverse
    case invisible, resetInvisible, strikethrough, resetStrikethrough
    case directColorFg(RGB), directColorBg(RGB), bg8(ColorName), fg8(ColorName), resetFg, resetBg
    case brightBg8(ColorName), brightFg8(ColorName), bg256(UInt8), fg256(UInt8)
}
public struct UnknownSGR { public var full: [UInt16], partial: [UInt16] }
public enum Underline: UInt16 { case none, single, double, curly, dotted, dashed }
public struct RGB: Equatable, Sendable {
    public var r, g, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }
}
public struct ColorName { public var value: UInt8 }

// OSC payloads.
public enum Terminator { case st, bel }
public struct Title { public var title: [UInt8] }
public struct Pwd { public var url: [UInt8] }
public struct Hyperlink { public var uri: [UInt8], id: [UInt8]? }
public struct Clipboard { public var kind: UInt8, data: [UInt8], terminator: Terminator }
public struct Notification { public var title: [UInt8], body: [UInt8] }
public struct Progress {
    public enum State { case remove, set, error, indeterminate, pause }
    public var state: State, progress: UInt8?
}
public struct KittyString { public var metadata: [UInt8], payload: [UInt8]?, terminator: Terminator }
