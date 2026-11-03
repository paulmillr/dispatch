import IOSurface
import Metal
import XCTest
@_spi(Test) import Term
@_spi(Test) import TermApple
@testable import DispatchApp

/// A hidden terminal gives back its GPU memory (HiddenResources) and draws the same frame when shown again; every
/// terminal on a device shares the shader library and pipelines.
@MainActor
final class TerminalGPUResourcesTests: XCTestCase {
    private let (width, height) = (480, 320)

    /// A session whose layer has a size (the layer's display() draws into its swap chain, as when hosted).
    private func session(_ text: String = "") throws -> Session {
        let session = try Session(config: SwiftEngine.parse("", dark: true), scale: 1, machine: System.machine.launch)
        session.layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        session.setSize(width: width, height: height)
        session.locked { Array(text.utf8).withUnsafeBufferPointer { session.surface.feed($0) } }
        return session
    }

    /// Draws into every swap-chain target, as a few frames on screen do.
    private func show(_ session: Session) {
        for _ in 0..<3 { session.refresh(); session.layer.display() }
    }

    private func pixels(_ session: Session) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        (descriptor.usage, descriptor.storageMode) = ([.renderTarget, .shaderRead], .shared)
        let target = try XCTUnwrap(session.device.makeTexture(descriptor: descriptor))
        let commands = try XCTUnwrap(session.render(into: target), "Metal frame was not submitted")
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    private let image = "\u{1b}_Ga=T,f=32,s=1,v=1,i=7,c=2,r=1,C=1,q=2;" + Data([255, 0, 0, 255]).base64EncodedString() + "\u{1b}\\"

    func testHiddenTerminalReleasesItsGPUMemoryAndShowsTheSameFrameAgain() throws {
        let session = try session("\u{1b}[1;31mSam Example\u{1b}[m 日本語 😀\r\n" + image + "\r\nprompt$ ")
        defer { session.close() }
        show(session)
        let before = try pixels(session)
        let text = session.locked { session.surface.readText(.active) }
        XCTAssertGreaterThan(session.gpuBytes, 3 * width * height * 4, "three targets and the renderer's buffers")
        XCTAssertNotNil(session.layer.contents)

        session.setVisible(false)
        HiddenResources.releaseHidden()
        XCTAssertEqual(session.gpuBytes, 0)
        XCTAssertNil(session.layer.contents)
        XCTAssertEqual(session.locked { session.surface.readText(.active) }, text, "contents and history stay")

        // Shown again: a frame is in the layer before the view appears, and it is the frame from before.
        session.setVisible(true)
        XCTAssertNotNil(session.layer.contents)
        XCTAssertGreaterThan(session.gpuBytes, 0)
        XCTAssertTrue(try pixels(session) == before, "the image, emoji and text draw as before")
    }

    func testQuickSwitchesKeepTheMemoryAndAHiddenTabReleasesAfterTheRetention() async throws {
        let retention = HiddenResources.retention
        defer { HiddenResources.retention = retention }
        let session = try session("Sam Example")
        defer { session.close() }
        show(session)
        let held = session.gpuBytes
        // Hidden and shown before the retention can pass (in the same turn of the main queue): nothing is released.
        for _ in 0..<20 {
            session.setVisible(false)
            XCTAssertTrue(session.hiddenResources.scheduled)
            session.setVisible(true)
            XCTAssertFalse(session.hiddenResources.scheduled)
        }
        XCTAssertEqual(session.gpuBytes, held)
        HiddenResources.retention = 0
        session.setVisible(false)
        try await TestSupport.eventually(timeout: .seconds(5)) { session.gpuBytes == 0 }
        session.setVisible(true)
        XCTAssertNotNil(session.layer.contents)
    }

    func testCoveredTerminalReleasesOnlyOnMemoryPressure() throws {
        let session = try session("Sam Example")
        defer { session.close() }
        show(session)
        session.setVisible(false, release: .onMemoryPressure)
        XCTAssertFalse(session.hiddenResources.scheduled, "a covered window may be revealed before a new frame is ready")
        XCTAssertGreaterThan(session.gpuBytes, 0)
        HiddenResources.releaseHidden()
        XCTAssertEqual(session.gpuBytes, 0)
        session.setVisible(true)
        XCTAssertNotNil(session.layer.contents)
    }

