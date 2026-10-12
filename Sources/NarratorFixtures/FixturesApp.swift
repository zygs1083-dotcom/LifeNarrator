import SwiftUI

@main
struct FixturesApp: App {
    var body: some Scene {
        Window("Fixture Chat", id: "single") {
            ChatFixtureView(group: false)
                .background(OpenFixtures())
        }
        .defaultSize(width: 800, height: 600)
        Window("Fixture Group", id: "group") {
            ChatFixtureView(group: true)
        }
        .defaultSize(width: 800, height: 600)
        Window("Fixture Document", id: "document") {
            VStack(alignment: .leading, spacing: 24) {
                Text("工作安排").font(.title2)
                Text("明天下午开会")
                Text("请提前准备项目进度和需要讨论的问题。")
                Spacer()
            }
            .padding(32)
            .frame(minWidth: 600, minHeight: 400, alignment: .topLeading)
        }
        .defaultSize(width: 700, height: 500)
    }
}

private struct OpenFixtures: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.task {
            openWindow(id: "group")
            openWindow(id: "document")
        }
    }
}

struct ChatFixtureView: View {
    let group: Bool
    @State private var imageContent = false
    @State private var draft = ""
    private var title: String { group ? "项目群" : "张三" }
    private var messages: [String] {
        group ? ["李四：张三已经看过这份计划了", "我：收到，稍后更新进度", "王五：下周一起确认"]
            : ["张三：今天下班前把周报发我", "我：好的，正在整理", "张三：辛苦了"]
    }

    var body: some View {
        GeometryReader { geometry in
            if imageContent {
                Canvas { context, size in
                    let sidebar = size.width * 0.28
                    context.fill(Path(CGRect(x: 0, y: 0, width: sidebar, height: size.height)), with: .color(.gray.opacity(0.1)))
                    context.draw(Text("张三").font(.system(size: 14)), at: CGPoint(x: 16, y: 26), anchor: .leading)
                    context.draw(Text("今天下班前把周报发我").font(.system(size: 11)), at: CGPoint(x: 16, y: 50), anchor: .leading)
                    context.draw(Text("项目群").font(.system(size: 14)), at: CGPoint(x: 16, y: 104), anchor: .leading)
                    context.draw(Text(title).font(.system(size: 17)), at: CGPoint(x: sidebar + 20, y: 28), anchor: .leading)
                    for (index, message) in messages.enumerated() {
                        context.draw(Text(message).font(.system(size: 14)),
                                     at: CGPoint(x: sidebar + 20, y: 190 + CGFloat(index) * 40), anchor: .leading)
                    }
                }
                .accessibilityHidden(true)
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("张三").font(.system(size: 14))
                        Text("今天下班前把周报发我").font(.system(size: 11))
                        Text("项目群").font(.system(size: 14)).padding(.top, 28)
                        Spacer()
                    }
                    .padding(16)
                    .frame(width: geometry.size.width * 0.28, height: geometry.size.height, alignment: .topLeading)
                    .background(.gray.opacity(0.1))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.system(size: 17))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .frame(height: 56)
                        Divider()
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(messages, id: \.self) { Text($0).font(.system(size: 14)) }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 120)
                        Spacer()
                        TextField("输入消息", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .padding(20)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(.top, 28)
        .frame(minWidth: 700, minHeight: 500)
        .toolbar {
            if group { Toggle("图片内容（OCR）", isOn: $imageContent) }
        }
    }
}
