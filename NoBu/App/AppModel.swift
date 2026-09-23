import Foundation

/// 画面をまたいで共有する、ごく小さな状態。
/// - 本棚のタブに出す冊数（`GET /api/me` の `counts`）
/// - どこかで登録・状態変更をしたときに、本棚に「読み直して」と伝える合図
@MainActor
@Observable
final class AppModel {
    var counts: [String: Int] = [:]
    /// 値が変わったら本棚が読み直す（`.task(id:)` の種）
    private(set) var shelfToken = 0

    func shelfChanged() {
        shelfToken &+= 1
        Task { await refreshCounts() }
    }

    func refreshCounts() async {
        // 冊数は飾りなので、取れなければ黙って諦める（本文のエラーは各画面が出す）
        if let me = try? await NobuAPI.shared.me() { counts = me.counts }
    }
}
