import XCTest
@testable import NarratorLlama

final class SpeculativeSamplingTests: XCTestCase {
    func testAcceptanceAndResidual() {
        let p = [0.2, 0.8, 0.0]
        let q = [0.8, 0.0, 0.2]
        XCTAssertTrue(SpeculativeSampling.accepts(token: 0, target: p, draft: q, uniform: 0.24))
        XCTAssertFalse(SpeculativeSampling.accepts(token: 0, target: p, draft: q, uniform: 0.25))
        XCTAssertFalse(SpeculativeSampling.accepts(token: 2, target: p, draft: q, uniform: 0))
        XCTAssertEqual(SpeculativeSampling.residual(target: p, draft: q), [0, 1, 0])
        XCTAssertEqual(SpeculativeSampling.sample([0, 1, 0], uniform: 0.9), 1)
    }

    func testFixedSeedRejectionSamplingPreservesTargetDistribution() {
        let p = [0.15, 0.35, 0.5, 0.0] // token 3 is forbidden by the grammar
        let q = [0.7, 0.2, 0.1, 0.0]
        var random = SpeculativeRandom(state: 42)
        var counts = [Int](repeating: 0, count: p.count)
        for _ in 0..<50000 {
            let proposed = SpeculativeSampling.sample(q, uniform: random.uniform())
            let token = SpeculativeSampling.accepts(token: proposed, target: p, draft: q, uniform: random.uniform())
                ? proposed : SpeculativeSampling.sample(SpeculativeSampling.residual(target: p, draft: q), uniform: random.uniform())
            counts[token] += 1
        }
        for i in p.indices { XCTAssertEqual(Double(counts[i]) / 50000, p[i], accuracy: 0.008) }
        XCTAssertEqual(counts[3], 0)
        var a = SpeculativeRandom(state: 42)
        var b = SpeculativeRandom(state: 42)
        XCTAssertEqual((0..<20).map { _ in a.uniform() }, (0..<20).map { _ in b.uniform() })
    }
}
