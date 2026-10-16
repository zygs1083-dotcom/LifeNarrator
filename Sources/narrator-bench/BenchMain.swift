import Darwin
import Foundation
import NarratorMac

func elapsed(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
}

func rss() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw BenchError.measurement("task_info: \(result)") }
    return info.resident_size
}

func peakRSS() throws -> Int {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw BenchError.measurement("getrusage: \(errno)") }
    return usage.ru_maxrss
}

enum BenchError: Error {
    case usage, measurement(String), invalidQuips
}

struct Quips: Decodable {
    struct Quip: Decodable { let text: String; let emoji: [String] }
    let quips: [Quip]
}

let prefix = """
<|im_start|>system
You look at a description of the user's screen and answer one question with a single token.<|im_end|>
<|im_start|>user
STATE:
app: 钉钉 (com.alibaba.DingTalkMac)
window: 张三
url: -
time: Monday 23:40, late night
visible text:
1. 张三
2. 在线
3. 昨天的周报什么时候发我
4. 好的张总，马上
candidates:
A. person "张三" (user's boss), matched "张三" in line 1
B. app 钉钉 (DingTalk)


"""
let answer = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\nAnswer:"
let questions: [(String, String, [String])] = [
    ("target", "QUESTION: Which candidate best describes what the user is looking at or doing right now? Pick \"none\" if none of them fits.\nOPTIONS:\nA. person \"张三\" (user's boss)\nB. app 钉钉 (DingTalk)\nC. none\nAnswer with the letter only." + answer, [" A", " B", " C"]),
    ("worth", "QUESTION: Is this a good moment to show the user a short playful comment about candidate A? Answer yes if the screen clearly shows that situation and a comment would feel natural.\nAnswer yes or no." + answer, [" yes", " no"]),
    ("score", "QUESTION: On a scale of 0 to 9, how likely is it that a witty friend looking over the user's shoulder would make a comment right now?\nAnswer with a single digit from 0 to 9." + answer, (0...9).map { " \($0)" }),
]
let prompt = """
<|im_start|>user
你是住在用户电脑里的旁白小精灵。用户正在和领导张三聊天，外号"猪领导"。写 12 条毒舌但可爱的小旁白，每条不超过 14 个汉字，不写表情，每条配 1 到 3 个表情放进 emoji 数组。只输出 JSON。<|im_end|>
<|im_start|>assistant
<think>

</think>


"""
let grammar = #"""
root ::= "{" ws "\"quips\"" ws ":" ws "[" ws quip (ws "," ws quip){11} ws "]" ws "}" ws
quip ::= "{" ws "\"text\"" ws ":" ws text ws "," ws "\"emoji\"" ws ":" ws "[" ws emoji (ws "," ws emoji){0,2} ws "]" ws "}"
text ::= "\"" [\u4e00-\u9fff，。！？、]{1,14} "\""
emoji ::= "\"" [\U0001f300-\U0001faff\u2600-\u27bf] [\U0001f300-\U0001faff\u2600-\u27bf\ufe0f\u200d]* "\""
ws ::= [ \t\n\r]{0,4}
"""#

func run() async throws {
    if let command = CommandLine.arguments.dropFirst().first, ["compare", "--compare-worker"].contains(command) {
        let arguments = try CompareArguments(Array(CommandLine.arguments.dropFirst(2)))
        if command == "compare" { try runCompare(arguments) }
        else { try runCompareWorker(arguments) }
        return
    }
    if CommandLine.arguments.dropFirst().first == "variety" {
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        let rounds: Int
        if arguments.isEmpty { rounds = 2 }
        else {
            guard arguments.count == 2, arguments[0] == "--rounds", let count = Int(arguments[1]), count > 0 else {
                throw BenchError.usage
            }
            rounds = count
        }
        try await runVariety(rounds: rounds)
        return
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "sprite" {
        try await runSprite(modelPath: CommandLine.arguments[2])
        return
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--quality" {
        try runQuality(modelPath: CommandLine.arguments[1])
        return
    }
    guard CommandLine.arguments.count == 2 else { throw BenchError.usage }
    let path = CommandLine.arguments[1]
    let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as! NSNumber
    print("model: \(path)")
    print("file_bytes: \(size)")
    let loadStart = ContinuousClock.now
    let engine = try LlamaEngine(modelPath: path)
    let loadSeconds = elapsed(loadStart)
    print("load_seconds: \(loadSeconds)")
    print("loaded_rss_bytes: \(try rss())")
    for (name, suffix, options) in questions {
        let start = ContinuousClock.now
        let probabilities = try engine.optionProbabilities(prefix: prefix, suffix: suffix, options: options)
        print("\(name)_seconds: \(elapsed(start))")
        print("\(name)_prefix_prefill_seconds: \(engine.prefixPrefillSeconds)")
        print("\(name)_probabilities: \(zip(options, probabilities).map { "\($0.0.trimmingCharacters(in: .whitespaces))=\($0.1)" }.joined(separator: ", "))")
    }
    let start = ContinuousClock.now
    let output = try engine.generate(prompt: prompt, grammar: grammar, maxTokens: 1536)
    let generationSeconds = elapsed(start)
    print("raw_output: \(output)")
    print("generation_seconds: \(generationSeconds)")
    print("generated_tokens: \(engine.generatedTokens)")
    print("tokens_per_second: \(Double(engine.generatedTokens) / generationSeconds)")
    print("peak_rss_bytes: \(try peakRSS())")
    let decoded = try JSONDecoder().decode(Quips.self, from: Data(output.utf8))
    guard decoded.quips.count == 12,
          decoded.quips.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 14 && (1...3).contains($0.emoji.count) }) else {
        throw BenchError.invalidQuips
    }
    print("validation: 12 quips, text <= 14 characters, 1...3 emoji strings each")
}

@main
struct BenchMain {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("Usage: narrator-bench compare --models a.gguf,b.gguf [--draft draft.gguf [--draft-tokens 1...8] | --mtp]\n", stderr)
            fputs("narrator-bench failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
