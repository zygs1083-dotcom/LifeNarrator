import Foundation
import NarratorMac

private struct ShuffleRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

private struct ExamplePack: Decodable {
    struct Rule: Decodable {
        let id: String
        let quips: [Example]
    }
    struct Example: Decodable {
        let lang: String
        let persona: String
        let text: String
        let emoji: [String]
    }
    let rules: [Rule]
}

private struct GenerationScene {
    let id: String
    let label: String
    let kind: String
    let note: String
    let persona: String
    let personaDescription: String
    let exampleRules: [String]
}

private let generationScenes = [
    GenerationScene(id: "boss-sharp", label: "领导张三", kind: "person", note: "张三是用户的领导，外号猪领导；用户想轻轻吐槽聊天和催工作，不攻击个人。", persona: "sharp", personaDescription: "毒舌：嘴碎、爱吐槽、一针见血，但本质是损友，损完还会留一分可爱。不骂人，不攻击外貌、智商、家庭。", exampleRules: ["builtin.app.dingtalk", "builtin.time.fridayEvening"]),
    GenerationScene(id: "google-chuuni", label: "谷歌", kind: "site", note: "用户讨厌谷歌，但正在打开谷歌搜索；把搜索说成可爱的史诗冒险。", persona: "chuuni", personaDescription: "中二：把日常说成史诗，爱用封印、结界、宿命、吾、汝，自我感觉良好，气势十足但人畜无害。", exampleRules: ["builtin.site.google", "builtin.app.terminal"]),
    GenerationScene(id: "meeting-gentle", label: "开会", kind: "topic", note: "用户讨厌开会，看到文档里的会议安排，想得到一句温柔的安慰。", persona: "gentle", personaDescription: "温柔：软软的、会安慰人、会给小鼓励，像一只贴心的小动物。可以撒娇，不说教。", exampleRules: ["builtin.app.tencentmeeting", "builtin.app.calendar"]),
]

