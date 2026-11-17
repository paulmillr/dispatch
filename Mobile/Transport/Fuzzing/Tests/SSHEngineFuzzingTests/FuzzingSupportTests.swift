import SSHEngine
import Testing

@Test func postKeyExchangeChannelStatesAreExecutable() {
  // Selectors 4 and 5 exercise CHANNEL_OPEN_CONFIRMATION's non-trivial UInt32 window and packet-size fields.
  // A checked byte narrowing here was the first fuzz-harness finding.
  SSHEngineFuzzing.clientPostKex([4])
  SSHEngineFuzzing.clientPostKex([5])
}
