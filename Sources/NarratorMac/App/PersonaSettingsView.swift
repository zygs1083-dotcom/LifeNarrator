import NarratorCore
import SwiftUI

struct PersonaSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var creating = false
    private let hue = AppTheme.hue(320)

    var body: some View {
        let lang = store.settings.language.lang
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(store.personas.profiles) { profile in
                    VStack(alignment: .leading, spacing: 6) {
                        ChoiceCards(options: [(value: profile.id, emoji: profile.emoji,
                                               title: profile.name[lang], caption: profile.caption[lang])],
                                    selection: $store.settings.persona, hue: hue)
                        if profile.id.rawValue.hasPrefix("custom.") {
                            Button(role: .destructive) { store.perform { try store.deletePersona(profile.id) } } label: {
                                Label(store.text("persona.custom.delete"), systemImage: "trash")
                            }
                            .font(AppTheme.font(.caption))
                        }
                    }
                }
                Button { creating = true } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "plus.circle").font(.system(size: 24)).accessibilityHidden(true)
                        Text(store.text("persona.custom.add")).font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(store.text("persona.custom.hint")).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading).padding(12)
                    .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.cardStroke, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(store.personaModelUnavailableReason != nil)
            }
            if let reason = store.personaModelUnavailableReason {
                Text(verbatim: reason).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
            }
        }
        .sheet(isPresented: $creating) { CustomPersonaView(store: store) }
    }
}

struct CustomPersonaView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var generating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.text("persona.custom.add")).font(.headline)
            Text(store.text("persona.custom.description")).font(AppTheme.font(.body))
            TextField(store.text("persona.custom.placeholder"), text: $input)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(store.text("persona.custom.description"))
                .disabled(generating)
                .onSubmit { if canGenerate { generate() } }
            if let error { Text(verbatim: error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if generating {
                    ProgressView().controlSize(.small)
                    Text(store.text("persona.custom.generating")).font(.caption)
                }
                Spacer()
                Button(store.text("persona.custom.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(generating)
                Button(store.text("persona.custom.generate"), action: generate)
                    .keyboardShortcut(.defaultAction).disabled(!canGenerate)
            }
        }
        .padding(24).frame(width: 460)
        .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
        .background(AppTheme.windowBackground)
        .interactiveDismissDisabled(generating)
    }

    private var canGenerate: Bool { !generating && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func generate() {
        generating = true
        error = nil
        Task {
            do {
                try await store.createPersona(input.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } catch { self.error = String(describing: error) }
            generating = false
        }
    }
}
