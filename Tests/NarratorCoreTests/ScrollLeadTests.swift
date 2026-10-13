import Foundation
import Testing
@testable import NarratorCore

@Test func scrollLeadConfirmationDoesNotJumpBack() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("mark", windowID: 1)
    let delta = CGPoint(x: 3, y: -20)
    #expect(lead.event(delta: delta, windows: [1], time: 0.1, duration: 0)["mark"] == delta)
    #expect(lead.follow(deltas: ["mark": delta], time: 0.2)["mark"] == .zero)
    #expect(lead.marks["mark"]!.lead == .zero)
    #expect(lead.marks["mark"]!.sample == 1)
}

@Test func scrollLeadMatchesLaggingAXSamplesAgainstHistory() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("mark", windowID: 1)
    for (index, delta) in [CGPoint(x: 2, y: -10), CGPoint(x: 3, y: -20), CGPoint(x: 4, y: -30)].enumerated() {
        _ = lead.event(delta: delta, windows: [1], time: Double(index + 1) * 0.1, duration: 0)
    }
    #expect(lead.follow(deltas: ["mark": CGPoint(x: 5, y: -30)], time: 0.4)["mark"] == .zero)
    #expect(lead.marks["mark"]!.sample == 2)
    #expect(lead.marks["mark"]!.lead == CGPoint(x: 4, y: -30))
    #expect(lead.follow(deltas: ["mark": CGPoint(x: 4, y: -30)], time: 0.5)["mark"] == .zero)
    #expect(lead.marks["mark"]!.sample == 3)
    #expect(lead.marks["mark"]!.lead == .zero)
}

@Test func scrollLeadCorrectsPredictionError() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("mark", windowID: 1)
    _ = lead.event(delta: CGPoint(x: 0, y: -20), windows: [1], time: 0.1, duration: 0)
    #expect(lead.follow(deltas: ["mark": CGPoint(x: 0, y: -18)], time: 0.2)["mark"] == CGPoint(x: 0, y: 2))
    #expect(lead.marks["mark"]!.lead == .zero)
}

@Test func scrollLeadStopsPredictingStationaryMarksInSameWindow() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("moving", windowID: 1)
    lead.add("sticky", windowID: 1)
    lead.add("other", windowID: 2)
    let delta = CGPoint(x: 0, y: -20)
    _ = lead.event(delta: delta, windows: [1, 2], time: 0.1, duration: 0)
    let moves = lead.follow(deltas: ["moving": delta, "sticky": .zero, "other": .zero], time: 0.2)
    #expect(moves["sticky"] == CGPoint(x: 0, y: 20))
    #expect(!lead.marks["sticky"]!.predicting)
    #expect(lead.marks["sticky"]!.lead == .zero)
    #expect(moves["other"] == nil)
    #expect(lead.marks["other"]!.predicting)
    #expect(lead.event(delta: delta, windows: [1], time: 0.3, duration: 0)["sticky"] == nil)
    #expect(lead.follow(deltas: ["sticky": delta], time: 0.4)["sticky"] == delta)
}

@Test func scrollLeadTimeoutUsesFirstUnconfirmedPrediction() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("mark", windowID: 1)
    _ = lead.event(delta: CGPoint(x: 0, y: -10), windows: [1], time: 0.1, duration: 0)
    _ = lead.event(delta: CGPoint(x: 0, y: -10), windows: [1], time: 0.5, duration: 0)
    #expect(lead.follow(deltas: ["mark": .zero], time: 0.79).isEmpty)
    #expect(lead.follow(deltas: ["mark": .zero], time: 0.81)["mark"] == CGPoint(x: 0, y: 20))
    #expect(lead.marks["mark"]!.lead == .zero)
    #expect(!lead.marks["mark"]!.predicting)
    #expect(lead.event(delta: CGPoint(x: 0, y: -10), windows: [1], time: 0.9, duration: 0).isEmpty)
}

@Test func scrollLeadBusyAXReadSkipsStationaryDetectionAndTimeout() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("moving", windowID: 1)
    lead.add("busy", windowID: 1)
    let delta = CGPoint(x: 0, y: -20)
    _ = lead.event(delta: delta, windows: [1], time: 0.1, duration: 0)
    _ = lead.follow(deltas: ["moving": delta], time: 0.9)
    #expect(lead.marks["busy"]!.lead == delta)
    #expect(lead.marks["busy"]!.predicting)
}

