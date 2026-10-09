import AppKit
import SwiftUI
import Vision
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import DispatchApp

@MainActor
enum PresentationTestSupport {
    nonisolated private static func measured<T>(_ phase: String, file: StaticString, line: UInt,
                                    _ operation: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        defer {
            let elapsed = start.duration(to: .now)
            if elapsed >= .milliseconds(10) {
                let components = elapsed.components
                let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
                let name = URL(fileURLWithPath: String(describing: file)).lastPathComponent
                print(String(format: "Presentation phase %@ %@:%llu elapsed=%.3f",
                             phase, name, UInt64(line), seconds))
            }
        }
        return try operation()
    }

    /// Captures pixels immediately; callers choose when animation or asynchronous
    /// content has settled. OCR runs only when a test asks for recognized text.
    final class Snapshot {
        let bitmap: NSBitmapImageRep
        /// WindowServer has reached the AppKit window frame used for hit testing.
        let positioned: Bool
        static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        private var observations: [String: [VNRecognizedTextObservation]] = [:]

        init(bitmap: NSBitmapImageRep, positioned: Bool = true) {
            self.bitmap = bitmap; self.positioned = positioned
        }

        /// The same pixels at twice the size: macOS 27 OCR sometimes reads nothing for small or dim text that it
        /// reads when enlarged (macOS 26 reads both). Vision's normalized boxes are the same in both.
        lazy var enlarged: Snapshot = {
            let image = bitmap.cgImage!, width = image.width * 2, height = image.height * 2
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return Snapshot(bitmap: NSBitmapImageRep(cgImage: context.makeImage()!), positioned: positioned)
        }()

        /// Whether OCR reads any of `candidates`. Retries without language correction (macOS 27 corrects "tmux" to
        /// "tux" and "event.id" to "event. id"), then the same on the enlarged pixels. Retries only add ways to pass.
        func reads(_ candidates: [String], in region: CGRect = Snapshot.whole, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
            try [self, enlarged].contains { snapshot in
                try [true, false].contains { corrected in
                    try ([region] + snapshot.tiles(region)).contains { part in
                        let text = try snapshot.text(in: part, corrected: corrected, file: file, line: line)
                        return candidates.contains { text.contains($0) }
                    }
                }
            }
        }

        /// Where OCR reads `text`, by the same retries as `reads`. Vision boxes are relative to the region read;
        /// the result is normalized to the whole image (bottom-left origin) for clicking.
        func box(of text: String, file: StaticString = #filePath, line: UInt = #line) throws -> CGRect? {
            for snapshot in [self, enlarged] {
                for corrected in [true, false] {
                    for part in [Snapshot.whole] + snapshot.tiles(Snapshot.whole) {
                        for observation in try snapshot.recognizedText(in: part, corrected: corrected, file: file, line: line) {
                            guard let candidate = observation.topCandidates(1).first,
                                  let range = candidate.string.range(of: text),
                                  let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                            return CGRect(x: part.minX + box.minX * part.width, y: part.minY + box.minY * part.height,
                                          width: box.width * part.width, height: box.height * part.height)
                        }
                    }
                }
            }
            return nil
        }

        /// macOS 27 Vision drops lines or reads text upside down in narrow images taller than about 1475 pixels; the
        /// same text in a shorter image reads (measured 2026-10-01, macOS 26 reads both). Overlapping tiles of a taller
        /// region stay below that height; each tile overlaps the next by half, so every text line lies inside one.
        private func tiles(_ region: CGRect) -> [CGRect] {
            let tile = 1400 / CGFloat(bitmap.pixelsHigh), step = tile / 2
            guard region.height > tile else { return [] }
            return (0...Int(((region.height - tile) / step).rounded(.up))).map {
                CGRect(x: region.minX, y: max(region.minY, region.maxY - tile - CGFloat($0) * step), width: region.width, height: tile)
            }
        }

