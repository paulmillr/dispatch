import AppKit
import Observation

@MainActor @Observable
final class AppUpdater {
    enum State: Equatable {
        case idle, checking, downloading, verifying, ready, installing, upToDate, failed(String)
    }

    struct Operations {
        var context: () async throws -> UpdateInstaller.Context
        var latest: () async throws -> UpdateRelease
        /// Reports the download's progress, then that it is verifying, from any thread.
        var prepare: (UpdateRelease, UpdateInstaller.Context, @escaping @Sendable (UpdateInstaller.Step) -> Void) async throws -> UpdateInstaller.Prepared
        var discard: (UpdateInstaller.Prepared) async -> Void
        var install: (UpdateInstaller.Prepared) async throws -> Void
        /// Removes what interrupted updates left beside the app.
        var sweep: () async -> Void = {}
        /// The running app's version, which a copy that can't update itself (no `context`) compares the feed's with.
        var installedVersion: () -> String? = { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

        static func live(_ installer: UpdateInstaller = UpdateInstaller()) -> Self {
            Self(context: { try await installer.context() }, latest: { try await installer.latest() },
                 prepare: { try await installer.prepare($0, context: $1, step: $2) }, discard: { await installer.discard($0) },
                 install: { try await installer.install($0) }, sweep: { await installer.sweep() })
        }
    }

    private(set) var state = State.idle
    private(set) var release: UpdateRelease?
    private(set) var automatic = false
    /// Bytes of the update downloaded so far, while downloading.
    private(set) var progress: UpdateInstaller.Progress?
    /// What the last failure was doing ("check for updates", "download Dispatch 0.2.0"), and when.
    private(set) var failure: (step: String, at: Date)?
    /// A newer release this copy can't install itself (not in a writable folder, or not a signed release): the last
    /// check says so and Settings offers its download.
    private(set) var available: UpdateRelease?
    /// An update the daily check downloaded is ready. One started in Settings shows there instead.
    @ObservationIgnored var onReady: (() -> Void)?
    @ObservationIgnored var onRestart: (() -> Void)?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var prepared: UpdateInstaller.Prepared?
    /// Tells a cancelled download's late progress from the current one's.
    @ObservationIgnored private var attempt = 0
    /// The current or last check is the daily one: turning automatic updates off stops it and discards what it staged,
    /// but leaves one started with Check for updates.
    @ObservationIgnored private var daily = false
    /// The last failure was the network's or the server's, so the daily check tries again sooner.
    @ObservationIgnored private var transient = false
    @ObservationIgnored private let operations: Operations
    @ObservationIgnored private let defaults: UserDefaults?
    private static let lastCheckKey = "dispatchUpdateLastCheck"
    static let interval: TimeInterval = 24 * 60 * 60
    /// After a network failure (offline, just woken, a dropped connection) the daily check tries again after these
    /// waits before going back to daily.
    static let retries: [TimeInterval] = [5 * 60, 30 * 60, 2 * 60 * 60]

    init(operations: Operations = .live(), defaults: UserDefaults? = .app) {
        self.operations = operations
        self.defaults = defaults
    }

    var busy: Bool { cancellable || state == .installing }
    /// Checking, downloading or verifying, which Settings offers to cancel.
    var cancellable: Bool { state == .checking || state == .downloading || state == .verifying }
    var status: String {
        switch state {
        case .idle: automatic ? "Checks daily; asks before restarting." : "Automatic updates are off."
        case .checking: "Checking for updates…"
        case .downloading:
            if let progress, progress.received > 0 {
                progress.expected > 0
                    ? "Downloading Dispatch \(release?.version ?? "")… \(Self.size(progress.received)) of \(Self.size(progress.expected))"
                    : "Downloading Dispatch \(release?.version ?? "")… \(Self.size(progress.received))"
            } else { "Downloading Dispatch \(release?.version ?? "")…" }
        case .verifying: "Verifying Dispatch \(release?.version ?? "")…"
        case .ready: "Dispatch \(release?.version ?? "") is ready to install."
        case .installing: "Installing the update…"
        case .upToDate: "Dispatch is up to date."
        case .failed(let message):
            if available != nil { message }
            else if let failure { "Could not \(failure.step) (\(Self.time(failure.at))): \(message)" } else { message }
        }
    }

