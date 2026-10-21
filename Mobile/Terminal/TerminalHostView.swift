import UIKit
@preconcurrency import Term

/// A terminal in a `UIView` (M6a): a `TerminalPresence`'s session drawing into this view's Metal layer. The view
/// owns input and geometry: the software keyboard (`UITextInput`), hardware keys (`UIKeyCommand`), touch selection,
/// scrolling, pinch zoom. Its size in points becomes the grid, sent through the feed as `resize` whenever it changes
/// (rotation, the keyboard, a font size). Presentation only: the presence stays attached when the view goes away
/// (the Chat segment may need it), and nothing on the host ends (docs/architecture.md).
final class TerminalHostView: UIView {
    let presence: TerminalPresence
    var session: TerminalSession { presence.session }
    var feed: (any TerminalFeed)? { presence.attached ? presence.feed : nil }
    var configuration: TerminalConfiguration { presence.configuration }
    var scroll: TerminalScrollModel {
        get { presence.scroll }
        set { presence.scroll = newValue }
    }

    /// The latched capsule modifiers for the next key (the key capsule's model), and the notice that a key used them.
    var pendingMods: () -> Mods = { [] }
    var onKeySent: (() -> Void)?
    /// The keyboard's frame in the window changed (nil: no window).
    var onKeyboardFrame: ((CGRect?) -> Void)?
    /// Pinned to `keyboardLayoutGuide`, which follows a floating or split keyboard too: the keyboard's real frame.
    /// The keyboard's notifications cannot say it: a keyboard that comes up floating posts none, and floating a
    /// docked one posts a hide while it stays on screen.
    let keyboardTracker = UIView()
    private var reportedKeyboard: CGRect??
    /// Whether the software keyboard shows while this view is first responder; false keeps hardware keys and the
    /// capsule working with no keyboard on screen.
    var softwareKeyboard = true {
        didSet {
            guard softwareKeyboard != oldValue else { return }
            inputView = softwareKeyboard ? nil : UIView(frame: .zero)
            if isFirstResponder { reloadInputViews() }
        }
    }
    private var noKeyboard: UIView?
    override var inputView: UIView? {
        get { noKeyboard }
        set { noKeyboard = newValue }
    }

    /// The input method's text (UITextInput's marked text) and its selection, in UTF-16 units.
    var marked = ""
    var markedSelection = NSRange(location: 0, length: 0)
    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    // UITextInputTraits: a terminal wants exactly the keys typed.
    var autocorrectionType = UITextAutocorrectionType.no
    var autocapitalizationType = UITextAutocapitalizationType.none
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    var inlinePredictionType = UITextInlinePredictionType.no
    var keyboardType = UIKeyboardType.default
    var keyboardAppearance = UIKeyboardAppearance.dark
    var returnKeyType = UIReturnKeyType.default
    var textContentType: UITextContentType! = nil

    let startHandle = TerminalSelectionHandle(end: false)
    let endHandle = TerminalSelectionHandle(end: true)
    var editMenu: UIEditMenuInteraction?
    var momentum: CADisplayLink?
    var momentumVelocity = 0.0
    var momentumTime: CFTimeInterval = 0
    var momentumPoint = CGPoint.zero
    var draggedHandle: Surface.TouchHandle?
    /// Presses `pressesBegan` took for the terminal (a chord iPadOS reserves): their ends stay here too.
    var reservedPresses: Set<UIPress> = []
    /// The selection came from a pointer (no handles); a long press makes a touch one.
    var pointerSelection = false
    /// The scroll, wheel and pointer recognizers (tests check how they are set up).
    var pointerRecognizers: (pan: UIPanGestureRecognizer, wheel: UIPanGestureRecognizer, click: UILongPressGestureRecognizer,
                             secondary: UITapGestureRecognizer)?
    /// Runs once, after the first layout with a size (the attachment waits for the view's grid).
    var onSized: (() -> Void)?
    var hasSize: Bool { bounds.width > 0 && bounds.height > 0 && window != nil }
    /// A pinch changed the font size (to remember it).
    var onFontSize: ((Double) -> Void)?
    var pinchBase: Double?
    private var blinkTimer: Timer?

    init(presence: TerminalPresence) {
        self.presence = presence
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        clipsToBounds = true
        layer.addSublayer(session.layer)
        updateBackground()
        presence.onViewEvent = { [weak self] event in self?.handle(event) }
        presence.relayout = { [weak self] in self?.setNeedsLayout() }
        installGestures()
        installKeyboardTracker()
        #if DEBUG
        // `-DispatchHardwareKeyboard YES` stands in for an attached keyboard: no software keyboard either, as with a
        // real one (and as Chat's composer does), so screenshots show the terminal as a keyboard user sees it. The
        // capsule's keyboard key still brings it.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "DispatchHardwareKeyboard") != nil, defaults.bool(forKey: "DispatchHardwareKeyboard") {
            // In the initializer its observer does not run: the input view too.
            softwareKeyboard = false
            inputView = UIView(frame: .zero)
        }
        #endif
        // The iPad keyboard's shortcut bar would offer Undo, Redo and Paste, which a terminal has no use for or has
        // in its edit menu and ⌘V; the capsule carries the keys the keyboard lacks. Empty, the bar goes and gives the
        // rows back (with a hardware keyboard, only the system's minimal bar remains). No effect on an iPhone.
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        accessibilityLabel = "Terminal"
        accessibilityTraits = .allowsDirectInteraction
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    isolated deinit {
        blinkTimer?.invalidate()
        momentum?.invalidate()
        // Another view may show the presence by now.
        if session.layer.superlayer === layer {
            session.setVisible(false)
            session.setFocus(false)
        }
    }

