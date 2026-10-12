import Foundation

public enum QuestionType: String, Codable, Sendable { case choice, noul, score }
public enum Criteria: Codable, Equatable, Sendable {
    case choices([String: String])
    case scale([String])
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let choices = try? container.decode([String: String].self) { self = .choices(choices) }
        else { self = .scale(try container.decode([String].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .choices(let choices): try container.encode(choices)
        case .scale(let scale): try container.encode(scale)
        }
    }
}
public struct DecisionQuestion: Codable, Equatable, Sendable {
    public var type: QuestionType
    public var instructions: String
    public var criteria: Criteria?
    public init(type: QuestionType, instructions: String, criteria: Criteria? = nil) {
        self.type = type; self.instructions = instructions; self.criteria = criteria
    }
}
public struct DecisionRequest: Codable, Sendable {
    public var model: String
    public var state: String
    public var questions: [String: DecisionQuestion]
    public init(model: String = "jev-latest", state: String, questions: [String: DecisionQuestion]) {
        self.model = model; self.state = state; self.questions = questions
    }
}
public struct DecisionAnswer: Codable, Sendable {
    public var type: QuestionType
    public var choice: String?
    public var confidence: Double?
    public var probabilities: [String: Double]?
    public var noul: Double?
    public var score: Double?
    public var legend: [String: String]?
    public init(type: QuestionType, choice: String? = nil, confidence: Double? = nil,
                probabilities: [String: Double]? = nil, noul: Double? = nil, score: Double? = nil) {
        self.type = type; self.choice = choice; self.confidence = confidence
        self.probabilities = probabilities; self.noul = noul; self.score = score
    }
    public var bestChoice: (key: String, probability: Double)? {
        probabilities?.sorted { $0.key < $1.key }.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}
public struct DecisionResponse: Codable, Sendable {
    public struct Usage: Codable, Sendable {
        public var input_tokens: Int
        public var output_tokens: Int
        public init(input_tokens: Int, output_tokens: Int) {
            self.input_tokens = input_tokens; self.output_tokens = output_tokens
        }
    }
    public var model: String
    public var answers: [String: DecisionAnswer]
    public var usage: Usage?
    public init(model: String, answers: [String: DecisionAnswer], usage: Usage? = nil) {
        self.model = model; self.answers = answers; self.usage = usage
    }
}
public protocol DecisionProvider: Sendable {
    func decide(_ request: DecisionRequest) async throws -> DecisionResponse
}

public enum DecisionConstants {
    public static let targetInstructions = "Which candidate best describes what the user is looking at or doing right now? Pick \"none\" if none of them fits."
    public static let worthInstructions = "Is this a good moment to show the user a short playful comment about the selected candidate? Answer yes if the screen clearly shows that situation and a comment would feel natural, no if it is ambiguous, noisy, or the user seems busy typing."
    public static let highlightInstructions = "Which numbered line is the name or title of the person the user is currently chatting with (the chat header), not a message or a list entry? Pick \"none\" if no line is the header."
    public static let moodInstructions = "What tone fits a one-line comment about this screen? tease = gently make fun of it, cheer = encourage the user, comfort = sympathize, hype = dramatic excitement."
    public static let interestInstructions = "On a scale of 0 to 9, how likely is it that a witty friend looking over the user's shoulder would make a comment right now? 0 = nothing interesting, 9 = absolutely must comment."
    public static let targetThreshold = 0.55
    public static let worthThreshold = 0.6
    public static let highlightThreshold = 0.5
    public static let interestThreshold = 6.0
    public static let noTarget = "none of them fits"
    public static let noHighlight = "no line is the header"
    public static let moodChoices = ["tease": "gently make fun of it", "cheer": "encourage the user", "comfort": "sympathize", "hype": "dramatic excitement"]
    public static let interestScale = (0...9).map(String.init)
    public static func letter(_ index: Int) -> String {
        // Excel-style letters also cover more than 26 user rules.
        var value = index + 1
        var result = ""
        while value > 0 {
            value -= 1
            result = String(UnicodeScalar(65 + value % 26)!) + result
            value /= 26
        }
        return result
    }
    public static func description(_ candidate: Candidate) -> String {
        let rule = candidate.rule
        let detail = rule.note.map { " (\($0))" } ?? ""
        return "\(rule.kind.rawValue) \"\(rule.label.zh)\"\(detail)"
    }
}

public enum StateBuilder {
    public static func build(snapshot: ContextSnapshot, candidates: [Candidate], now: Date,
                             calendar: Calendar = .current) -> String {
        var indices: [Int] = []
        let matchedIndices = candidates.flatMap { candidate in
            candidate.lineIndex.map { [$0] } ?? RuleMatcher.matchingLines(for: candidate.rule, in: snapshot).map(\.index)
        }
        for index in matchedIndices {
            for neighbor in max(0, index - 2)...min(snapshot.textLines.count - 1, index + 2) {
                if !indices.contains(neighbor) && indices.count < 12 { indices.append(neighbor) }
            }
        }
        for index in snapshot.textLines.indices where indices.count < 12 && !indices.contains(index) { indices.append(index) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE HH:mm"
        let when = When.current(at: now, calendar: calendar)
        let tags: [When: String] = [.lateNight: "late night", .mondayMorning: "Monday morning", .fridayEvening: "Friday evening"]
        var lines = ["app: \(snapshot.appName) (\(snapshot.bundleId))", "window: \(snapshot.windowTitle ?? "-")",
                     "url: \(snapshot.url ?? "-")", "time: \(formatter.string(from: now))\(tags[when].map { ", " + $0 } ?? "")", "visible text:"]
        lines += indices.sorted().map { "\($0 + 1). \(snapshot.textLines[$0].text.prefix(40))" }
        if candidates.count >= 2 {
            lines.append("candidates:")
            lines += candidates.enumerated().map { index, candidate in
                let match = candidate.matchedText.map { ", matched \"\($0)\"" } ?? ""
                let location = candidate.lineIndex.map { " in line \($0 + 1)" } ?? ""
                return "\(DecisionConstants.letter(index)). \(DecisionConstants.description(candidate))\(match)\(location)"
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct DecisionPlan: Sendable {
    public var request: DecisionRequest
    public var candidates: [Candidate]
    public var highlightLines: [String: Int]
    public var freeComment: Bool
    public var skipsProvider: Bool
}
public struct DecisionOutcome: Sendable {
    public var shouldShow: Bool
    public var candidate: Candidate?
    public var highlightLineIndex: Int?
    public var mood: String?
}
public enum DecisionError: Error, Sendable { case missingAnswer(String), invalidAnswer(String) }

public enum SystemOneDecision {
    public static func plan(snapshot: ContextSnapshot, candidates: [Candidate], freeComments: Bool,
                            needsGeneration: Bool, now: Date, calendar: Calendar = .current,
                            model: String = "jev-latest") -> DecisionPlan {
        let free = freeComments && candidates.isEmpty
        let skip = candidates.count == 1 && [.app, .site, .time].contains(candidates[0].rule.kind)
        var questions: [String: DecisionQuestion] = [:]
        var highlightLines: [String: Int] = [:]
        if !skip && (!candidates.isEmpty || free) {
            if candidates.count >= 2 {
                var choices = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { (DecisionConstants.letter($0.offset), DecisionConstants.description($0.element)) })
                choices["none"] = DecisionConstants.noTarget
                questions["target"] = DecisionQuestion(type: .choice, instructions: DecisionConstants.targetInstructions, criteria: .choices(choices))
            }
            if freeComments || candidates.contains(where: { $0.rule.kind == .person || $0.rule.kind == .topic }) {
                questions["worth"] = DecisionQuestion(type: .noul, instructions: DecisionConstants.worthInstructions)
            }
            let hits = Set(candidates.filter { $0.rule.highlight }.flatMap { RuleMatcher.matchingLines(for: $0.rule, in: snapshot).map(\.index) }).sorted()
            if hits.count >= 2 {
                var choices: [String: String] = ["none": DecisionConstants.noHighlight]
                for (offset, index) in hits.prefix(8).enumerated() {
                    let letter = DecisionConstants.letter(offset)
                    highlightLines[letter] = index
                    choices[letter] = "line \(index + 1): \(snapshot.textLines[index].text.prefix(40))"
                }
                questions["highlight"] = DecisionQuestion(type: .choice, instructions: DecisionConstants.highlightInstructions, criteria: .choices(choices))
            }
            if needsGeneration || free {
                questions["mood"] = DecisionQuestion(type: .choice, instructions: DecisionConstants.moodInstructions, criteria: .choices(DecisionConstants.moodChoices))
            }
            if free {
                questions["interest"] = DecisionQuestion(type: .score, instructions: DecisionConstants.interestInstructions, criteria: .scale(DecisionConstants.interestScale))
            }
        }
        return DecisionPlan(request: DecisionRequest(model: model, state: StateBuilder.build(snapshot: snapshot, candidates: candidates, now: now, calendar: calendar), questions: questions),
                            candidates: candidates, highlightLines: highlightLines, freeComment: free, skipsProvider: skip)
    }

    public static func evaluate(_ response: DecisionResponse?, plan: DecisionPlan, snapshot: ContextSnapshot) throws -> DecisionOutcome {
        var outcome = DecisionOutcome(shouldShow: !plan.candidates.isEmpty || plan.freeComment, candidate: plan.candidates.first,
                                      highlightLineIndex: nil, mood: nil)
        func answer(_ id: String, type: QuestionType) throws -> DecisionAnswer {
            guard let answer = response?.answers[id] else { throw DecisionError.missingAnswer(id) }
            guard answer.type == type else { throw DecisionError.invalidAnswer(id) }
            return answer
        }
        func choice(_ id: String) throws -> (key: String, probability: Double) {
            guard let best = try answer(id, type: .choice).bestChoice,
                  case .choices(let options) = plan.request.questions[id]?.criteria, options[best.key] != nil,
                  (0...1).contains(best.probability) else { throw DecisionError.invalidAnswer(id) }
            return best
        }
        if plan.request.questions["target"] != nil {
            let best = try choice("target")
            if best.key == "none" || best.probability < DecisionConstants.targetThreshold { outcome.shouldShow = false; outcome.candidate = nil; return outcome }
            outcome.candidate = plan.candidates.enumerated().first { DecisionConstants.letter($0.offset) == best.key }!.element
        }
        if plan.request.questions["worth"] != nil {
            guard let probability = try answer("worth", type: .noul).noul, (0...1).contains(probability) else { throw DecisionError.invalidAnswer("worth") }
            if probability < DecisionConstants.worthThreshold { outcome.shouldShow = false; return outcome }
        }
        if plan.request.questions["interest"] != nil {
            guard let score = try answer("interest", type: .score).score, (0...9).contains(score) else { throw DecisionError.invalidAnswer("interest") }
            if score < DecisionConstants.interestThreshold { outcome.shouldShow = false; return outcome }
        }
        if let candidate = outcome.candidate, candidate.rule.highlight {
            let hits = RuleMatcher.matchingLines(for: candidate.rule, in: snapshot)
            if plan.request.questions["highlight"] != nil {
                let best = try choice("highlight")
                if best.probability >= DecisionConstants.highlightThreshold,
                   let index = plan.highlightLines[best.key], hits.contains(where: { $0.index == index }) { outcome.highlightLineIndex = index }
            } else { outcome.highlightLineIndex = candidate.lineIndex ?? hits.first?.index }
        }
        if plan.request.questions["mood"] != nil { outcome.mood = try choice("mood").key }
        return outcome
    }
}
