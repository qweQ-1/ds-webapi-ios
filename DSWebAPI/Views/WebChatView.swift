import SwiftUI
import WebKit

/// 「网页」页：内嵌真实的 DeepSeek 网页。
///
/// 这一页就是 API 的发动机：聊天请求不是我们自己拼的，而是让这个网页去发，
/// 再把网页自己收到的回复截下来，转成 API 返回。
/// 所以登录、PoW、风控令牌、会话管理全都不用我们操心。
struct WebChatView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var driver: WebChatDriver
    @State private var refreshing = false

    init() {
        _driver = ObservedObject(wrappedValue: WebChatDriver.shared)
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            WebChatContainer()
        }
        .task {
            await driver.ensureLoaded()
            await driver.refreshStatus()
            // 页面里登录 / 登出都会改登录态，这里定期同步一下状态显示
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await driver.refreshStatus()
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(driver.status)
                    .font(.caption)
                    .lineLimit(1)
                if !driver.loggedIn {
                    Text("在下面的网页里登录一次，API 就能用了")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                Task {
                    refreshing = true
                    await driver.reload()
                    refreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(refreshing)
            .buttonStyle(.borderless)

            Button {
                Task { await driver.startNewConversation() }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var statusColor: Color {
        if !driver.loggedIn { return .orange }
        if driver.status.hasPrefix("失败") { return .red }
        if driver.composerFound { return .green }
        return .yellow
    }
}

/// 承载网页端的 WKWebView。
///
/// 网页视图一直挂在视图树里（只是切换标签时 TabView 把它藏起来），
/// 所以切到别的标签页以后它照样在后台加载、执行 JS，API 随时能用。
struct WebChatContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground
        let web = WebChatDriver.shared.attachTo(container)
        web.frame = container.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let web = WebChatDriver.shared.webView, web.superview !== uiView else { return }
        web.removeFromSuperview()
        uiView.addSubview(web)
        web.frame = uiView.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
}
