import AppKit
import NarratorCore
import SwiftUI

final class AnnouncementWindow: NSWindow {
    var onClose: (() -> Void)?
    override func close() { onClose?(); super.close() }
}

struct AnnouncementView: View {
    @ObservedObject var store: AppStore
    let announcement: UpdateAnnouncement
    let dismiss: () -> Void
    private var lang: Lang { store.settings.language.lang }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(announcement.title.value(lang)).font(AppTheme.font(.pageTitle))
                Spacer()
                Text("v" + NarratorCore.version).font(AppTheme.font(.badge)).foregroundStyle(AppTheme.textSecondary)
            }
            ScrollView {
                GroupBox {
                    Text(announcement.intro.value(lang)).foregroundStyle(AppTheme.textSecondary)
                    ForEach(announcement.items.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 10) {
                            Text("•").foregroundStyle(AppTheme.accentDeep)
                            Text(announcement.items[index].value(lang)).frame(maxWidth: .infinity, alignment: .leading)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                } label: { CardHeading(title: announcement.title.value(lang), symbol: "sparkles", hue: AppTheme.hue(42)) }
                .padding(2)
            }
            HStack { Spacer(); Button(announcement.dismiss.value(lang), action: dismiss)
                .buttonStyle(AppTheme.CapsuleButton()).keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(minWidth: 280, minHeight: 200)
        .font(AppTheme.font(.body)).foregroundStyle(AppTheme.textPrimary)
        .groupBoxStyle(.card).background(AppTheme.windowBackground)
    }
}