    func testReleasedTerminalFollowsResizesDisplayChangesAndClosing() throws {
        let session = try session("Sam Example\r\n" + image)
        show(session)
        session.setVisible(false)
        HiddenResources.releaseHidden()
        // While hidden: a new size, a new scale and a display change draw nothing and make no targets.
        session.layer.bounds = CGRect(x: 0, y: 0, width: width / 2, height: height / 2)
        session.layer.display()
        session.setSize(width: width / 2, height: height / 2)
        session.setScale(2)
        session.relink()
        XCTAssertEqual(session.gpuBytes, 0)
        XCTAssertNil(session.layer.contents)
        session.setVisible(true)
        let shown = try XCTUnwrap(session.layer.contents)
        XCTAssertEqual(IOSurfaceGetWidth(shown as! IOSurfaceRef), width / 2 * 2, "drawn at the layer's new size and scale")
        // Closing a hidden terminal with a release pending, or a released one, leaves nothing behind.
        session.setVisible(false)
        session.close()
        HiddenResources.releaseHidden()
        XCTAssertEqual(session.gpuBytes, 0)
    }

    func testRapidSwitchingAlwaysShowsAFrame() throws {
        let sessions = try (0..<4).map { try session("terminal \($0)") }
        defer { sessions.forEach { $0.close() } }
        sessions.forEach(show)
        for round in 0..<25 {
            let shown = sessions[round % sessions.count]
            for s in sessions where s !== shown { s.setVisible(false) }
            if round % 3 == 0 { HiddenResources.releaseHidden() }
            shown.setVisible(true)
            XCTAssertNotNil(shown.layer.contents, "round \(round)")
        }
    }

    func testRenderersShareTheirPipelines() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        _ = try MetalRenderer(device: device)
        let made = MetalRenderer.librariesMade
        let renderers = try (0..<10).map { _ in try MetalRenderer(device: device) }
        XCTAssertEqual(MetalRenderer.librariesMade, made, "one library and its pipelines per device and pixel format")
        XCTAssertEqual(renderers.count, 10)
        _ = try MetalRenderer(device: device, pixelFormat: .rgba16Float)
        XCTAssertEqual(MetalRenderer.librariesMade, made + 1)
    }
}

extension TerminalGPUResourcesTests {
    /// Hosts report visibility often (every helper scroll report, every occlusion notice): hiding again the same way
    /// keeps the retention running from the first report.
    func testRepeatedHideReportsStillReleaseAfterTheRetention() async throws {
        let retention = HiddenResources.retention
        defer { HiddenResources.retention = retention }
        HiddenResources.retention = 0.3
        let session = try session("Sam Example")
        defer { session.close() }
        show(session)
        session.setVisible(false)
        // Every poll (25 ms) reports hidden again, far more often than the retention.
        try await TestSupport.eventually(timeout: .seconds(5)) {
            session.setVisible(false)
            return session.gpuBytes == 0
        }
        XCTAssertEqual(session.hiddenResources.hiddenPolicy, .afterRetention)
    }

    /// A covered window's terminal released on memory pressure keeps showing its last frame (the window server can
    /// reveal it before the app hears so); a hidden tab's releases that frame too.
    func testACoveredTerminalKeepsShowingItsLastFrame() throws {
        let covered = try session("Sam Example"), hidden = try session("Sam Example")
        defer { covered.close(); hidden.close() }
        show(covered); show(hidden)
        covered.setVisible(false, release: .onMemoryPressure)
        hidden.setVisible(false)
        let last = covered.layer.contents.map { $0 as! IOSurfaceRef }
        HiddenResources.releaseHidden()
        XCTAssertEqual(covered.gpuBytes, 0)
        XCTAssertTrue(covered.layer.contents.map { $0 as! IOSurfaceRef } === last, "the last frame stays")
        XCTAssertNil(hidden.layer.contents)
        covered.setVisible(true)
        let next = try XCTUnwrap(covered.layer.contents.map { $0 as! IOSurfaceRef })
        XCTAssertFalse(next === last, "a new frame replaced it")
    }
}
