import Foundation

/// The engine's entry point for the app.
public enum SSHClient {
  /// Connects over TCP with Network.framework (`NetworkStreamConnector`), randomness from the system
  /// (`SystemRandom`), host key signatures checked by `SSHSignatureVerifier`.
  public static func connector() -> any SSHConnector {
    ClientConnector(streams: NetworkStreamConnector())
  }
}

/// `SSHConnector` over any stream connector: one `ConnectionDriver` per connection. Tests build it over in-memory
/// streams, seeded randomness and lowered thresholds.
struct ClientConnector: SSHConnector {
  let streams: any StreamConnector
  let random: @Sendable () -> any RandomSource
  let tuning: DriverTuning
  /// Tests: told of each driver as it is made, before its connect starts.
  let created: (@Sendable (ConnectionDriver) -> Void)?

  init(streams: any StreamConnector, random: @escaping @Sendable () -> any RandomSource = { SystemRandom() },
       tuning: DriverTuning = DriverTuning(), created: (@Sendable (ConnectionDriver) -> Void)? = nil) {
    self.streams = streams
    self.random = random
    self.tuning = tuning
    self.created = created
  }

  func connect(_ options: ConnectOptions, trust: @escaping HostKeyTrust) async throws(SSHError) -> any SSHSession {
    let driver = try ConnectionDriver(options: options, random: random, tuning: tuning)
    created?(driver)
    let hostKey = try await driver.connect(using: streams, trust: trust)
    return ClientSession(driver: driver, hostKey: hostKey)
  }
}

/// `SSHSession`: a handle on its connection's driver. Releasing the last reference closes the connection.
final class ClientSession: SSHSession {
  let driver: ConnectionDriver
  let hostKey: HostKey

  init(driver: ConnectionDriver, hostKey: HostKey) {
    self.driver = driver
    self.hostKey = hostKey
  }

  deinit {
    let driver = driver
    Task { await driver.close() }
  }

  func authenticate(user: String, with credential: Credential) async throws(SSHError) -> AuthOutcome {
    try await driver.authenticate(user: user, with: credential)
  }

  func exec(_ command: String) async throws(SSHError) -> any ExecChannel {
    let (handle, _) = try await driver.open(.exec, command: command)
    return ClientExecChannel(driver: driver, handle: handle)
  }

  func shell(term: String, size: TerminalSize) async throws(SSHError) -> any ShellChannel {
    let (handle, mailbox) = try await driver.open(.shell, term: term, size: size)
    return ClientShellChannel(driver: driver, handle: handle, mailbox: mailbox ?? ShellMailbox())
  }

  func close() async { await driver.close() }

  func ended() async -> SSHError { await driver.ended() }
}

/// `ExecChannel` over the driver. Releasing it closes the channel (an abandoned channel would otherwise hold its
/// window and number until the server ends the command).
final class ClientExecChannel: ExecChannel {
  let driver: ConnectionDriver
  let handle: UInt64

  init(driver: ConnectionDriver, handle: UInt64) {
    self.driver = driver
    self.handle = handle
  }

  deinit {
    let (driver, handle) = (driver, handle)
    Task { await driver.release(handle) }
  }

  func write(_ bytes: [UInt8]) async throws(SSHError) { try await driver.write(handle, bytes) }
  func finishInput() async { await driver.finishInput(handle) }
  func read() async throws(SSHError) -> ChannelOutput? { try await driver.read(handle) }
  func close() async { await driver.closeChannel(handle) }
  func exit() async -> ChannelExit { await driver.exit(handle) }
}

/// `ShellChannel` over the driver. Releasing it closes the channel.
final class ClientShellChannel: ShellChannel {
  let driver: ConnectionDriver
  let handle: UInt64
  private let mailbox: ShellMailbox

  init(driver: ConnectionDriver, handle: UInt64, mailbox: ShellMailbox) {
    self.driver = driver
    self.handle = handle
    self.mailbox = mailbox
  }

  deinit {
    let (driver, handle) = (driver, handle)
    Task { await driver.release(handle) }
  }

  func write(_ bytes: [UInt8]) async throws(SSHError) { try await driver.write(handle, bytes) }

  func read() async throws(SSHError) -> [UInt8]? { try await driver.read(handle)?.bytes }

  func resize(_ size: TerminalSize) throws(SSHError) {
    guard try mailbox.request(size) else { return }
    let (driver, handle) = (driver, handle)
    Task { await driver.applyResize(handle) }
  }

  func close() async {
    mailbox.markClosed()
    await driver.closeChannel(handle)
  }

  func exit() async -> ChannelExit { await driver.exit(handle) }
}

/// `ShellChannel.resize` is synchronous, so the newest size waits here until the driver takes it: one slot (the
/// latest wins) and whether the shell ended. The only connection state outside the driver; a lock guards it, and the
/// driver marks it closed when the shell ends. A delivery task is started only when the slot was empty, and it takes
/// the slot and sends on the driver in one step, so sizes reach the core in call order.
final class ShellMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var closed = false
  private var pending: TerminalSize?

  /// Stores `size`; true when a delivery must be started (none is pending). Throws once the shell ended or closed.
  func request(_ size: TerminalSize) throws(SSHError) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { throw .usage(.channelClosed) }
    let deliver = pending == nil
    pending = size
    return deliver
  }

  func take() -> TerminalSize? {
    lock.lock()
    defer { lock.unlock() }
    defer { pending = nil }
    return pending
  }

  func markClosed() {
    lock.lock()
    defer { lock.unlock() }
    closed = true
    pending = nil
  }
}
