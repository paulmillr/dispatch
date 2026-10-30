import XCTest
@testable import DispatchApp

/// The per-tab input queue and scroll joining of `HelperWorkspace`, without a helper: a fake wire records what goes
/// out and answers when the test says so.
@MainActor
final class HelperInputQueueTests: XCTestCase {
  private typealias Queue = HelperInputQueue<String>

  /// Records calls in the order they went on the wire; each reply comes when the test answers it.
  @MainActor
  private final class Wire {
    var sent: [String] = []
    private var replies: [AsyncStream<Void>.Continuation] = []

    func send(_ item: Queue.Item) async -> Queue.Reply? {
      switch item {
      case .input(let bytes): sent.append(String(decoding: bytes, as: UTF8.self))
      case .keys(let bytes, let binding): sent.append(binding + ":" + String(decoding: bytes, as: UTF8.self))
      }
      let (answered, answer) = AsyncStream<Void>.makeStream()
      replies.append(answer)
      return { for await _ in answered {} }
    }

    func answer(_ index: Int) { replies[index].finish() }
  }

  /// A gate that holds until opened (the attach confirmation) and then reports whether the tab is still bound.
  @MainActor
  private final class Gate {
    var bound = true
    private let (stream, open) = AsyncStream<Void>.makeStream()

    func pass() async -> Bool {
      for await _ in stream {}
      return bound
    }

    func release() { open.finish() }
  }

  private func queue(_ wire: Wire, _ gate: Gate? = nil, budget: Int = Queue.budget, depth: Int = Queue.depth) -> Queue {
    Queue(budget: budget, depth: depth, gate: { await gate?.pass() ?? true }, send: { await wire.send($0) })
  }

  private func input(_ text: String) -> Queue.Item { .input(Data(text.utf8)) }

  /// Lets the queue's tasks run, for checks that something did not happen.
  private func settle() async {
    for _ in 0..<100 { await Task.yield() }
  }

  /// Each key goes out as soon as the one before it is on the wire, without its reply, in typing order.
  func testInputGoesOutBeforeEarlierRepliesInOrder() async throws {
    let wire = Wire(), queue = queue(wire)
    for (index, key) in ["e", "c", "h", "o"].enumerated() {
      queue.append(input(key))
      try await TestSupport.eventually { wire.sent.count == index + 1 }
    }
    XCTAssertEqual(wire.sent, ["e", "c", "h", "o"])
    XCTAssertEqual(queue.unanswered, 4, "No reply came, yet every key is on the wire")
    for index in 0..<4 { wire.answer(index) }
    try await TestSupport.eventually { queue.unanswered == 0 }
  }

  /// Nothing goes out before the attach is confirmed; what was typed meanwhile goes out as one call.
  func testInputWaitsForTheAttachAndJoins() async throws {
    let wire = Wire(), gate = Gate(), queue = queue(wire, gate)
    for key in ["l", "s", " ", "-", "l", "a"] { queue.append(input(key)) }
    await settle()
    XCTAssertEqual(wire.sent, [], "Input waits for terminal.attached")
    queue.append(input("\r"))
    gate.release()
    try await TestSupport.eventually { queue.queued == 0 && wire.sent.count == 1 }
    XCTAssertEqual(wire.sent, ["ls -la\r"])
  }

  /// A gate that finds the tab no longer showing the terminal drops that call; later input still goes out.
  func testUnboundGateDropsTheCall() async throws {
    let wire = Wire(), gate = Gate(), queue = queue(wire, gate)
    gate.bound = false
    gate.release()
    queue.append(input("lost"))
    try await TestSupport.eventually { queue.queued == 0 }
    await settle()
    XCTAssertEqual(wire.sent, [])
    gate.bound = true
    queue.append(input("kept"))
    try await TestSupport.eventually { wire.sent == ["kept"] }
  }

  /// Checked keys never join plain input: they wait for every earlier reply (they may use another connection), and
  /// input after them waits for theirs.
  func testKeysWaitForEarlierRepliesAndHoldLaterInput() async throws {
    let wire = Wire(), queue = queue(wire)
    queue.append(input("a"))
    try await TestSupport.eventually { wire.sent == ["a"] }
    queue.append(.keys(Data("y".utf8), "agent"))
    queue.append(input("b"))
    queue.append(input("c"))
    await settle()
    XCTAssertEqual(wire.sent, ["a"], "Keys wait for the input before them to be answered")
    wire.answer(0)
    try await TestSupport.eventually { wire.sent == ["a", "agent:y"] }
    await settle()
    XCTAssertEqual(wire.sent, ["a", "agent:y"], "Input after keys waits for their reply")
    wire.answer(1)
    try await TestSupport.eventually { wire.sent == ["a", "agent:y", "bc"] }
  }

