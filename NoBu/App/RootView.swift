import SwiftUI

/// 下タブ4つ。**左端は記録**（日付ごとの時系列。開いてまず見たいのは「最近なにをしたか」なので、
/// 起動時もここ・2026-09-23）。タブごとに `NavigationStack` を持ち、本のページはどのタブからも同じ形で開く。
///
/// **設定は下タブから外した**（2026-09-23）。下タブは一等地で、めったに開かない設定に1枠使うのは惜しい。
/// 代わりに記録タブ・本棚タブのナビゲーションバー右上の歯車から開く。
struct RootView: View {
    enum TabID: Hashable { case timeline, shelf, search, scan }

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

/// ナビゲーションバー右上の歯車。下タブから外した設定の入口（記録タブ・本棚タブに付ける）
struct SettingsToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink { SettingsView() } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("設定")
        }
    }
}
