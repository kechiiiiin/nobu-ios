import SwiftUI

/// 下タブ5つ。**左端は記録**（日付ごとの時系列。開いてまず見たいのは「最近なにをしたか」なので、
/// 起動時もここ・2026-09-23）。タブごとに `NavigationStack` を持ち、本のページはどのタブからも同じ形で開く。
struct RootView: View {
    enum TabID: Hashable { case timeline, shelf, search, scan, settings }

    @Environment(ToastCenter.self) private var toasts
    @State private var tab: TabID = .timeline

    var body: some View {
        TabView(selection: $tab) {
            Tab("記録", systemImage: "clock", value: TabID.timeline) {
                NavigationStack { TimelineView() }
            }
            Tab("本棚", systemImage: "books.vertical", value: TabID.shelf) {
                NavigationStack { ShelfView() }
            }
            Tab("さがす", systemImage: "magnifyingglass", value: TabID.search) {
                NavigationStack { SearchView() }
            }
            Tab("スキャン", systemImage: "barcode.viewfinder", value: TabID.scan) {
                NavigationStack { ScanView(isSelected: tab == .scan) }
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
