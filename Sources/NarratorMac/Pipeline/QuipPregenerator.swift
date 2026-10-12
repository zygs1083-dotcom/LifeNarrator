import Foundation
import NarratorCore

/// Fills in quips for the current persona and language on enabled user rules that lack them,
/// two batches of six per rule. One generation task runs at a time; a request during a run queues one more pass.
@MainActor
final class QuipPregenerator {
    private unowned let store: AppStore
    private var task: Task<Void, Never>?
    private var pending = false

    init(store: AppStore) { self.store = store }

    func schedule() {
        pending = true
        guard task == nil else { return }
        task = Task {
            while pending {
                pending = false
                do { try await fill() } catch { store.error = String(describing: error) }
            }
            task = nil
        }
    }

    private func fill() async throws {
        guard let generator = try store.textGenerator() else { return }
        let lang = store.settings.language.lang
        let persona = store.settings.persona.rawValue
        let missing = store.rules.filter { rule in
            rule.enabled && !rule.quips.contains { $0.lang == lang && $0.persona.rawValue == persona }
        }.map(\.id)
        for id in missing {
            for _ in 0..<2 {
                // The rule may have been deleted while an earlier batch was generating.
                guard var rule = store.rules.first(where: { $0.id == id }) else { break }
                do {
                    rule.quips += try await RuleCompiler.generateQuips(for: rule, lang: lang, persona: .init(rawValue: persona)!, generator: generator, n: 6)
                } catch {
                    store.error = String(describing: error)
                    break
                }
                guard store.rules.contains(where: { $0.id == id }) else { break }
                try store.update(rule)
            }
        }
    }
}
