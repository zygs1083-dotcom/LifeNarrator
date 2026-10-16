import XCTest
@testable import NarratorLlama

final class LlamaChatTests: XCTestCase {
    // A template containing these GGUF control tokens is detected as ChatML by b11429.
    private let qwen = "{{ '<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>\\n' }}"

    func testQwenMatchesPreviousSerialization() throws {
        for system in [nil, "", "系统指令\nReturn JSON."] as [String?] {
            let chat = try LlamaChat.render(template: qwen, system: system, user: "屏幕\nhello", disableThinking: true)
            let prefix = system.map { "<|im_start|>system\n\($0)<|im_end|>\n" }
            XCTAssertEqual(chat.prefix, prefix)
            XCTAssertEqual(chat.prompt, (prefix ?? "") + "<|im_start|>user\n屏幕\nhello<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        }
    }

    func testNonQwenDoesNotReceiveThinkBlock() throws {
        let chat = try LlamaChat.render(template: qwen, system: "rules", user: "hello", disableThinking: false)
        XCTAssertEqual(chat.prefix, "<|im_start|>system\nrules<|im_end|>\n")
        XCTAssertTrue(chat.prompt.hasSuffix("<|im_start|>assistant\n"))
        XCTAssertFalse(chat.prompt.contains("<think>"))
        let minicpm = try LlamaChat.render(template: "minicpm", system: "rules", user: "hello", disableThinking: false)
        XCTAssertTrue(minicpm.prompt.contains("<用户>hello<AI>"))
        XCTAssertFalse(minicpm.prompt.contains("<|im_start|>"))
    }

    func testUnsupportedTemplateFails() {
        XCTAssertThrowsError(try LlamaChat.render(template: "unknown-format", system: nil, user: "hello", disableThinking: false))
    }
}
