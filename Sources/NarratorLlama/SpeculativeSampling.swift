import Foundation

// p and q are the grammar-masked, filtered, temperature-adjusted distributions.
enum SpeculativeSampling {
    static func accepts(token: Int, target: [Double], draft: [Double], uniform: Double) -> Bool {
        uniform < min(1, target[token] / draft[token])
    }

    static func residual(target: [Double], draft: [Double]) -> [Double] {
        let weights = zip(target, draft).map { max(0, $0 - $1) }
        let total = weights.reduce(0, +)
        return weights.map { $0 / total }
    }

    static func sample(_ probabilities: [Double], uniform: Double) -> Int {
        var cumulative = 0.0
        for (token, probability) in probabilities.enumerated() {
            cumulative += probability
            if uniform < cumulative { return token }
        }
        return probabilities.lastIndex(where: { $0 > 0 })!
    }
}

struct SpeculativeRandom {
    var state: UInt64
    mutating func uniform() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return Double((value ^ (value >> 31)) >> 11) * 0x1.0p-53
    }
}
