import AppKit
import Observation

@MainActor @Observable
final class AppUpdater {
    enum State: Equatable {
        case idle, checking, available, downloading, ready, installing, upToDate, failed(String)
    }

    struct Operations {
        var context: () async throws -> UpdateInstaller.Context
        var latest: () async throws -> UpdateRelease
        var prepare: (UpdateRelease, UpdateInstaller.Context) async throws -> UpdateInstaller.Prepared
        var discard: (UpdateInstaller.Prepared) async -> Void
        var install: (UpdateInstaller.Prepared) async throws -> Void

        static func live(_ installer: UpdateInstaller = UpdateInstaller()) -> Self {
            Self(context: { try await installer.context() }, latest: { try await installer.latest() },
                 prepare: { try await installer.prepare($0, context: $1) }, discard: { await installer.discard($0) },
                 install: { try await installer.install($0) })
        }
    }

    private(set) var state = State.idle
    private(set) var release: UpdateRelease?
    private(set) var automatic = false
    @ObservationIgnored var onReady: (() -> Void)?
    @ObservationIgnored var onRestart: (() -> Void)?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var prepared: UpdateInstaller.Prepared?
    @ObservationIgnored private let operations: Operations
    @ObservationIgnored private let defaults: UserDefaults?
    private static let lastCheckKey = "dispatchUpdateLastCheck"
    static let interval: TimeInterval = 24 * 60 * 60

    init(operations: Operations = .live(), defaults: UserDefaults? = .app) {
        self.operations = operations
        self.defaults = defaults
    }

    var busy: Bool { state == .checking || state == .downloading || state == .installing }
    var status: String {
        switch state {
        case .idle: automatic ? "Checks daily; asks before restarting." : "Automatic updates are off."
        case .checking: "Checking for updates…"
        case .available: "Dispatch \(release?.version ?? "") is available."
        case .downloading: "Downloading and verifying the update…"
        case .ready: "Dispatch \(release?.version ?? "") is ready to install."
        case .installing: "Installing the update…"
        case .upToDate: "Dispatch is up to date."
        case .failed(let message): message
        }
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        guard automatic != enabled else { return }
        automatic = enabled
        schedule?.cancel(); schedule = nil
        if enabled {
            schedule = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let last = defaults?.object(forKey: Self.lastCheckKey) as? Date
                    let elapsed = last.map { System.date().timeIntervalSince($0) } ?? Self.interval
                    // A clock moved backwards never suppresses updates indefinitely.
                    let delay = elapsed < 0 ? 0 : max(0, Self.interval - elapsed)
                    if delay > 0 {
                        do { try await System.sleep(for: .seconds(delay), "automatic update check") }
                        catch { return }
                    }
                    guard !Task.isCancelled, automatic else { return }
                    check(download: true)
                    await work?.value
                    do { try await System.sleep(for: .seconds(Self.interval), "automatic update interval") }
                    catch { return }
                }
            }
        } else {
            work?.cancel(); work = nil
            if let prepared {
                self.prepared = nil
                Task { await operations.discard(prepared) }
            }
            release = nil
            state = .idle
        }
    }

    /// A manual check does not opt the user into future requests or downloads.
    func check(download: Bool = false) {
        guard !busy, state != .ready else { return }
        state = .checking
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await operations.context()
                try Task.checkCancellation()
                defaults?.set(System.date(), forKey: Self.lastCheckKey)
                let latest = try await operations.latest()
                try Task.checkCancellation()
                guard try UpdateRelease.compare(latest.version, context.version) == .orderedDescending else {
                    release = nil; state = .upToDate
                    return
                }
                release = latest
                state = .available
                if download { try await prepare(latest, context: context) }
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func download() {
        guard !busy, state != .ready, let release else { return }
        state = .downloading
        work = Task {
            do {
                let context = try await operations.context()
                try Task.checkCancellation()
                try await prepare(release, context: context)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func prepare(_ release: UpdateRelease, context: UpdateInstaller.Context) async throws {
        state = .downloading
        let result = try await operations.prepare(release, context)
        guard !Task.isCancelled else { await operations.discard(result); return }
        prepared = result
        state = .ready
        onReady?()
    }

    func restart() { if state == .ready { onRestart?() } }

    func installOnQuit() async throws {
        guard let prepared, state == .ready else { throw UpdateFailure("Check for updates again before restarting.") }
        state = .installing
        do {
            try await operations.install(prepared)
            self.prepared = nil
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() async {
        schedule?.cancel(); schedule = nil
        work?.cancel()
        await work?.value
        work = nil
        if let prepared { await operations.discard(prepared); self.prepared = nil }
    }

    /// An onboarding screen for both fresh installs and users receiving the updater for the first time.
    /// The unchecked choice stays off unless Continue explicitly saves it.
    static func onboard(over window: NSWindow, settings: SettingsStore) async {
        guard settings.values.automaticUpdates == nil else { return }
        let alert = onboardingAlert()
        await alert.beginSheetModal(for: window)
        // A setting changed while the sheet was open takes precedence.
        guard settings.values.automaticUpdates == nil, let choice = alert.accessoryView as? NSButton else { return }
        var values = settings.values
        values.automaticUpdates = choice.state == .on
        do { try settings.save(values) }
        catch { settings.error = error.localizedDescription }
    }

    static func onboardingAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Keep Dispatch up to date"
        alert.informativeText = "Dispatch can check for new releases and download updates automatically. You choose when to restart and install.\n\nYou can change this later in Settings › General › Updates."
        let choice = NSButton(checkboxWithTitle: "Enable automatic updates", target: nil, action: nil)
        choice.state = .off
        choice.setAccessibilityIdentifier("onboarding-automatic-updates")
        alert.accessoryView = choice
        alert.addButton(withTitle: "Continue")
        return alert
    }
}
