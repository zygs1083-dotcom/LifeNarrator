import NarratorBrain
import SwiftUI

struct MemorySettingsView: View {
    @ObservedObject var store: AppStore
    let showRules: () -> Void
    @State private var selected: Memory?
    @State private var adding = false
    @State private var confirmClear = false
    private let hue = AppTheme.hue(175)
    static let kinds: [Memory.Kind] = [.nickname, .fact, .preference, .episode]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.text("memory.privacy"))
                .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
            GroupBox {
                LabeledContent(store.text("memory.enabled")) {
                    Toggle(store.text("memory.enabled"), isOn: $store.settings.memoryEnabled).labelsHidden()
                }.frame(minHeight: 28)
                HStack {
                    Button(store.text("memory.add")) { adding = true }
                        .buttonStyle(AppTheme.CapsuleButton(hue: hue))
                        .disabled(!store.settings.memoryEnabled)
                    Spacer()
                    Button(store.text("memory.clear")) { confirmClear = true }
                        .buttonStyle(AppTheme.CapsuleButton(hue: AppTheme.hue(350), filled: false))
                        .disabled(store.memories.isEmpty)
                }
            } label: { CardHeading(title: store.text("memory.title"), symbol: "brain", hue: hue) }
            ForEach(Self.kinds, id: \.self) { kind in
                category(kind)
            }
        }
        .sheet(isPresented: $adding) { MemoryEditor(store: store, memory: nil) }
        .sheet(item: $selected) { MemoryEditor(store: store, memory: $0) }
        .confirmationDialog(store.text("memory.clear.confirm"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(store.text("memory.clear"), role: .destructive) { store.perform { try store.clearMemories() } }
            Button(store.text("cancel"), role: .cancel) {}
        } message: { Text(store.text("memory.clear.hint")) }
    }

    private func category(_ kind: Memory.Kind) -> some View {
        let entries = store.memories.filter { $0.kind == kind }.sorted { $0.pinned && !$1.pinned }
        let rules = kind == .preference ? store.rules : []
        return GroupBox {
            if entries.isEmpty && rules.isEmpty {
                Text(store.text("memory.empty")).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
            }
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    Text(verbatim: entry.text).foregroundStyle(AppTheme.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.perform { try store.pinMemory(id: entry.id, pinned: !entry.pinned) } } label: {
                        Image(systemName: entry.pinned ? "pin.fill" : "pin")
                            .foregroundStyle(entry.pinned ? hue.text : AppTheme.textSecondary)
                    }
                    .help(store.text(entry.pinned ? "memory.unpin" : "memory.pin"))
                    .accessibilityLabel(store.text(entry.pinned ? "memory.unpin" : "memory.pin"))
                    Button { selected = entry } label: { Image(systemName: "pencil") }
                        .help(store.text("memory.edit")).accessibilityLabel(store.text("memory.edit"))
                    Button { store.perform { try store.deleteMemory(id: entry.id) } } label: { Image(systemName: "trash") }
                        .help(store.text("delete")).accessibilityLabel(store.text("delete"))
                }
                .buttonStyle(.plain).foregroundStyle(AppTheme.textSecondary).frame(minHeight: 28)
            }
            ForEach(rules, id: \.id) { rule in
                Button(action: showRules) {
                    HStack {
                        Text(verbatim: rule.input ?? rule.label[store.settings.language.lang])
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        Text(store.text("memory.rule")).font(AppTheme.font(.caption))
                        Image(systemName: "arrow.up.right").accessibilityHidden(true)
                    }.foregroundStyle(hue.text).frame(minHeight: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help(store.text("memory.rule.hint"))
                    .accessibilityHint(store.text("memory.rule.hint"))
            }
        } label: {
            HStack {
                CardHeading(title: store.text("memory.kind.\(kind.rawValue)"), symbol: symbol(kind), hue: hue)
                Spacer()
                Badge(text: "\(entries.count + rules.count)", hue: hue)
            }
        }
    }

    private func symbol(_ kind: Memory.Kind) -> String {
        switch kind {
        case .nickname: "person.crop.circle"
        case .fact: "bookmark.fill"
        case .preference: "heart.fill"
        case .episode: "clock.fill"
        }
    }
}

struct MemoryEditor: View {
    @ObservedObject var store: AppStore
    let memory: Memory?
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Memory.Kind
    @State private var text: String
    @State private var error: String?

    init(store: AppStore, memory: Memory?) {
        self.store = store
        self.memory = memory
        _kind = State(initialValue: memory?.kind ?? .fact)
        _text = State(initialValue: memory?.text ?? "")
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !trimmed.isEmpty && trimmed.count <= 40 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.text(memory == nil ? "memory.add" : "memory.edit")).font(AppTheme.font(.cardTitle))
            Picker(store.text("memory.category"), selection: $kind) {
                ForEach(MemorySettingsView.kinds, id: \.self) { kind in
                    Text(store.text("memory.kind.\(kind.rawValue)")).tag(kind)
                }
            }
            LabeledContent(store.text("memory.content")) {
                TextField(store.text("memory.content"), text: $text).textFieldStyle(.roundedBorder)
                    .onSubmit { if valid { save() } }
            }
            Text(store.text("memory.length"))
                .font(AppTheme.font(.caption)).foregroundStyle(AppTheme.textSecondary)
            if let error {
                Text(verbatim: error).font(AppTheme.font(.caption)).foregroundStyle(AppTheme.hue(350).text)
            }
            HStack {
                Spacer()
                Button(store.text("cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(store.text("memory.save")) { save() }.keyboardShortcut(.defaultAction).disabled(!valid)
            }.buttonStyle(AppTheme.CapsuleButton())
        }
        .padding(20).frame(width: 460).background(AppTheme.windowBackground)
        .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
    }

    private func save() {
        do {
            if let memory { try store.editMemory(id: memory.id, kind: kind, text: trimmed) }
            else if try store.addMemory(kind: kind, text: trimmed) == nil {
                error = store.text("memory.duplicate")
                return
            }
            dismiss()
        } catch { self.error = String(describing: error) }
    }
}
