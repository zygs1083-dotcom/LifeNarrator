import Foundation

public struct ScrollLead {
    public enum Mode: String, Sendable { case fresh, throttled }

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

    public let mode: Mode
    public private(set) var marks: [String: Mark] = [:]
    public private(set) var events = 0
    public private(set) var samples = 0
    private var history: [Sample]

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

    public mutating func event(delta: CGPoint, windows: Set<UInt32>, time: TimeInterval) -> [String: CGPoint] {
        events += 1
        var next = history.last!
        for window in windows {
            next.positions[window] = adding(next.positions[window] ?? .zero, delta)
        }
        history.append(Sample(time: time, positions: next.positions))
        guard mode == .throttled else { return [:] }
        var translations: [String: CGPoint] = [:]
        for (id, var mark) in marks where windows.contains(mark.windowID) && mark.predicting {
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
        let changed = deltas.filter { hypot($0.value.x, $0.value.y) >= 0.5 }
        samples += changed.count
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
        events >= 10 ? (samples * 3 >= events ? .fresh : .throttled) : nil
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
        return translations
    }

    private func adding(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: a.x + b.x, y: a.y + b.y)
    }

    private func subtracting(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: a.x - b.x, y: a.y - b.y)
    }
}
