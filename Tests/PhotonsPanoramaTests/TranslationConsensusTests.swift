import Foundation
import XCTest
@testable import PhotonsPanorama

final class TranslationConsensusTests: XCTestCase {
    private typealias Offset = SIMD2<Int>

    private func reference(_ offsets: [Offset]) -> [Int] {
        var best: [Int] = []
        for seed in offsets {
            let neighbors = offsets.indices.filter { i in
                let delta = offsets[i] &- seed
                return hypot(Double(delta.x), Double(delta.y)) < 4
            }
            if neighbors.count > best.count { best = neighbors }
        }
        return best
    }

    func testOpenDiskBoundaryAndTiedClustersRetainInputOrder() {
        let diskAndBoundary = (-4...4).flatMap { y in (-4...4).map { x in Offset(x, y) } }
        let tied = [Offset(-8, 4), Offset(8, -4), Offset(9, -2), Offset(-7, 6)]
        XCTAssertEqual(TranslationRegistration.consensusIndices(tied), [0, 3])
        for inputs in [[], diskAndBoundary, Array(diskAndBoundary.reversed()), tied + tied] {
            XCTAssertEqual(TranslationRegistration.consensusIndices(inputs), reference(inputs))
        }
    }

    func testSparseVotesAlongOneWireNeedSpatialVerification() {
        let wire = [0, 29, 58, 87, 116].map { CGPoint(x: 500 + $0 / 10, y: $0) }
        var match = TranslationRegistration.Match(offset: .zero, score: 0.994, inliers: 5, anchors: wire)
        XCTAssertFalse(match.hasIndependentSupport)
        match.anchors.append(CGPoint(x: 426, y: 58))
        match.inliers += 1
        XCTAssertTrue(match.hasIndependentSupport)
    }

    func testDenseSparseAndDuplicatedVotesMatchAllPairs() {
        var state: UInt64 = 73
        func next(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(limit))
        }
        for spread in [2, 7, 50, 400] {
            for _ in 0..<30 {
                let count = next(96)
                let offsets = (0..<count).map { _ in Offset(next(spread) - spread / 2, next(spread) - spread / 2) }
                XCTAssertEqual(TranslationRegistration.consensusIndices(offsets), reference(offsets))
            }
        }
    }
}
