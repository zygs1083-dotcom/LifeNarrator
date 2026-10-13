import Foundation

public struct ScrollLead {
    public enum Mode: String, Sendable { case fresh, throttled }

    public static let lineDelta: CGFloat = 40
    public static let pageOverlap: CGFloat = 20
    public static let wheelDuration: TimeInterval = 0.175
    public static let keyDuration: TimeInterval = 0.15

    public struct Mark {
        public let windowID: UInt32
        public fileprivate(set) var lead = CGPoint.zero
        public fileprivate(set) var sample: Int
        public fileprivate(set) var predicting = true
        fileprivate var predictionSince: TimeInterval?
    }

    struct Sample {
        let time: TimeInterval
        var positions: [UInt32: CGPoint]
    }

    private struct Animation {
        let delta: CGPoint
        let windows: Set<UInt32>
        let start: TimeInterval
        let duration: TimeInterval
        var progress: CGFloat = 0
    }

    public let mode: Mode
    public private(set) var marks: [String: Mark] = [:]
    public private(set) var moves = 0
    public private(set) var samples = 0
    private var history: [Sample]
    private var animations: [Animation] = []
    private var movedSinceFollow = false

    public init(mode: Mode, time: TimeInterval) {
        self.mode = mode
        history = [Sample(time: time, positions: [:])]
    }

    public mutating func add(_ id: String, windowID: UInt32) {
        marks[id] = Mark(windowID: windowID, sample: history.count - 1)
    }

    public mutating func remove(_ id: String) {
        marks.removeValue(forKey: id)
    }

    public mutating func event(delta: CGPoint, windows: Set<UInt32>, time: TimeInterval,
                               duration: TimeInterval) -> [String: CGPoint] {
        animations.append(Animation(delta: delta, windows: windows, start: time, duration: duration))
        return advance(time: time)
    }

    public mutating func advance(time: TimeInterval) -> [String: CGPoint] {
        var deltas: [UInt32: CGPoint] = [:]
        for i in animations.indices {
            let animation = animations[i]
            let p = animation.duration == 0 ? 1 : min(1, max(0, (time - animation.start) / animation.duration))
            let progress = CGFloat(3 * p * p - 2 * p * p * p)
            let step = progress - animation.progress
            for window in animation.windows {
                deltas[window] = adding(deltas[window] ?? .zero,
                    CGPoint(x: animation.delta.x * step, y: animation.delta.y * step))
            }
            animations[i].progress = progress
        }
        animations.removeAll { $0.progress == 1 }
        deltas = deltas.filter { $0.value != .zero }
        guard !deltas.isEmpty else { return [:] }
        movedSinceFollow = true
        var next = history.last!
        for (window, delta) in deltas {
            next.positions[window] = adding(next.positions[window] ?? .zero, delta)
        }
        history.append(Sample(time: time, positions: next.positions))
        guard mode == .throttled else { return [:] }
        var translations: [String: CGPoint] = [:]
        for (id, var mark) in marks where mark.predicting {
            guard let delta = deltas[mark.windowID] else { continue }
            mark.lead = adding(mark.lead, delta)
            if mark.lead == .zero { mark.predictionSince = nil }
            else if mark.predictionSince == nil { mark.predictionSince = time }
            marks[id] = mark
            translations[id] = delta
        }
        return translations
    }

    /// Only successful AX reads participate; a busy app's marks are skipped for this frame.
    public mutating func follow(deltas: [String: CGPoint], time: TimeInterval) -> [String: CGPoint] {
        if movedSinceFollow { moves += 1 }
        movedSinceFollow = false
        let changed = deltas.filter { hypot($0.value.x, $0.value.y) >= 0.5 }
        if !changed.isEmpty { samples += 1 }
        let changedWindows = Set(changed.keys.map { marks[$0]!.windowID })
        var translations: [String: CGPoint] = [:]
        for (id, delta) in deltas {
            var mark = marks[id]!
            if changed[id] != nil {
                var lead = CGPoint.zero
                if mode == .throttled && mark.predicting {
                    let previous = history[mark.sample].positions[mark.windowID] ?? .zero
                    let match = (mark.sample..<history.count).min { lhs, rhs in
                        let a = subtracting(subtracting(history[lhs].positions[mark.windowID] ?? .zero, previous), delta)
                        let b = subtracting(subtracting(history[rhs].positions[mark.windowID] ?? .zero, previous), delta)
                        return hypot(a.x, a.y) < hypot(b.x, b.y)
                    }!
                    mark.sample = match
                    lead = subtracting(history.last!.positions[mark.windowID] ?? .zero,
                                       history[match].positions[mark.windowID] ?? .zero)
                }
                translations[id] = adding(delta, subtracting(lead, mark.lead))
                mark.lead = lead
                mark.predictionSince = lead == .zero ? nil : time
            } else if mark.predicting && mark.lead != .zero,
                      changedWindows.contains(mark.windowID) || mark.predictionSince.map({ time - $0 >= 0.7 }) == true {
                translations[id] = subtracting(.zero, mark.lead)
                mark.lead = .zero
                mark.predicting = false
                mark.predictionSince = nil
            }
            marks[id] = mark
        }
        return translations
    }

    public var classifiedMode: Mode? {
        moves >= 10 ? (samples * 2 >= moves ? .fresh : .throttled) : nil
    }

    public mutating func end() -> [String: CGPoint] {
        var translations: [String: CGPoint] = [:]
        for (id, var mark) in marks {
            translations[id] = subtracting(.zero, mark.lead)
            mark.lead = .zero
            mark.sample = 0
            mark.predicting = true
            mark.predictionSince = nil
            marks[id] = mark
        }
        history = []
        animations = []
        movedSinceFollow = false
        return translations
    }

    private func adding(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: a.x + b.x, y: a.y + b.y)
    }

    private func subtracting(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: a.x - b.x, y: a.y - b.y)
    }
}
