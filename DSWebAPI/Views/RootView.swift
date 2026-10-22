import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right") }
            ApiView()
                .tabItem { Label("接口", systemImage: "point.3.connected.trianglepath.dotted") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .onAppear {
            store.refreshCredentialState()
        }
    }
}

/// 带复制按钮的一行
struct CopyRow: View {
    let title: String
    let value: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark.circle" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        }
    }
}
