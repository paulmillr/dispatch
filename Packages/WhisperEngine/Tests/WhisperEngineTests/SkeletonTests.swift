import XCTest
@testable import WhisperEngine

final class SkeletonTests: XCTestCase {
  func testWeightTypeByteCounts() {
    XCTAssertEqual(WeightType.q8_0.byteCount(elements: 64), 68)
    XCTAssertEqual(WeightType.f16.byteCount(elements: 3), 6)
  }
}