    /// Today's time alone, else the date too: a failure can stay in Settings for days.
    private static func time(_ date: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: System.date())
            ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The network's or the server's failures, worth trying again soon; a cancelled task is not one.
    static func isTransient(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        return (error as? UpdateFailure)?.transient == true
    }

    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    func setAutomaticUpdates(_ enabled: Bool) {
        guard automatic != enabled else { return }
        automatic = enabled
        schedule?.cancel(); schedule = nil
        if enabled {
            schedule = Task { [weak self] in
                var retried = 0
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
                    check(announce: true)
                    await work?.value
                    // The last check is saved only once one completed, so the loop's start waits out the rest.
                    if case .failed = state, transient, retried < Self.retries.count {
                        do { try await System.sleep(for: .seconds(Self.retries[retried]), "automatic update retry") }
                        catch { return }
                        retried += 1
                    } else {
                        retried = 0
                        do { try await System.sleep(for: .seconds(Self.interval), "automatic update interval") }
                        catch { return }
                    }
                }
            }
        } else if daily {
            work?.cancel(); work = nil
            if let prepared {
                self.prepared = nil
                Task { await operations.discard(prepared) }
            }
            reset()
        }
    }

    private func reset() {
        release = nil
        available = nil
        progress = nil
        failure = nil
        state = .idle
    }

    /// Removes folders interrupted updates left beside the app (a crash, a forced quit, power lost mid-download).
    func sweep() { Task { await operations.sweep() } }

    /// Checks, then downloads and verifies a newer release. Clicking Check for updates asks for this one release, so a
    /// manual check downloads it at once; it does not opt the user into future requests or downloads. Only the daily
    /// check (`announce`) calls `onReady`: a manual one shows its result in Settings, where it was started.
    func check(announce: Bool = false) {
        guard !busy, state != .ready else { return }
        daily = announce
        failure = nil
        available = nil
        transient = false
        state = .checking
        // A cancelled download may still be cleaning up its files; it finishes before the next one starts.
        let previous = work
        work = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // The feed request goes out while the installed app's signature is checked (up to a second, cold).
            let feed = Task { try await operations.latest() }
            defer { feed.cancel() } // once answered, a no-op
            do {
                let context: UpdateInstaller.Context
                do { context = try await operations.context() } catch {
                    // A copy that can't update itself still says whether a newer one is out, and how to get it.
                    try Task.checkCancellation()
                    guard let latest = try? await withTaskCancellationHandler(operation: { try await feed.value }, onCancel: { feed.cancel() }),
                          let installed = operations.installedVersion(),
                          let order = try? UpdateRelease.compare(latest.version, installed) else { throw error }
                    try Task.checkCancellation()
                    guard order == .orderedDescending else {
                        release = nil; state = .upToDate
                        checked()
                        return
                    }
                    available = latest
                    throw UpdateFailure("Dispatch \(latest.version) is available, but this copy can’t update itself: \(error.localizedDescription) "
                        + "Update with Homebrew (brew upgrade --cask paulmillr/tap/dispatch), or download it.")
                }
                try Task.checkCancellation()
                let latest = try await withTaskCancellationHandler { try await feed.value } onCancel: { feed.cancel() }
                try Task.checkCancellation()
                guard try UpdateRelease.compare(latest.version, context.version) == .orderedDescending else {
                    release = nil; state = .upToDate
                    checked()
                    return
                }
                release = latest
                try await prepare(latest, context: context, announce: announce)
                checked()
            } catch {
                guard !Task.isCancelled else { return }
                let step = switch state {
                case .downloading: "download Dispatch \(release?.version ?? "")"
                case .verifying: "verify Dispatch \(release?.version ?? "")"
                default: "check for updates"
                }
                transient = Self.isTransient(error)
                // A network failure is no check: a relaunch tries again rather than waiting a day.
                if !transient { checked() }
                progress = nil
                failure = (step, System.date())
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func checked() { defaults?.set(System.date(), forKey: Self.lastCheckKey) }

    /// Stops a check, a download or its verification; the partial files are removed in the background.
    func cancel() {
        guard cancellable else { return }
        work?.cancel()
        attempt += 1
        reset()
    }

    private func prepare(_ release: UpdateRelease, context: UpdateInstaller.Context, announce: Bool) async throws {
        attempt += 1
        let current = attempt
        progress = nil
        state = .downloading
        let result = try await operations.prepare(release, context) { step in
            Task { @MainActor [weak self] in self?.advance(step, attempt: current) }
        }
        guard !Task.isCancelled else { await operations.discard(result); return }
        prepared = result
        progress = nil
        state = .ready
        if announce { onReady?() }
    }

    /// Steps arrive asynchronously: one from an earlier attempt, or after a later step, changes nothing.
    private func advance(_ step: UpdateInstaller.Step, attempt current: Int) {
        guard current == attempt, state == .downloading else { return }
        switch step {
        case .downloading(let received): progress = received
        case .verifying: progress = nil; state = .verifying
        }
    }

    func restart() { if state == .ready { onRestart?() } }

    func installOnQuit() async throws {
        guard let prepared, state == .ready else { throw UpdateFailure("Check for updates again before restarting.") }
        state = .installing
        do {
            try await operations.install(prepared)
            self.prepared = nil
        } catch {
            failure = ("install Dispatch \(prepared.release.version)", System.date())
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
}
