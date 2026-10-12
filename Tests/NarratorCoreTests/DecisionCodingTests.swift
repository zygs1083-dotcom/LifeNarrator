import Foundation
import Testing
@testable import NarratorCore

@Test func systemOneEncodesQuestionsAsObjectAndCriteriaAsObjectOrArray() throws {
    let questions = [
        "target": DecisionQuestion(type: .choice, instructions: DecisionConstants.targetInstructions, criteria: .choices(["A": "person 张三 (user's boss)", "B": "app 钉钉", "none": "none of them fits"])),
        "worth": DecisionQuestion(type: .noul, instructions: DecisionConstants.worthInstructions),
        "interest": DecisionQuestion(type: .score, instructions: DecisionConstants.interestInstructions, criteria: .scale(DecisionConstants.interestScale))]
    let decision = DecisionRequest(state: "screen", questions: questions)
    let request = try SystemOneClient(baseURL: URL(string: "https://example.test")!, key: "key").makeRequest(decision)
    #expect(request.url?.absoluteString == "https://example.test/v1/systemone")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(body["model"] as? String == "jev-latest")
    #expect(body["state"] as? String == "screen")
    let object = body["questions"] as! [String: [String: Any]]
    #expect((object["target"]!["criteria"] as! [String: String])["B"] == "app 钉钉")
    #expect(object["worth"]!["criteria"] == nil)
    #expect(object["interest"]!["criteria"] as? [String] == (0...9).map(String.init))
    let roundTrip = try JSONDecoder().decode(DecisionRequest.self, from: request.httpBody!)
    #expect(roundTrip.questions == questions)
    let noKey = try SystemOneClient(baseURL: URL(string: "https://example.test/")!).makeRequest(decision)
    #expect(noKey.value(forHTTPHeaderField: "Authorization") == nil)
}
@Test func systemOneDecodesOnlineResponseSample() throws {
    let json = #"""
    {"model":"jev-latest","answers":{
      "target":{"type":"choice","choice":"A","confidence":0.7,"probabilities":{"A":0.71,"B":0.21,"none":0.08}},
      "worth":{"type":"noul","noul":0.83},
      "interest":{"type":"score","score":5.9,"probabilities":{"0":0.01,"1":0.0},"confidence":0.5}
    },"usage":{"input_tokens":238,"output_tokens":39}}
    """#
    let response = try JSONDecoder().decode(DecisionResponse.self, from: Data(json.utf8))
    #expect(response.answers["target"]?.choice == "A")
    #expect(response.answers["target"]?.confidence == 0.7)
    #expect(response.answers["target"]?.bestChoice?.probability == 0.71)
    #expect(response.answers["worth"]?.noul == 0.83)
    #expect(response.answers["interest"]?.score == 5.9)
    #expect(response.usage?.input_tokens == 238)
    #expect(response.usage?.output_tokens == 39)
}
