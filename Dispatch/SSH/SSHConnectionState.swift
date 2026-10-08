import Foundation

/// One authenticated connection generation owns its work and origin binding; a reused
/// terminal UUID cannot acquire an older connection's helper.
@MainActor
final class SSHConnectionState {
    let request: SSHLaunchRequest
    var id: SSHConnectionID { request.connectionID }
    /// The helper on the server; its connection is lent to HelperApp for the remote families.
    var helper: HelperSession? { didSet { if helper != nil { helperInstalled = true } } }
    /// Stays set after the helper disconnects: the shell it authorized keeps running.
    private(set) var helperInstalled = false
    /// What the user granted the helper connection and whom it greeted.
    var granted: SSHIntegrationGrant?
    var greeting: SSHGreeting?
    var launchTask: Task<Void, Never>?
    var reduction: Task<Void, Never>?
    var launchFailure: Error?
    var workspace: HelperWorkspace?
    var cleanupTask: Task<Void, Never>?
    var originClosed = false
    var helperPath: String?
    var intentionalDisconnect = false
    var normalExit: Int32?
    private(set) var isFinishing = false

    init(request: SSHLaunchRequest) { self.request = request }

    /// Remove active routing before any teardown can reenter the coordinator.
    /// The owner remains until its asynchronous private-master cleanup finishes.
    func beginFinishing() -> Bool {
        guard !isFinishing else { return false }
        isFinishing = true
        return true
    }

    func retireOrigin() {
        helperPath = nil; normalExit = nil; intentionalDisconnect = false
        originClosed = false
        launchTask?.cancel(); launchTask = nil
        reduction?.cancel(); reduction = nil
    }
}
