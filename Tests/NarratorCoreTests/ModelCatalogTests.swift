import Foundation
import Testing
@testable import NarratorCore

@Test func sharedBuiltinModelCatalog() {
    let models = ModelCatalog.models
    #expect(models.map(\.name) == ["Qwen3.5-4B-Q4_K_M", "Qwen3.5-2B-Q4_K_M"])
    for model in models {
        #expect(model.url.host == "huggingface.co")
        #expect(model.url.pathComponents[3] == "resolve")
        #expect(model.url.pathComponents[4].count == 40)
        #expect(model.sha256.count == 64)
        #expect(model.size > 1_000_000_000)
        #expect(model.filename == model.name + ".gguf")
    }
}
