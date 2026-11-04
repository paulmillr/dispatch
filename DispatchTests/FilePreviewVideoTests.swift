import AVFoundation
import AVKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// A video's Play in the Files preview: nothing read before it, a host's video copied to this Mac first (a dragged
/// row's copy), a video on this Mac played where it is, and the copy removed when the preview is left.
@MainActor
final class FilePreviewVideoTests: XCTestCase {
    private var coordinator = FilesCoordinator { nil }

    override func setUp() async throws {
        coordinator = FilesCoordinator { nil }
    }

    func testVideosAreKnownByTheirName() {
        XCTAssertTrue(FilePreviewVideo.isVideo("clip.MP4"))
        XCTAssertTrue(FilePreviewVideo.isVideo("screen recording.mov"))
        XCTAssertFalse(FilePreviewVideo.isVideo("clip.mp4.txt"))
        XCTAssertFalse(FilePreviewVideo.isVideo("mp4"))
    }

    func testAHostsVideoIsCopiedToThisMacOnlyOnPlayAndRemovedWhenLeft() async throws {
        let remote = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        remote.file("/home/ivan/clips/launch.mp4", "not really a movie")
        let local = FakeFilesSource(endpoint: .local)
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(remote)
        let video = FilePreviewVideo()
        XCTAssertTrue(session.transfers.isEmpty, "Nothing is read before Play")

        video.play("/home/ivan/clips/launch.mp4", in: session, engine: engine(), local: { self.local(local) })
        XCTAssertTrue(video.copying)
        let transfer = try XCTUnwrap(session.transfers.first)
        XCTAssertEqual(transfer.kind, .copyOut)
        XCTAssertEqual(transfer.targetLabel, "this Mac")
        try await TestSupport.eventually { if case .playing = video.stage { true } else { false } }
        let url = try XCTUnwrap(playing(video))
        XCTAssertEqual(url.lastPathComponent, "launch.mp4")
        XCTAssertEqual(local.text(url.path), "not really a movie", "The player reads the copy on this Mac")
        let folder = url.deletingLastPathComponent()
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("dispatch-video-"))
        XCTAssertTrue(System.exists(folder))

        video.stop()
        XCTAssertFalse(System.exists(folder), "Leaving the preview removes the copy")
        guard case .idle = video.stage else { return XCTFail("Stopped: \(video.stage)") }
    }

    func testAVideoOnThisMacPlaysWhereItIs() throws {
        let local = FakeFilesSource(endpoint: .local)
        local.file("/Users/ivan/Movies/launch.mov", "movie")
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(local)
        let video = FilePreviewVideo()
        video.play("/Users/ivan/Movies/launch.mov", in: session, engine: engine(), local: { self.local(local) })
        XCTAssertEqual(try XCTUnwrap(playing(video)).path, "/Users/ivan/Movies/launch.mov")
        XCTAssertTrue(session.transfers.isEmpty, "Nothing is copied")
        video.stop()
    }

    func testLeavingWhileCopyingCancelsTheCopyAndLeavesNothing() async throws {
        let remote = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        remote.file("/home/ivan/clips/launch.mp4", "not really a movie")
        remote.latency = .milliseconds(50)
        let local = FakeFilesSource(endpoint: .local)
        let session = coordinator.session(for: System.uuid())
        session.availability = .available(remote)
        let video = FilePreviewVideo()
        video.play("/home/ivan/clips/launch.mp4", in: session, engine: engine(), local: { self.local(local) })
        let transfer = try XCTUnwrap(session.transfers.first)
        video.stop()
        try await TestSupport.eventually { transfer.stage == .cancelled || transfer.stage == .done }
        guard case .idle = video.stage else { return XCTFail("Stopped: \(video.stage)") }
        let leftovers = try System.list(System.temporary).filter { $0.hasPrefix("dispatch-video-") }
        XCTAssertEqual(leftovers, [], "No copy is left behind")
    }

    /// The preview's player is SwiftUI's `VideoPlayer`, from `_AVKit_SwiftUI`, whose view subclasses AVKit's player
    /// view. Nothing else in the app names AVKit, so the linker dropped it, and the first player shown aborted
    /// (superclass metadata not found). The app links AVKit explicitly (project.yml); so must the iPhone app.
    func testThePlayerViewIsMade() {
        let host = NSHostingView(rootView: VideoPlayer(player: AVPlayer()).frame(width: 320, height: 180))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.subviews.isEmpty, "The system player is in the preview")
    }

    /// This Mac's fake source, given the folders the video made in the temporary folder (the real one has them).
    private func local(_ local: FakeFilesSource) -> FakeFilesSource {
        for name in (try? System.list(System.temporary)) ?? [] where name.hasPrefix("dispatch-video-") {
            _ = local.directory(System.temporary.appendingPathComponent(name).path)
        }
        return local
    }

    private func playing(_ video: FilePreviewVideo) -> URL? {
        guard case .playing(let player) = video.stage else { return nil }
        return (player.currentItem?.asset as? AVURLAsset)?.url
    }

    private func engine() -> FileTransferEngine {
        let engine = FileTransferEngine(coordinator: { [unowned self] in coordinator }, asksBeforeReplacing: { true })
        engine.sleep = { _, _ in throw CancellationError() }
        return engine
    }
}