        /// `region` keeps unrelated columns out of Vision's reading order. Coordinates are Vision's: normalized,
        /// bottom-left origin.
        func recognizedText(in region: CGRect = Snapshot.whole, corrected: Bool = true, file: StaticString = #filePath,
                            line: UInt = #line) throws -> [VNRecognizedTextObservation] {
            let key = "\(region) \(corrected)"
            if let cached = observations[key] { return cached }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = corrected
            request.regionOfInterest = region.intersection(Snapshot.whole)
            // Keep the current input even if Vision never returns (one image per call site).
            let input = "ocr-input-\(URL(fileURLWithPath: String(describing: file)).lastPathComponent)-\(line)"
            try PresentationTestSupport.save(bitmap, named: input, in: "ui-audit", file: file, line: line)
            print("Vision input \(input) size=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) region=\(request.regionOfInterest) corrected=\(corrected) revision=\(request.revision)")
            do {
                try measured("ocr", file: file, line: line) {
                    try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage, file: file, line: line)).perform([request])
                }
            } catch {
                let name = "ocr-failure-\(UUID().uuidString)"
                print("Vision failure \(file):\(line) image=\(name) size=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) region=\(request.regionOfInterest) corrected=\(corrected) revision=\(request.revision) device=automatic error=\(error)")
                do { try PresentationTestSupport.save(bitmap, named: name, in: "ui-audit", file: file, line: line) }
                catch { print("Vision failure image save failed: \(error)") }
                throw error
            }
            let result = request.results ?? []
            observations[key] = result
            return result
        }

        // Vision can split one rendered line into multiple observations. Those
        // chunk boundaries are not reliable line breaks for text assertions.
        func text(in region: CGRect = Snapshot.whole, separator: String = " ", corrected: Bool = true,
                  file: StaticString = #filePath, line: UInt = #line) throws -> String {
            try recognizedText(in: region, corrected: corrected, file: file, line: line)
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: separator)
        }
    }

    static func capture(_ window: NSWindow, named name: String? = nil, in directory: String = "ui-audit",
                        file: StaticString = #filePath, line: UInt = #line) async throws -> Snapshot {
        try await capture(XCTUnwrap(window.contentView, file: file, line: line), named: name, in: directory, file: file, line: line)
    }

    static func capture(_ view: NSView, named name: String? = nil, in directory: String = "ui-audit",
                        file: StaticString = #filePath, line: UInt = #line) async throws -> Snapshot {
        measured("layout", file: file, line: line) { view.layoutSubtreeIfNeeded() }
        let bitmap: NSBitmapImageRep, positioned: Bool
        if #available(macOS 14.4, *), let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor {
            // Independent child filters report child bounds but can return parent pixels.
            // Capture the root explicitly, including native children where needed.
            var root = window
            for ancestor in sequence(first: window, next: { $0.parent ?? $0.sheetParent }) { root = ancestor }
            var metadata: SCShareableContent?
            // AppKit can expose a visible window before WindowServer publishes its bounds.
            try await TestSupport.eventually(file: file, line: line, diagnostic: "Capture window not published: \(root.windowNumber), frame=\(root.frame)") {
                do { metadata = try await SCShareableContent.currentProcess }
                catch {
                    print("Presentation metadata failed: window=\(window.windowNumber), visible=\(window.isVisible), frame=\(window.frame), error=\(error)")
                    throw error
                }
                return metadata?.windows.first { $0.windowID == CGWindowID(root.windowNumber) }?.frame.isEmpty == false
            }
            let content = try XCTUnwrap(metadata, file: file, line: line)
            let source = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(root.windowNumber) }, file: file, line: line)
            let bounds = window.convertToScreen(view.convert(view.bounds, to: nil))
            let desktop = try XCTUnwrap(NSScreen.screens.first, file: file, line: line).frame
            let rect = CGRect(x: bounds.minX, y: desktop.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
            let expected = CGRect(x: window.frame.minX, y: desktop.maxY - window.frame.maxY,
                                  width: window.frame.width, height: window.frame.height)
            let actual = content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }?.frame
            positioned = actual == expected
            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            let filter: SCContentFilter, extent: CGRect
            if root.frame.contains(bounds) {
                // Independent windows retain their pixels even outside the physical display.
                filter = SCContentFilter(desktopIndependentWindow: source)
                configuration.width = Int(root.frame.width * root.backingScaleFactor)
                configuration.height = Int(root.frame.height * root.backingScaleFactor)
                configuration.ignoreShadowsSingleWindow = true
                extent = CGRect(x: root.frame.minX, y: desktop.maxY - root.frame.maxY,
                                width: root.frame.width, height: root.frame.height)
            } else {
                // A child can extend beyond its parent's image; capture that visible group
                // through the display, excluding unrelated windows and desktop content.
                let display = try XCTUnwrap(content.displays.first { $0.frame.contains(rect) },
                    "View capture is not contained by a display: view=\(rect), displays=\(content.displays.map(\.frame))", file: file, line: line)
                filter = SCContentFilter(display: display, including: [source])
                configuration.width = Int(bounds.width * window.backingScaleFactor)
                configuration.height = Int(bounds.height * window.backingScaleFactor)
                configuration.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                configuration.includeChildWindows = true
                extent = rect
            }
            let image: CGImage
            do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) }
            catch {
                print("Presentation image failed: window=\(window.windowNumber), source=\(source.windowID), sourceFrame=\(source.frame), onScreen=\(source.isOnScreen), filter=\(filter.contentRect), view=\(rect), error=\(error)")
                throw error
            }
            let x = CGFloat(image.width) / extent.width, y = CGFloat(image.height) / extent.height
            let crop = CGRect(x: (rect.minX - extent.minX) * x, y: (rect.minY - extent.minY) * y,
                              width: rect.width * x, height: rect.height * y)
            print("Presentation compositor \(name ?? "unnamed") window=\(window.windowNumber) parent=\(String(describing: window.parent?.windowNumber)) sheetParent=\(String(describing: window.sheetParent?.windowNumber)) root=\(root.windowNumber) bounds=\(view.bounds) frame=\(view.frame) contentLayout=\(window.contentLayoutRect) contentFrame=\(String(describing: window.contentView?.frame)) contentBounds=\(String(describing: window.contentView?.bounds)) style=\(window.styleMask.rawValue) source=\(source.frame) filter=\(filter.contentRect) extent=\(extent) view=\(rect) actual=\(String(describing: actual)) expected=\(expected) positioned=\(positioned) crop=\(crop) image=\(image.width)x\(image.height)")
            let pixels = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(pixels.contains(crop) ? image.cropping(to: crop) : nil,
                "View capture exceeds image: crop=\(crop), image=\(pixels)", file: file, line: line))
        } else {
            return try render(view, named: name, in: directory, file: file, line: line)
        }
        if let name { try save(bitmap, named: name, in: directory, file: file, line: line) }
        return Snapshot(bitmap: bitmap, positioned: positioned)
    }

    /// AppKit's offscreen rendering, also retained beside failed compositor captures for diagnosis.
    static func render(_ view: NSView, named name: String? = nil, in directory: String = "ui-audit",
                       file: StaticString = #filePath, line: UInt = #line) throws -> Snapshot {
        measured("layout", file: file, line: line) { view.layoutSubtreeIfNeeded() }
        let bitmap = try measured("allocate", file: file, line: line) {
            try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), file: file, line: line)
        }
        measured("render", file: file, line: line) { view.cacheDisplay(in: view.bounds, to: bitmap) }
        if let name { try save(bitmap, named: name, in: directory, file: file, line: line) }
        return Snapshot(bitmap: bitmap)
    }

    nonisolated static func save(_ bitmap: NSBitmapImageRep, named name: String, in directory: String,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build").appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let png = try measured("png", file: file, line: line) {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), file: file, line: line)
        }
        try measured("write", file: file, line: line) {
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
    }

    /// Frames, in window coordinates, of the accessibility elements with `identifier` (and `label`, when given).
    /// SwiftUI controls have no NSView of their own, and SwiftUI vends their accessibility elements only to an
    /// assistive client: the lookup sets the enhanced-interface attribute VoiceOver sets, then restores it.
    static func accessibilityFrames(_ identifier: String, label: String? = nil, in window: NSWindow) -> [NSRect] {
        accessibilityFrames(matching: { $0 == identifier }, label: label, in: window)
    }

    /// Frames of the accessibility elements whose identifier satisfies `matches`, e.g. a per-row identifier's prefix.
    static func accessibilityFrames(matching matches: (String) -> Bool, label: String? = nil, in window: NSWindow) -> [NSRect] {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced) as? Bool ?? false
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        var frames: [NSRect] = [], visited: Set<ObjectIdentifier> = []
        // SwiftUI's elements implement the NSAccessibility methods without declaring the protocol in Swift.
        func visit(_ element: AnyObject, depth: Int) {
            guard depth < 64, visited.insert(ObjectIdentifier(element)).inserted else { return }
            if let identifier = element.accessibilityIdentifier?(), matches(identifier), label.map({ element.accessibilityLabel?() == $0 }) ?? true,
               let frame = element.accessibilityFrame?() {
                frames.append(window.convertFromScreen(frame))
            }
            for child in element.accessibilityChildren?() ?? [] { visit(child as AnyObject, depth: depth + 1) }
        }
        // Hosting views nested in AppKit containers (split views, representables) are not always reachable as
        // accessibility children of the window's root, so start from every view as well.
        if let root = window.contentView {
            for view in [root] + views(of: NSView.self, in: root, includingNestedMatches: true) { visit(view, depth: 0) }
        }
        return frames
    }

    static func views<T: NSView>(of type: T.Type, in root: NSView, includingNestedMatches: Bool = false) -> [T] {
        let matches = (root as? T).map { [$0] } ?? []
        if !includingNestedMatches, !matches.isEmpty { return matches }
        return matches + root.subviews.flatMap { views(of: type, in: $0, includingNestedMatches: includingNestedMatches) }
    }

    /// Visible text: OCR (retried on enlarged pixels) must read `exact` or one of `variants`, spellings a macOS
    /// release's OCR produces for the same correct pixels (macOS 27 splits a terminal marker around the next prompt). With `rendered`, the
    /// text drawn there must also contain `exact`, so a variant cannot hide a real change. Leave `rendered` out where
    /// the text is not readable that way (composed Text, or views whose view-debug data SwiftUI cannot produce).
    static func assertText(_ exact: String, _ variants: [String] = [], in snapshot: Snapshot, rendered root: NSView? = nil,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let read = try snapshot.reads([exact] + variants, file: file, line: line)
        XCTAssertTrue(read, "OCR: \((try? snapshot.text()) ?? "") | uncorrected: \((try? snapshot.text(corrected: false)) ?? "")"
                      + " | enlarged: \((try? snapshot.enlarged.text()) ?? "")",
                      file: file, line: line)
        guard let root else { return }
        try assertRendered(exact, in: root, file: file, line: line)
    }

    /// The exact half of assertText alone, for callers that check OCR themselves.
    static func assertRendered(_ exact: String, in root: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let texts = try renderedText(root, file: file, line: line)
        XCTAssertTrue(texts.contains { $0.contains(exact) }, "Rendered: \(texts)", file: file, line: line)
    }

    /// Text drawn under `root`: strings SwiftUI resolved for drawing, from its view-debug tree (the data Xcode's view
    /// debugger reads; recorded only when SWIFTUI_VIEW_DEBUG is set for the test process), plus AppKit text views.
    static func renderedText(_ root: NSView, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let all = views(of: NSView.self, in: root, includingNestedMatches: true)
        let hosts = all.compactMap { $0 as? ViewDebugging }
        let trees = try hosts.map { host in
            try XCTUnwrap(_ViewDebug.serializedData(host._viewDebugData()).flatMap { try? JSONSerialization.jsonObject(with: $0) },
                          file: file, line: line)
        }
        // AppKit text views draw their own storage; SwiftUI's tree does not contain them.
        let appKit = all.compactMap { ($0 as? NSTextView)?.string ?? ($0 as? NSTextField)?.stringValue }
        let texts = trees.flatMap(resolvedStrings) + appKit
        XCTAssertFalse(texts.isEmpty, "No SwiftUI view-debug text; run tests with SWIFTUI_VIEW_DEBUG set", file: file, line: line)
        return texts
    }

    // Drawn text appears as a resolved NSAttributedString (description "run{ attributes }run{ attributes }", runs
    // without their attribute blocks are the text) or, for selectable Text, as the AttributedString it draws.
    private static func resolvedStrings(_ node: Any) -> [String] {
        if let object = node as? [String: Any] {
            let type = object["type"] as? String ?? "", value = object["value"] as? String
            if let value, type == "Foundation.AttributedString" || type.hasPrefix("NSConcrete") && type.hasSuffix("AttributedString") {
                return [value.replacingOccurrences(of: #"\{\n([^\n]*\n)*?\}"#, with: "", options: .regularExpression)]
            }
            return object.values.flatMap(resolvedStrings)
        }
        return (node as? [Any])?.flatMap(resolvedStrings) ?? []
    }

    // macOS 27 SwiftUI keeps a styled TextField prompt only in placeholderAttributedString; macOS 26 used placeholderString.
    static func placeholder(of field: NSTextField) -> String? {
        field.placeholderString ?? field.placeholderAttributedString?.string
    }

    static func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint,
                           file: StaticString = #filePath, line: UInt = #line) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: type == .leftMouseUp ? 1 : 0, clickCount: 1, pressure: 1), file: file, line: line)
    }

    static func click(_ window: NSWindow, at point: NSPoint, file: StaticString = #filePath, line: UInt = #line) throws {
        let down = try mouseEvent(.leftMouseDown, in: window, at: point, file: file, line: line)
        let up = try mouseEvent(.leftMouseUp, in: window, at: point, file: file, line: line)
        // AppKit buttons and drag trackers may run a nested event loop on down.
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
    }

    /// Moves the pointer over a point before clicking it, as a user does.
    /// SwiftUI buttons in a window that is not frontmost track hover first.
    static func hoverAndClick(_ window: NSWindow, at point: NSPoint) async throws {
        let screen = window.convertPoint(toScreen: point), desktop = try XCTUnwrap(NSScreen.screens.first)
        let cursor = CGPoint(x: screen.x, y: desktop.frame.maxY - screen.y)
        XCTAssertEqual(CGWarpMouseCursorPosition(cursor), .success)
        let move = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: cursor, mouseButton: .left))
        move.postToPid(getpid())
        window.sendEvent(try mouseEvent(.mouseMoved, in: window, at: point))
        try await Task.sleep(for: .milliseconds(150))
        try click(window, at: point)
    }

    /// Selects a Settings tab by clicking its visible label.
    static func selectSettingsTab(_ title: String, in window: NSWindow) async throws {
        let root = try XCTUnwrap(window.contentView)
        var label: CGRect?, seen: [String] = []
        try await TestSupport.eventually(diagnostic: "No \(title) Settings tab in \(seen)") {
            // Capture the content view: its OCR boxes share the coordinates the click converts.
            // Vision can read neighbouring tabs as one line; then click the title's part of it.
            let candidates = try await capture(root).recognizedText().compactMap { $0.topCandidates(1).first }
            seen = candidates.map(\.string)
            if let exact = candidates.first(where: { $0.string == title }) {
                label = try exact.boundingBox(for: exact.string.startIndex..<exact.string.endIndex)?.boundingBox
            } else if let line = candidates.first(where: { $0.string.contains(title) }), let range = line.string.range(of: title) {
                label = try line.boundingBox(for: range)?.boundingBox
            } else if let word = title.split(separator: " ").first.map(String.init), word != title,
                      let part = candidates.first(where: { $0.string == word }) {
                // …or split one ("Spaces", "& Tabs"); its first word is still on the tab.
                label = try part.boundingBox(for: part.string.startIndex..<part.string.endIndex)?.boundingBox
            }
            return label != nil
        }
        let box = try XCTUnwrap(label)
        try await hoverAndClick(window, at: root.convert(NSPoint(x: box.midX * root.bounds.width,
            y: (root.isFlipped ? 1 - box.midY : box.midY) * root.bounds.height), to: nil))
    }

    /// Opens the sidebar's space search as ⌘P does and returns its field.
    static func openSpaceSearch(_ controller: AppDelegate, in root: NSView) async throws -> NSTextField {
        controller.focusSpaceSearch()
        var field: NSTextField?
        try await TestSupport.eventually {
            field = views(of: NSTextField.self, in: root).first { placeholder(of: $0) == "Search spaces…" }
            return field != nil
        }
        return try XCTUnwrap(field)
    }

    static func chooseNewSpace(_ title: String = "New space", in workspace: Workspace, host: HostID = .local) async throws {
        // The new-space control's own option builder. NSMenu owns a modal tracking loop, so run the
        // supplied menu action without blocking the async test's main-actor executor.
        let choices = await NewSpaceMenu.groups(workspace: workspace, host: nil).flatMap(\.options)
        let choice = try XCTUnwrap(choices.first { $0.choice.label == title && $0.choice.host == host }, "Missing new-space option: \(title) on \(host)")
        try XCTUnwrap(choice.action)()
    }

    static func chooseNewSpaceOption(_ title: String, in window: NSWindow) async throws {
        var chosen: (NSWindow, NSPoint)?
        var observed = ""
        try await TestSupport.eventually(diagnostic: "Missing new-space option: \(title); observed: \(observed)") {
            for popup in NSApp.windows where popup.isVisible && popup !== window {
                guard let content = popup.contentView else { continue }
                let snapshot = try await capture(content)
                observed = try snapshot.text()
                if let box = try textRow(title, in: snapshot) {
                    try save(snapshot.bitmap, named: title, in: "new-space-validation")
                    let point = NSPoint(x: box.midX * content.bounds.width,
                        y: (content.isFlipped ? 1 - box.midY : box.midY) * content.bounds.height)
                    chosen = (popup, content.convert(point, to: nil))
                    return true
                }
            }
            return false
        }
        let (popup, point) = try XCTUnwrap(chosen)
        try click(popup, at: point)
        try await TestSupport.eventually(diagnostic: "New-space popup did not dismiss") { !popup.isVisible }
    }

    private static func textRow(_ title: String, in snapshot: Snapshot) throws -> CGRect? {
        let observations = try snapshot.recognizedText()
        for anchor in observations {
            // Vision can split a label into several observations on one line.
            let row = observations.filter { abs($0.boundingBox.midY - anchor.boundingBox.midY) < anchor.boundingBox.height / 2 }
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let label = row.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if label == title || label.hasPrefix(title + " ") || label.hasSuffix(" " + title) || label.contains(" " + title + " ") {
                return row.reduce(CGRect.null) { $0.union($1.boundingBox) }
            }
        }
        return nil
    }

    static func chooseTmuxLayout(_ title: String, in window: NSWindow) async throws {
        let view = try XCTUnwrap(window.contentView)
        // The 32-point tmux tab strip sits immediately below the title row.
        try click(window, at: view.convert(NSPoint(x: view.bounds.width - 21, y: view.isFlipped ? 55 : view.bounds.height - 55), to: nil))
        var chosen: (NSWindow, NSPoint)?
        var observed = ""
        try await TestSupport.eventually(diagnostic: "Missing layout option: \(title); observed: \(observed)") {
            for popup in NSApp.windows where popup.isVisible && popup !== window {
                guard let content = popup.contentView else { continue }
                let snapshot = try await capture(content)
                observed = try snapshot.text()
                if let box = try textRow(title, in: snapshot) {
                    let point = NSPoint(x: box.midX * content.bounds.width,
                        y: (content.isFlipped ? 1 - box.midY : box.midY) * content.bounds.height)
                    try save(snapshot.bitmap, named: "tmux-layout-options", in: "integration-audit")
                    chosen = (popup, content.convert(point, to: nil))
                    return true
                }
            }
            return false
        }
        let (popup, point) = try XCTUnwrap(chosen)
        try click(popup, at: point)
    }
}

/// NSHostingView is generic; this gives the view-debug walk one type for every hosting view.
@MainActor protocol ViewDebugging { func _viewDebugData() -> [_ViewDebug.Data] }
extension NSHostingView: ViewDebugging {}
