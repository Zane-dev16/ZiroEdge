import XCTest
@testable import ZiroEdge

final class Batch4TokenEstimatorTests: XCTestCase {
    func testEstimatedTokensBoundaries() {
        XCTAssertEqual(ChatViewModel.estimatedTokens(characterCount: 0), 0)
        XCTAssertEqual(ChatViewModel.estimatedTokens(characterCount: 1), 1)
        XCTAssertEqual(ChatViewModel.estimatedTokens(characterCount: 7), 1)
        XCTAssertEqual(ChatViewModel.estimatedTokens(characterCount: 8), 2)
        XCTAssertEqual(ChatViewModel.estimatedTokens(characterCount: 4001), 1000)
    }
}