private let qualityGrammar = #"""
root ::= "{" ws "\"quips\"" ws ":" ws "[" ws quip (ws "," ws quip){5} ws "]" ws "}" ws
quip ::= "{" ws "\"text\"" ws ":" ws text ws "," ws "\"emoji\"" ws ":" ws "[" ws emoji (ws "," ws emoji){0,2} ws "]" ws "}"
text ::= "\"" [\u4e00-\u9fff，。！？、：；——…《》“”]{1,14} "\""
emoji ::= "\"" [\U0001f300-\U0001faff\u2600-\u27bf] [\U0001f300-\U0001faff\u2600-\u27bf\ufe0f\u200d]* "\""
ws ::= [ \t\n\r]{0,4}
"""#

func runQuality(modelPath: String) throws {
    let model = URL(fileURLWithPath: modelPath).lastPathComponent
    let size = try FileManager.default.attributesOfItem(atPath: modelPath)[.size] as! NSNumber
    let start = ContinuousClock.now
    let engine = try LlamaEngine(modelPath: modelPath)
    try emit(["type": "load", "model": model, "file_bytes": size, "seconds": elapsed(start), "rss_bytes": try rss()])

    for variant in 1...3 {
        for (index, sample) in decisionCases.enumerated() {
            let none = DecisionCandidate(id: "none", description: "none", explanation: "Choose this if no listed candidate describes the current focus.")
            var candidates = sample.candidates + [none]
            var worthOptions = ["yes", "no"]
            var random = ShuffleRandom(state: UInt64(index + 1) &+ 20261013)
            if variant == 3 {
                candidates.shuffle(using: &random)
                worthOptions.shuffle(using: &random)
            }
            let letters = candidates.indices.map { String(UnicodeScalar(65 + $0)!) }
            let stateCandidates = zip(letters, candidates).filter { $0.1.id != "none" }.map {
                "\($0.0). \($0.1.description)"
            }.joined(separator: "\n")
            let prefix = "<|im_start|>system\nYou look at a description of the user's screen and answer one question with a single token.<|im_end|>\n<|im_start|>user\nSTATE:\n\(sample.state)\ncandidates:\n\(stateCandidates)\n\n"
            let ending = variant == 1 ? "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\nAnswer:" : "<|im_end|>\n<|im_start|>assistant\nAnswer:"
            let targetOptions = zip(letters, candidates).map {
                "\($0.0). \($0.1.description.components(separatedBy: ", ").first!)" + (variant == 1 ? "" : ". \($0.1.explanation)")
            }.joined(separator: "\n")
            let targetPrompt = prefix + "QUESTION: Which candidate best describes what the user is looking at or doing right now? Pick \"none\" if none of them fits.\nOPTIONS:\n\(targetOptions)\nAnswer with the letter only." + ending
            let targetStart = ContinuousClock.now
            // Full independent forwards keep the hybrid Qwen3.5 model comparable without KV rollback.
            let target = try engine.optionProbabilities(prefix: "", suffix: targetPrompt, options: letters.map { " " + $0 })
            let targetSeconds = elapsed(targetStart)
            let targetIndex = target.indices.max(by: { target[$0] < target[$1] })!
            let targetProbabilities = Dictionary(uniqueKeysWithValues: zip(candidates.map(\.id), target))
            let worthIndex = candidates.firstIndex { $0.id == sample.worthCandidate }!
            var worthQuestion = "QUESTION: Is this a good moment to show the user a short playful comment about candidate \(letters[worthIndex])? Answer yes if the screen clearly shows that situation and a comment would feel natural.\n"
            if variant != 1 {
                worthQuestion += "OPTIONS:\n" + worthOptions.map {
                    $0 == "yes" ? "yes. The candidate clearly applies, and a comment would feel natural now." : "no. The candidate is ambiguous or incidental, or the user is busy typing or concentrating."
                }.joined(separator: "\n") + "\n"
            }
            worthQuestion += "Answer " + worthOptions.joined(separator: " or ") + "." + ending
            let worthStart = ContinuousClock.now
            let worth = try engine.optionProbabilities(prefix: "", suffix: prefix + worthQuestion, options: worthOptions.map { " " + $0 })
            let yes = worth[worthOptions.firstIndex(of: "yes")!]
            try emit([
                "type": "decision", "model": model, "variant": "V\(variant)", "case": sample.id,
                "expected_target": sample.expectedTarget, "expected_worth": sample.expectedWorth,
                "worth_candidate": sample.worthCandidate, "target_order": candidates.map(\.id), "worth_order": worthOptions,
                "target_probabilities": targetProbabilities, "yes_probability": yes,
                "predicted_target": candidates[targetIndex].id, "predicted_worth": yes >= 0.5,
                "target_seconds": targetSeconds, "worth_seconds": elapsed(worthStart),
                "target_prompt": targetPrompt, "worth_prompt": prefix + worthQuestion,
            ])
        }
    }

    let pack = try JSONDecoder().decode(ExamplePack.self, from: Data(contentsOf: URL(fileURLWithPath: "Sources/NarratorCore/Resources/quips.json")))
    for scene in generationScenes {
        let examples = scene.exampleRules.flatMap { id in
            pack.rules.first { $0.id == id }!.quips.filter { $0.lang == "zh" && $0.persona == scene.persona }.prefix(2)
        }.prefix(3)
        let exampleText = examples.map { "{\"text\":\"\($0.text)\",\"emoji\":[\($0.emoji.map { "\"\($0)\"" }.joined(separator: ","))]}" }.joined(separator: "\n")
        let instruction = """
        你是 LifeNarrator，一只住在用户电脑里的旁白小精灵。用户在屏幕上遇到下面这个对象时，你会弹出一句小旁白。请写 6 条。

        对象：\(scene.label)（\(scene.kind)）
        用户的态度：dislike
        背景：\(scene.note)

        人设：\(scene.personaDescription)

        要求：
        - 每条不超过 14 个汉字（标点算字，不写表情）。
        - 可爱、好笑、像朋友随口一句，不是口号。
        - 不恶毒：不攻击外貌、智商、家庭、身份；不脏话；不涉及政治、宗教、色情、暴力。
        - 每条配 1 到 3 个表情，放在 emoji 数组里，文字里不要出现表情。
        - 6 条之间角度不同，不要换个词重复同一句。
        - 只输出 JSON。

        同人设风格示例：
        \(exampleText)
        """
        let prompt = "<|im_start|>user\n" + instruction + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        var allText: [String] = []
        for batch in 1...2 {
            let generationStart = ContinuousClock.now
            let output = try engine.generate(prompt: prompt, grammar: qualityGrammar, maxTokens: 1024)
            let seconds = elapsed(generationStart)
            let decoded = try JSONDecoder().decode(Quips.self, from: Data(output.utf8))
            guard decoded.quips.count == 6,
                  decoded.quips.allSatisfy({ !$0.text.isEmpty && $0.text.count <= 14 && (1...3).contains($0.emoji.count) }) else {
                throw BenchError.invalidQuips
            }
            allText += decoded.quips.map(\.text)
            try emit([
                "type": "generation", "model": model, "scene": scene.id, "batch": batch,
                "raw_output": output, "seconds": seconds, "tokens": engine.generatedTokens,
                "tokens_per_second": Double(engine.generatedTokens) / seconds,
                "rss_bytes": try rss(), "prompt": prompt, "example_rules": scene.exampleRules,
            ])
        }
        try emit(["type": "dedup", "model": model, "scene": scene.id, "count": allText.count, "unique": Set(allText).count, "ratio": Double(Set(allText).count) / Double(allText.count)])
    }
    try emit(["type": "complete", "model": model, "peak_rss_bytes": try peakRSS()])
}
