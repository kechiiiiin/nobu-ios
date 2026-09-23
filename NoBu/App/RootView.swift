import SwiftUI

/// 下タブ4つ（Web 版の「さがす／スキャン／本棚」＋ネイティブだけの「設定」）。
/// タブごとに `NavigationStack` を持ち、本のページはどのタブからも同じ形で開く。
struct RootView: View {
    enum TabID: Hashable { case search, scan, shelf, settings }

    @Environment(ToastCenter.self) private var toasts
    @State private var tab: TabID = .search

    var body: some View {
        TabView(selection: $tab) {
            Tab("さがす", systemImage: "magnifyingglass", value: TabID.search) {
                NavigationStack { SearchView() }
            }
            Tab("スキャン", systemImage: "barcode.viewfinder", value: TabID.scan) {
                NavigationStack { ScanView(isSelected: tab == .scan) }
            }
            Tab("本棚", systemImage: "books.vertical", value: TabID.shelf) {
                NavigationStack { ShelfView() }
            }
            Tab("設定", systemImage: "gearshape", value: TabID.settings) {
                NavigationStack { SettingsView() }
            }
        }
        .overlay(alignment: .bottom) {
            ToastOverlay()
                .padding(.bottom, 52)   // タブバーの上に出す
        }
        .animation(.spring(duration: 0.25), value: toasts.current?.id)
    }
}

/// 本のページへ飛ぶ（`navigationDestination(for: Int.self)` と対で使う）
extension View {
    func bookDestination() -> some View {
        navigationDestination(for: Int.self) { id in BookView(id: id) }
    }
}
