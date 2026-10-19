import Foundation
import MobileTransport
import XCTest

/// Requirement 7: every public type is Sendable or an actor. This file only compiles if so (the package
/// builds in the Swift 6 language mode, i.e. complete strict concurrency checking).
final class ConcurrencyTests: XCTestCase {
  private func sendable<T: Sendable>(_: T.Type) {}
  private func actor<T: Actor>(_: T.Type) {}

  func testPublicTypesAreSendable() {
    sendable(HelperChannel.self)
    sendable(SSHExec.self)
    sendable(SSHExec.Output.self)
    sendable(SSHExec.AsyncIterator.self)
    sendable(HelperBootstrap.self)
    sendable(HelperBootstrap.Installed.self)
    sendable(SSHHostSession.self)
    sendable(SSHConnection.self)
    sendable(SSHConnection.Timings.self)
    sendable(SSHCommandResult.self)
    sendable(HostKeyInfo.self)
    sendable((any HostKeyTrust).self)
    sendable(HostKeyDecision.self)
    actor(TrustOnFirstUse.self)
    sendable(SSHTransportError.self)
    sendable(SSHEndpoint.self)
    sendable(SSHCredential.self)
    sendable(KeyboardInteractiveChallenge.self)
    sendable(KeyboardInteractiveChallenge.Prompt.self)
    sendable(HostConnectionState.self)
    sendable((any ReconnectClock).self)
    sendable(SystemReconnectClock.self)
    sendable((any HostSession).self)
    sendable(HostConnectionPhase.self)
    actor(HostConnection<SSHHostSession>.self)
    sendable(HostConnectionPolicy.self)
    sendable(SSHKey.self)
    sendable(SSHKey.Kind.self)
  }
}
