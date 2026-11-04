import AVFoundation
import Foundation
import Observation

/// A video's Play in the Files preview (F2d). Nothing is read until Play: a video on this Mac then plays where it is;
/// a host's is first copied into a private folder in the app's temporary folder, the way a row dragged out is
/// (`FileTransferEngine`, whose row under the list shows the progress and Cancel), and plays from that copy. Leaving
/// the preview (`stop`) cancels the copy, stops the player and removes the copy.
@MainActor @Observable final class FilePreviewVideo {
    enum Stage {
        case idle
        case copying
        case playing(AVPlayer)
        case failed(String)
    }

    private(set) var stage: Stage = .idle
    @ObservationIgnored private var transfer: FileTransfer?
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var stopped = false

    /// Videos the system player takes, by name: a binary otherwise shown by its kind and size.
    static let extensions: Set<String> = ["mp4", "mov", "m4v"]

    static func isVideo(_ name: String) -> Bool { extensions.contains((name as NSString).pathExtension.lowercased()) }

    var copying: Bool { if case .copying = stage { true } else { false } }

    func play(_ path: String, in session: FilesSession, engine: FileTransferEngine = .shared,
              local: @MainActor () -> (any FilesSource)? = { FilesSources.local() }) {
        switch stage {
        case .idle, .failed: break
        case .copying, .playing: return
        }
        guard !stopped, let source = session.source else { return }
        if source.endpoint.isLocal { return start(URL(fileURLWithPath: path)) }
        let folder = System.temporary.appendingPathComponent("dispatch-video-" + System.uuid().uuidString)
        do {
            try System.directory(folder)
        } catch {
            stage = .failed(error.localizedDescription)
            return
        }
        self.folder = folder
        guard let local = local() else {
            removeCopy()
            stage = .failed("This Mac’s helper is not running")
            return
        }
        stage = .copying
        let name = (path as NSString).lastPathComponent
        transfer = engine.copy(items: [path], from: source, to: local, directory: folder.path, in: session,
                               kind: .copyOut, label: "this Mac", retryable: false) { [weak self] transfer in
            // The preview may be gone by now: its copy goes all the same.
            guard let self, !self.stopped else { try? System.remove(folder); return }
            self.transfer = nil
            switch transfer.stage {
            case .done:
                self.start(folder.appendingPathComponent(name))
            case .failed(let message, _):
                self.removeCopy()
                self.stage = .failed(message)
            default:
                self.removeCopy()
                self.stage = .idle
            }
        }
    }

    /// The preview is left: the copy in flight is cancelled (or removed once it settles), the player stops.
    func stop() {
        stopped = true
        transfer?.cancel?()
        transfer = nil
        if case .playing(let player) = stage { player.pause() }
        stage = .idle
        removeCopy()
    }

    private func start(_ url: URL) {
        let player = AVPlayer(url: url)
        stage = .playing(player)
        player.play()
    }

    private func removeCopy() {
        guard let folder else { return }
        self.folder = nil
        try? System.remove(folder)
    }
}
