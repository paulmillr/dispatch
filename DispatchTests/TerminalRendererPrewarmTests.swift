import Metal
import XCTest
@_spi(Test) import TermApple

/// The renderer's shared library and pipelines made ahead of the first renderer (`MetalRenderer.prewarm`, which the
/// phone runs at launch): made once, a renderer made after them compiles nothing, and one made while they compile
/// waits for them. Each case has a pixel format of its own, so no other renderer in the process (the phone's own
/// launch prewarm) counts in its checks, and forgets that format's pipelines first, so it can run again in one process.
@MainActor
final class TerminalRendererPrewarmTests: XCTestCase {
    func testPrewarmMakesThePipelinesOnceAndLaterRenderersCompileNothing() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let format = MTLPixelFormat.rgba8Unorm
        MetalRenderer.forgetPipelines(device, format)
        try MetalRenderer.prewarm(device: device, pixelFormat: format)
        XCTAssertEqual(MetalRenderer.librariesMade(device, format), 1)
        try MetalRenderer.prewarm(device: device, pixelFormat: format)
        let renderers = try (0..<3).map { _ in try MetalRenderer(device: device, pixelFormat: format) }
        XCTAssertEqual(MetalRenderer.librariesMade(device, format), 1, "a second prewarm and later renderers compile nothing")
        XCTAssertEqual(renderers.map(\.pixelFormat), [format, format, format])
    }

    /// The prewarm's compile is held at its start (the lock taken, nothing compiled yet) while a renderer is made on
    /// another thread: the renderer is seen waiting for the lock and not returning while the compile is held, then
    /// returns with the prewarm's pipelines once it is let go, nothing compiled twice.
    func testARendererMadeWhileAPrewarmCompilesWaitsForItAndCompilesNothing() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let format = MTLPixelFormat.bgra8Unorm_srgb
        MetalRenderer.forgetPipelines(device, format)
        let gate = CompileGate()
        MetalRenderer.whileCompiling { if $0 == format { gate.compile() } }
        // Released on every path: a held compile keeps the renderers' lock (at most 30 s).
        defer {
            gate.release()
            MetalRenderer.whileCompiling(nil)
        }
        Thread {
            try? MetalRenderer.prewarm(device: device, pixelFormat: format)
            gate.state.update { $0.prewarmed = true }
        }.start()
        try await TestSupport.eventually(diagnostic: "the prewarm never started compiling") { gate.state.value.held }

        Thread {
            let renderer = try? MetalRenderer(device: device, pixelFormat: format)
            gate.state.update { $0.rendered = renderer?.pixelFormat ?? .invalid }
        }.start()
        try await TestSupport.eventually(diagnostic: "the renderer never asked for the pipelines") {
            MetalRenderer.pipelinesWaiting(device, format) == 1
        }
        XCTAssertNil(gate.state.value.rendered, "the renderer waits while the prewarm compiles")
        XCTAssertFalse(gate.state.value.prewarmed, "the compile is still held")

        gate.release()
        try await TestSupport.eventually(diagnostic: "the renderer never returned") {
            gate.state.value.rendered != nil && gate.state.value.prewarmed
        }
        XCTAssertEqual(gate.state.value.rendered, format, "the renderer was made")
        XCTAssertEqual(gate.state.value.compiles, 1, "with the prewarm's pipelines")
        XCTAssertEqual(MetalRenderer.librariesMade(device, format), 1)
        XCTAssertEqual(MetalRenderer.pipelinesWaiting(device, format), 0)
    }
}

/// Holds the first compile at its start until released (at most 30 s), and counts compiles; a second compile (a
/// renderer that did not wait) is counted and not held.
private final class CompileGate: @unchecked Sendable {
    struct State {
        var held = false, prewarmed = false, compiles = 0
        var rendered: MTLPixelFormat?
    }

    final class Locked: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = State()

        var value: State {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func update(_ change: (inout State) -> Void) {
            lock.lock()
            change(&stored)
            lock.unlock()
        }
    }

    let state = Locked()
    private let released = DispatchSemaphore(value: 0)

    func compile() {
        var first = false
        state.update { state in
            state.compiles += 1
            first = state.compiles == 1
            if first { state.held = true }
        }
        if first { _ = released.wait(timeout: .now() + 30) }
    }

    func release() { released.signal() }
}
