import Foundation

public struct SpriteMinuteStats: Sendable {
    private var started: Date
    private var shows: [String: Int] = [:]
    private var repeats = 0
    private var requests = 0
    private var cancelled = 0
    private var active = 0
    private var busySince: Date?
    private var busy: TimeInterval = 0

    public init(now: Date) { started = now }

    public mutating func record(source: String, shown: Bool, repeatRejected: Bool) {
        if shown { shows[source, default: 0] += 1 }
        if repeatRejected { repeats += 1 }
    }

    public mutating func begin(now: Date) {
        requests += 1
        if active == 0 { busySince = now }
        active += 1
    }

    public mutating func end(now: Date, wasCancelled: Bool) {
        if wasCancelled { cancelled += 1 }
        active -= 1
        if active == 0 {
            busy += now.timeIntervalSince(busySince!)
            busySince = nil
        }
    }

    public mutating func line(now: Date) -> String {
        let seconds = busy + (busySince.map { now.timeIntervalSince($0) } ?? 0)
        let percentage = Int(100 * seconds / now.timeIntervalSince(started))
        let total = shows.values.reduce(0, +)
        let rule = shows.filter { !["model", "cache", "ambient", "opener"].contains($0.key) }.values.reduce(0, +)
        let line = "[sprite] minute shows=\(total) model=\(shows["model", default: 0]) cache=\(shows["cache", default: 0]) ambient=\(shows["ambient", default: 0]) opener=\(shows["opener", default: 0]) rule=\(rule) repeats=\(repeats) requests=\(requests) cancelled=\(cancelled) busy=\(percentage)%"
        shows = [:]
        repeats = 0
        requests = 0
        cancelled = 0
        busy = 0
        started = now
        if active > 0 { busySince = now }
        return line
    }
}
