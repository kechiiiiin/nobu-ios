import SwiftUI

/// アプリの入口。
///
/// 起動のたびに `LaunchConfig.applyIfPresent()` を呼ぶ。Mac から `make import-access` で置いた
/// サービストークンは、ここで Keychain へ移されてファイルが消える（値は画面にもログにも出さない）。
@main
struct NoBuApp: App {
    @State private var toasts = ToastCenter()
    @State private var model = AppModel()

    init() {
        LaunchConfig.applyIfPresent()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(toasts)
                .environment(model)
        }
    }
}