  /// With as many calls (or bytes) on the wire as allowed, typing joins into the next call, sent once a reply frees room.
  func testFullWireJoinsTyping() async throws {
    let wire = Wire(), queue = queue(wire, depth: 2)
    queue.append(input("a"))
    try await TestSupport.eventually { wire.sent == ["a"] }
    queue.append(input("b"))
    try await TestSupport.eventually { wire.sent == ["a", "b"] }
    for key in ["c", "d", "e"] { queue.append(input(key)) }
    await settle()
    XCTAssertEqual(wire.sent, ["a", "b"])
    wire.answer(0)
    try await TestSupport.eventually { wire.sent == ["a", "b", "cde"] }

    let bytes = Wire(), budgeted = self.queue(bytes, budget: 4)
    budgeted.append(input("abc"))
    try await TestSupport.eventually { bytes.sent == ["abc"] }
    budgeted.append(input("de"))
    budgeted.append(input("f"))
    await settle()
    XCTAssertEqual(bytes.sent, ["abc"], "Three bytes on the wire leave no room for two more")
    bytes.answer(0)
    try await TestSupport.eventually { bytes.sent == ["abc", "def"] }
    bytes.answer(1)
    budgeted.append(input("larger than the budget"))
    try await TestSupport.eventually { bytes.sent.count == 3 }
    XCTAssertEqual(bytes.sent.last, "larger than the budget", "A chunk larger than the budget still goes, alone")
  }

  /// Cancel drops what has not gone out; input after it goes out again.
  func testCancelDropsQueuedInput() async throws {
    let wire = Wire(), gate = Gate(), queue = queue(wire, gate)
    queue.append(input("dropped"))
    await settle()
    queue.cancel()
    gate.release()
    queue.append(input("sent"))
    try await TestSupport.eventually { wire.sent == ["sent"] }
  }

  /// A tab attached again sends its new input after what its earlier attachment already took on.
  func testFollowingQueueGoesAfterTheEarlierAttachment() async throws {
    let wire = Wire(), gate = Gate(), earlier = queue(wire, gate), later = queue(wire)
    earlier.append(input("first"))
    await settle()
    later.follow(earlier)
    later.append(input("second"))
    await settle()
    XCTAssertEqual(wire.sent, [])
    gate.release()
    try await TestSupport.eventually { wire.sent == ["first", "second"] }
  }

  /// Scroll steps made while one is in flight add up per kind (page, modifiers, cell), in order, keeping every step's
  /// local fallback.
  func testScrollStepsJoinWhileOneIsInFlight() {
    typealias Steps = HelperScrollSteps<String>
    let line = { (lines: Int64, column: UInt16?) in
      Steps.Step(lines: lines, page: false, column: column, row: column.map { _ in 4 }, modifiers: 0)
    }
    var steps = Steps()
    XCTAssertTrue(steps.idle)
    let first = steps.add(line(-1, 10), "one")
    XCTAssertEqual(first?.step, line(-1, 10))
    XCTAssertEqual(first?.locals, ["one"])
    XCTAssertNil(steps.add(line(-1, 10), "two"))
    XCTAssertNil(steps.add(line(-2, 10), "three"))
    XCTAssertNil(steps.add(Steps.Step(lines: -24, page: true, column: nil, row: nil, modifiers: 0), "page"))
    XCTAssertNil(steps.add(line(-1, 10), "four"))
    XCTAssertNil(steps.add(line(-1, 11), "moved"))
    XCTAssertNil(steps.add(Steps.Step(lines: -1, page: false, column: 11, row: 4, modifiers: 1), "shifted"))

    let joined = steps.finish()
    XCTAssertEqual(joined?.step, line(-3, 10))
    XCTAssertEqual(joined?.locals, ["two", "three"])
    XCTAssertEqual(steps.finish()?.step.page, true)
    XCTAssertEqual(steps.finish()?.locals, ["four"])
    XCTAssertEqual(steps.finish()?.locals, ["moved"])
    XCTAssertEqual(steps.finish()?.step.modifiers, 1)
    XCTAssertNil(steps.finish())
    XCTAssertTrue(steps.idle)

    // The renderer owns the history: everything waiting runs locally, in order.
    _ = steps.add(line(1, nil), "sent")
    _ = steps.add(line(1, nil), "a")
    _ = steps.add(line(1, 3), "b")
    XCTAssertEqual(steps.drain(), ["a", "b"])
    XCTAssertNil(steps.finish())
    XCTAssertTrue(steps.idle)
  }
}
