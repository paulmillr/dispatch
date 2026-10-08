import AppKit
import WebKit

@MainActor final class Renderer: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var web: WKWebView!
    var window: NSWindow!
    var loaded: CheckedContinuation<Void, any Error>?
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    func applicationDidFinishLaunching(_ notification: Notification) {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1800, height: 1100))
        web.navigationDelegate = self
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; window.makeKeyAndOrderFront(nil)
        Task {
            do { try await run() } catch { print("ERROR: \(error)"); exit(1) }
            NSApp.terminate(nil)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { loaded?.resume(throwing: error); loaded = nil }
    func run() async throws {
        let output = root.appendingPathComponent("build/mockup-review")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fonts = [("Regular", 400), ("Semibold", 600)].map { name, weight in
            let data = try! Data(contentsOf: root.appendingPathComponent("Dispatch/Resources/Fonts/SourceCodePro-\(name).ttf"))
            return "@font-face{font-family:'Source Code Pro';font-weight:\(weight);src:url(data:font/ttf;base64,\(data.base64EncodedString()))}"
        }.joined()
        let remove = try NSRegularExpression(pattern: #"<script[\s\S]*?</script>|<link[^>]*>"#)
        for name in ["Main", "Splits", "Chat mode", "Stats"] {
            let source = try String(contentsOf: root.appendingPathComponent("design/\(name).dc.html"), encoding: .utf8)
            var clean = remove.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "")
                .replacingOccurrences(of: "</head>", with: "<style>\(fonts)</style></head>")
            // Embed local image assets too; no network or file-loader access is needed.
            let images = try NSRegularExpression(pattern: #"src="(icon/[^" ]+)""#)
            for match in images.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).reversed() {
                let asset = String(clean[Range(match.range(at: 1), in: clean)!])
                let bytes = try Data(contentsOf: root.appendingPathComponent("design/" + asset))
                clean.replaceSubrange(Range(match.range(at: 1), in: clean)!, with: "data:image/png;base64," + bytes.base64EncodedString())
            }
            let regex = try NSRegularExpression(pattern: #"<div id="([^"]+)""#)
            let ids = regex.matches(in: clean, range: NSRange(clean.startIndex..., in: clean)).compactMap { Range($0.range(at: 1), in: clean).map { String(clean[$0]) } }
            for id in ids {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    loaded = continuation; web.loadHTMLString(clean, baseURL: root)
                }
                let literal = String(data: try JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed), encoding: .utf8)!
                _ = try await web.evaluateJavaScript("const target = document.getElementById(\(literal)); const css = [...document.querySelectorAll('style')].map(x=>x.outerHTML).join(''); document.body.innerHTML = css + target.outerHTML; document.body.style.padding='16px'; document.body.style.width='max-content';")
                try await Task.sleep(for: .milliseconds(150))
                let rect = try await web.evaluateJavaScript("(()=>{let r=document.getElementById(\(literal)).getBoundingClientRect(); return {width:r.width+32,height:r.height+32};})()") as! [String: Double]
                let size = NSSize(width: rect["width"]!, height: rect["height"]!)
                window.setContentSize(size); web.frame.size = size
                try await Task.sleep(for: .milliseconds(100))
                let config = WKSnapshotConfiguration(); config.rect = NSRect(origin: .zero, size: size)
                let image = try await web.takeSnapshot(configuration: config)
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                let filename = "\(name.replacingOccurrences(of: " ", with: "-"))-\(id).png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
                print(filename)
            }
        }
    }
}
MainActor.assumeIsolated {
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let renderer = Renderer(); app.delegate = renderer
app.run()
}