    private func installKeyboardTracker() {
        keyboardTracker.isHidden = true
        keyboardTracker.isUserInteractionEnabled = false
        keyboardTracker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardTracker)
        let guide = keyboardLayoutGuide
        guide.followsUndockedKeyboard = true
        NSLayoutConstraint.activate([
            keyboardTracker.topAnchor.constraint(equalTo: guide.topAnchor),
            keyboardTracker.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            keyboardTracker.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            keyboardTracker.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
    }

    /// The tracker's frame in the window, when it changed.
    private func reportKeyboard() {
        let frame = window.map { convert(keyboardTracker.frame, to: $0) }
        guard reportedKeyboard != .some(frame) else { return }
        reportedKeyboard = .some(frame)
        onKeyboardFrame?(frame)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportKeyboard()
        guard bounds.width > 0, bounds.height > 0 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            session.layer.frame = bounds
            CATransaction.commit()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let grid = presence.shownGrid {
            // The server's grid (another client holds the tmux window at its size): drawn at the same font size from
            // the top left, clipped or with room to spare, while the view's own grid is still asked for.
            let pixels = session.pixels(columns: grid.columns, rows: grid.rows)
            session.layer.frame = CGRect(x: 0, y: 0, width: Double(pixels.width) / session.scale,
                                         height: Double(pixels.height) / session.scale)
            CATransaction.commit()
            session.setGrid(columns: grid.columns, rows: grid.rows, drawn: true)
            presence.offer(session.fitting(width: bounds.width, height: bounds.height))
        } else {
            session.layer.frame = bounds
            CATransaction.commit()
            session.setSize(width: bounds.width, height: bounds.height)
        }
        updateSelectionHandles()
        if let sized = onSized {
            onSized = nil
            sized()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, session.layer.superlayer !== layer { layer.insertSublayer(session.layer, at: 0) }
        guard window != nil else {
            blinkTimer?.invalidate(); blinkTimer = nil
            // Another view may show the presence by now (it took the session's layer): leave its frames on.
            if session.layer.superlayer === layer { session.setVisible(false) }
            return
        }
        session.setVisible(true)
        session.setScale(traitCollection.displayScale > 0 ? traitCollection.displayScale : 3)
        if blinkTimer == nil {
            let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.session.blinkTick() } }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        }
        setNeedsLayout()
    }

    /// One cell in points.
    var cellSize: CGSize {
        let size = session.currentSize, scale = session.scale
        return CGSize(width: Double(size.cellWidth) / scale, height: Double(size.cellHeight) / scale)
    }

    /// The grid's top left in points (the padding).
    var gridOrigin: CGPoint {
        let padding = session.locked { session.surface.size.padding }
        return CGPoint(x: Double(padding.left) / session.scale, y: Double(padding.top) / session.scale)
    }

    /// The viewport cell under a point in this view.
    func cell(at point: CGPoint) -> (x: Int, y: Int) {
        session.locked { session.surface.touchCell(x: point.x * session.scale, y: point.y * session.scale) }
    }

    /// A viewport cell's frame in this view.
    func rect(of cell: (x: Int, y: Int)) -> CGRect {
        let origin = gridOrigin, size = cellSize
        return CGRect(x: origin.x + Double(cell.x) * size.width, y: origin.y + Double(cell.y) * size.height, width: size.width, height: size.height)
    }

    func configure(_ configuration: TerminalConfiguration) {
        presence.configure(configuration)
        updateBackground()
        updateSelectionHandles()
    }

    private func updateBackground() {
        let bg = session.background
        backgroundColor = UIColor(red: CGFloat(bg.r) / 255, green: CGFloat(bg.g) / 255, blue: CGFloat(bg.b) / 255, alpha: 1)
    }

    private func handle(_ event: TerminalSession.Event) {
        switch event {
        case .selectionChanged: updateSelectionHandles()
        case .background(let r, let g, let b):
            backgroundColor = UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .bell: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        default: break
        }
    }

    /// The viewport's text (tests, accessibility).
    func visibleText() -> String { session.locked { String(decoding: session.surface.readText(.viewport), as: UTF8.self) } }

    /// VoiceOver reads the screen; UI tests check the terminal's output through it.
    override var accessibilityValue: String? {
        get { visibleText() }
        set {}
    }
}