@Test func scrollLeadAXChangeRestartsTimeoutForRemainingLead() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("mark", windowID: 1)
    _ = lead.event(delta: CGPoint(x: 0, y: -10), windows: [1], time: 0.1, duration: 0)
    _ = lead.event(delta: CGPoint(x: 0, y: -20), windows: [1], time: 0.4, duration: 0)
    _ = lead.follow(deltas: ["mark": CGPoint(x: 0, y: -10)], time: 0.5)
    #expect(lead.follow(deltas: ["mark": .zero], time: 0.9).isEmpty)
    #expect(lead.marks["mark"]!.predicting)
    #expect(lead.follow(deltas: ["mark": .zero], time: 1.21)["mark"] == CGPoint(x: 0, y: 20))
}

@Test func scrollLeadEndReturnsToAXAndResetsPrediction() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("mark", windowID: 1)
    _ = lead.event(delta: CGPoint(x: 5, y: -30), windows: [1], time: 0.1, duration: 0)
    #expect(lead.end()["mark"] == CGPoint(x: -5, y: 30))
    #expect(lead.marks["mark"]!.lead == .zero)
    #expect(lead.marks["mark"]!.sample == 0)
    #expect(lead.marks["mark"]!.predicting)

    var sticky = ScrollLead(mode: .throttled, time: 0)
    sticky.add("mark", windowID: 1)
    _ = sticky.event(delta: CGPoint(x: 0, y: -10), windows: [1], time: 0.1, duration: 0)
    _ = sticky.follow(deltas: ["mark": .zero], time: 0.9)
    _ = sticky.end()
    #expect(sticky.marks["mark"]!.predicting)
}

@Test func scrollLeadFreshModeUsesAXOnly() {
    var lead = ScrollLead(mode: .fresh, time: 0)
    lead.add("mark", windowID: 1)
    let delta = CGPoint(x: 0, y: -20)
    #expect(lead.event(delta: delta, windows: [1], time: 0.1, duration: 0).isEmpty)
    #expect(lead.follow(deltas: ["mark": delta], time: 0.2)["mark"] == delta)
    #expect(lead.marks["mark"]!.lead == .zero)
}

@Test func scrollLeadClassifiesOnlyAfterTenMovingFrames() {
    for (moves, changes, expected) in [(9, 9, nil), (10, 4, ScrollLead.Mode.throttled),
                                        (10, 5, .fresh), (11, 5, .throttled), (11, 6, .fresh),
                                        (12, 5, .throttled), (12, 6, .fresh)] {
        var lead = ScrollLead(mode: .fresh, time: 0)
        lead.add("mark", windowID: 1)
        for index in 0..<moves {
            _ = lead.event(delta: CGPoint(x: 0, y: -10), windows: [1], time: Double(index) * 0.01, duration: 0)
            _ = lead.follow(deltas: ["mark": index < changes ? CGPoint(x: 0, y: -10) : .zero], time: Double(index) * 0.01)
        }
        #expect(lead.moves == moves)
        #expect(lead.samples == changes)
        #expect(lead.classifiedMode == expected)
    }
}

@Test func scrollLeadAnimationFollowsSmoothstepAndStopsAtDelta() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("mark", windowID: 1)
    let delta = CGPoint(x: 32, y: -64)
    #expect(lead.event(delta: delta, windows: [1], time: 0, duration: 1).isEmpty)
    #expect(lead.advance(time: 0.25)["mark"] == CGPoint(x: 5, y: -10))
    #expect(lead.advance(time: 0.5)["mark"] == CGPoint(x: 11, y: -22))
    #expect(lead.marks["mark"]!.lead == CGPoint(x: 16, y: -32))
    #expect(lead.advance(time: 1)["mark"] == CGPoint(x: 16, y: -32))
    #expect(lead.marks["mark"]!.lead == delta)
    #expect(lead.advance(time: 1.5).isEmpty)
    #expect(lead.marks["mark"]!.lead == delta)
}

@Test func scrollLeadOverlappingAnimationsAddAndMergeHistoryByWindow() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("first", windowID: 1)
    lead.add("second", windowID: 2)
    _ = lead.event(delta: CGPoint(x: 32, y: -64), windows: [1], time: 0, duration: 1)
    let atStart = lead.event(delta: CGPoint(x: 64, y: -32), windows: [1, 2], time: 0.25, duration: 1)
    #expect(atStart["first"] == CGPoint(x: 5, y: -10))
    #expect(atStart["second"] == nil)
    let halfway = lead.advance(time: 0.5)
    #expect(halfway["first"] == CGPoint(x: 21, y: -27))
    #expect(halfway["second"] == CGPoint(x: 10, y: -5))
    #expect(lead.follow(deltas: ["first": CGPoint(x: 26, y: -37)], time: 0.5)["first"] == .zero)
    #expect(lead.marks["first"]!.sample == 2)
    let end = lead.advance(time: 1.25)
    #expect(end["first"] == CGPoint(x: 70, y: -59))
    #expect(lead.marks["first"]!.lead == CGPoint(x: 70, y: -59))
    #expect(lead.marks["second"]!.lead == CGPoint(x: 64, y: -32))
    #expect(lead.advance(time: 2).isEmpty)
}

