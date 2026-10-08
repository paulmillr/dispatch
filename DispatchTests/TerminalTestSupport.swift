import AppKit
import Term
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import DispatchApp

@MainActor
enum TerminalTestSupport {
    static func assertScrollbar(in terminal: TerminalView, bottomMarker: String) async throws {
        try await TestSupport.eventually { !terminal.scrollbar.isHidden && terminal.scrollbar.state.canScroll }
        let size = try XCTUnwrap(terminal.surface).grid
        let scrollbar = terminal.scrollbar
        XCTAssertEqual(scrollbar.superview, terminal)
        // Capture the composited window: view caching omits the renderer's Metal
        // layer and cannot reveal a renderer covering the native scrollbar.
        if #available(macOS 14.4, *), let window = terminal.window {
            let content = try await SCShareableContent.currentProcess
            let ownWindow = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * window.backingScaleFactor)
            configuration.height = Int(window.frame.height * window.backingScaleFactor)
            configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: ownWindow), configuration: configuration)
            try PresentationTestSupport.save(NSBitmapImageRep(cgImage: image), named: bottomMarker, in: "scrollbar-audit")
        }
        let window = try XCTUnwrap(terminal.window)
        let knob = scrollbar.rect(for: .knob), slot = scrollbar.rect(for: .knobSlot)
        let start = scrollbar.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
        let end = scrollbar.convert(NSPoint(x: knob.midX, y: scrollbar.isFlipped ? slot.minY + 1 : slot.maxY - 1), to: nil)
        // Queue tracking events before mouseDown enters AppKit's nested loop.
        NSApp.postEvent(try PresentationTestSupport.mouseEvent(.leftMouseUp, in: window, at: end), atStart: true)
        NSApp.postEvent(try PresentationTestSupport.mouseEvent(.leftMouseDragged, in: window, at: end), atStart: true)
        window.sendEvent(try PresentationTestSupport.mouseEvent(.leftMouseDown, in: window, at: start))
        try await TestSupport.eventually(diagnostic: viewport(terminal: terminal)) {
            !viewport(terminal: terminal).contains(bottomMarker) && !viewport(terminal: terminal).isEmpty
        }
        scrollbar.doubleValue = 1
        XCTAssertTrue(scrollbar.sendAction(scrollbar.action, to: scrollbar.target))
        try await TestSupport.eventually { viewport(terminal: terminal).contains(bottomMarker) }
        let after = try XCTUnwrap(terminal.surface).grid
        XCTAssertEqual(after.columns, size.columns, "The scrollbar must not resize the terminal grid")
        XCTAssertEqual(after.rows, size.rows)
    }

    static func send(_ command: String, to terminal: TerminalView) {
        terminal.insertText(command, replacementRange: NSRange(location: NSNotFound, length: 0))
        key(36, "\r", terminal)
    }

    static func assertPhysicalTyping(in window: NSWindow, terminal: TerminalView) async throws {
        func key(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = []) {
            NSApp.sendEvent(TerminalTestSupport.keyEvent(code, text, in: window, modifiers: modifiers))
            let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(up)
        }
        TerminalTestSupport.send("printf 'TYPE_%s\\n' READY; read -r typed; printf 'INPUT_<%s>\\n' \"$typed\"", to: terminal)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: terminal).contains("TYPE_READY") }
        window.makeFirstResponder(terminal)
        for (code, text): (UInt16, String) in [(37, "l"), (1, "s"), (36, "\r")] {
            key(code, text)
            try await Task.sleep(for: .milliseconds(75))
        }
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("INPUT_<ls>")
        }
        // Recolor the first character when the command becomes valid, just as
        // syntax-highlighting plugins do. This forces a redraw of existing text.
        TerminalTestSupport.send("PS1='INPUT> '; RPROMPT=; function typing_highlight { if [[ $BUFFER == ls ]]; then region_highlight=('0 2 fg=green'); else region_highlight=('0 1 fg=red'); fi; }; zle -N zle-line-pre-redraw typing_highlight; printf '\\e[2J\\e[H'", to: terminal)
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).trimmingCharacters(in: .whitespacesAndNewlines) == "INPUT>"
        }
        for (code, text, expected): (UInt16, String, String) in [(37, "l", "INPUT> l"), (1, "s", "INPUT> ls")] {
            key(code, text)
            try await Task.sleep(for: .milliseconds(75))
            try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
                TerminalTestSupport.screen(terminal: terminal).trimmingCharacters(in: .whitespacesAndNewlines) == expected
            }
        }
        key(32, "u", modifiers: .control)
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).trimmingCharacters(in: .whitespacesAndNewlines) == "INPUT>"
        }
        TerminalTestSupport.send("zle -D zle-line-pre-redraw; unfunction typing_highlight; clear && printf 'TERMINFO_%s\\n' READY", to: terminal)
        try await TestSupport.eventually(diagnostic: TerminalTestSupport.screen(terminal: terminal)) {
            TerminalTestSupport.screen(terminal: terminal).contains("TERMINFO_READY")
        }
    }

    static func keyEvent(_ code: UInt16, _ text: String, in window: NSWindow?,
                         modifiers: NSEvent.ModifierFlags = [], ignoringModifiers: String? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: text,
            charactersIgnoringModifiers: ignoringModifiers ?? text, isARepeat: false, keyCode: code)!
    }

    static func key(_ code: UInt16, _ text: String, _ terminal: TerminalView, modifiers: NSEvent.ModifierFlags = []) {
        terminal.keyDown(with: keyEvent(code, text, in: terminal.window, modifiers: modifiers))
    }

    static func screen(terminal: TerminalView) -> String {
        guard let surface = terminal.surface else { return "" }
        return screen(surface: surface)
    }

    static func screen(surface: any TerminalBackend) -> String {
        surface.readText(.screen)
    }

    static func viewport(terminal: TerminalView) -> String {
        guard let surface = terminal.surface else { return "" }
        return surface.readText(.viewport)
    }
}
