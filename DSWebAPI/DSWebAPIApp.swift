import SwiftUI

@main
struct DSWebAPIApp: App {
    @StateObject private var store = AppStore()

    init() {
        BackgroundKeeper.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
