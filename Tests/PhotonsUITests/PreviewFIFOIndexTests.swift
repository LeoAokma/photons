import XCTest
@testable import PhotonsUI

final class PreviewFIFOIndexTests: XCTestCase {
    func testWraparoundOverwritesAndReinsertionsMatchInsertionOrder() {
        for capacity in [1, 2, 7] {
            var index = PreviewFIFOIndex<Int>(limit: capacity)
            var order: [String] = []
            var reference: [String: Int] = [:]
            let keys = (0..<(2 * capacity + 1)).map(String.init)
            for i in 0..<250 {
                let key = keys[(i / 3 + i % 2) % keys.count]
                if reference.updateValue(i, forKey: key) == nil {
                    order.append(key)
                    if order.count > capacity { reference.removeValue(forKey: order.removeFirst()) }
                }
                index.store(i, for: key)
                XCTAssertEqual(keys.map { index[$0] }, keys.map { reference[$0] })
            }
        }
    }
}