@Test func scrollLeadMatchesMidAnimationAXSampleWithoutJumpingBack() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("mark", windowID: 1)
    _ = lead.event(delta: CGPoint(x: 32, y: -64), windows: [1], time: 0, duration: 1)
    _ = lead.advance(time: 0.25)
    _ = lead.advance(time: 0.5)
    _ = lead.advance(time: 0.75)
    #expect(lead.follow(deltas: ["mark": CGPoint(x: 16, y: -32)], time: 0.75)["mark"] == .zero)
    #expect(lead.marks["mark"]!.sample == 2)
    #expect(lead.marks["mark"]!.lead == CGPoint(x: 11, y: -22))
    #expect(lead.advance(time: 1)["mark"] == CGPoint(x: 5, y: -10))
    #expect(lead.follow(deltas: ["mark": CGPoint(x: 16, y: -32)], time: 1)["mark"] == .zero)
    #expect(lead.marks["mark"]!.lead == .zero)
}

@Test func scrollLeadFreshAnimationCountsMovingFramesWithoutTranslating() {
    var lead = ScrollLead(mode: .fresh, time: 0)
    lead.add("mark", windowID: 1)
    #expect(lead.event(delta: CGPoint(x: 0, y: -40), windows: [1], time: 0, duration: ScrollLead.keyDuration).isEmpty)
    _ = lead.follow(deltas: ["mark": .zero], time: 0)
    #expect(lead.moves == 0)
    for frame in 1...18 {
        let time = Double(frame) / 120
        #expect(lead.advance(time: time).isEmpty)
        _ = lead.follow(deltas: ["mark": .zero], time: time)
    }
    #expect(lead.moves == 18)
    #expect(lead.classifiedMode == .throttled)
    #expect(lead.marks["mark"]!.lead == .zero)
    #expect(lead.advance(time: 0.2).isEmpty)
    _ = lead.follow(deltas: ["mark": .zero], time: 0.2)
    #expect(lead.moves == 18)
}

@Test func scrollLeadCountsMultipleEventsAndAnimationAdvancesAsOneMovingFrame() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("mark", windowID: 1)
    for _ in 0..<12 {
        _ = lead.event(delta: CGPoint(x: 0, y: -1), windows: [1], time: 0, duration: 0)
    }
    _ = lead.event(delta: CGPoint(x: 0, y: -32), windows: [1], time: 0, duration: 1)
    _ = lead.advance(time: 0.25)
    _ = lead.advance(time: 0.5)
    #expect(lead.moves == 0)
    _ = lead.follow(deltas: ["mark": .zero], time: 0.5)
    #expect(lead.moves == 1)
    #expect(lead.classifiedMode == nil)
    _ = lead.follow(deltas: ["mark": .zero], time: 0.5)
    #expect(lead.moves == 1)
}

@Test func scrollLeadEndDiscardsUnfinishedAnimation() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("mark", windowID: 1)
    _ = lead.event(delta: CGPoint(x: 0, y: -40), windows: [1], time: 0, duration: 1)
    _ = lead.advance(time: 0.5)
    #expect(lead.end()["mark"] == CGPoint(x: 0, y: 20))
    #expect(lead.advance(time: 1).isEmpty)
    #expect(lead.marks["mark"]!.lead == .zero)
}

@Test func scrollLeadCountsMarksChangingInOneFrameAsOneSample() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("a", windowID: 1)
    lead.add("b", windowID: 1)
    _ = lead.follow(deltas: ["a": CGPoint(x: 0, y: -10), "b": CGPoint(x: 0, y: -10)], time: 0.5)
    #expect(lead.samples == 1)
}

@Test func scrollLeadHistoryAndPredictionStayWithinEventWindow() {
    var lead = ScrollLead(mode: .throttled, time: 0)
    lead.add("first", windowID: 1)
    lead.add("second", windowID: 2)
    let delta = CGPoint(x: 0, y: -20)
    #expect(lead.event(delta: delta, windows: [1], time: 0.1, duration: 0)["second"] == nil)
    _ = lead.event(delta: CGPoint(x: 0, y: -50), windows: [2], time: 0.2, duration: 0)
    #expect(lead.follow(deltas: ["first": delta], time: 0.3)["first"] == .zero)
    #expect(lead.marks["first"]!.lead == .zero)
    lead.add("new", windowID: 1)
    #expect(lead.marks["new"]!.sample == 2)
    lead.remove("second")
    #expect(lead.marks["second"] == nil)
}
