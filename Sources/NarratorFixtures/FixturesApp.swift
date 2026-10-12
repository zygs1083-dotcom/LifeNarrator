import SwiftUI

// Stand-in windows for testing on a real Mac without launching personal apps like DingTalk or WeChat.
@main
struct FixturesApp: App {
    var body: some Scene {
        WindowGroup("Chat — 张三") {
            ChatFixtureView(contact: "张三")
        }
    }
}

struct ChatFixtureView: View {
    let contact: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(contact)
                .font(.headline)
                .padding(12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("\(contact)：今天下班前把周报发我")
                Text("我：好的")
            }
            .padding(12)
            Spacer()
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
