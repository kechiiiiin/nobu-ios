import Foundation

/// バーコードの読み取り結果から「確定」を決める（誤読防止）。Worker の `shared/scangate.ts` の移植。
///   - 書籍の ISBN-13（978/979・検算合格）だけを拾う。2段目（192…）などは黙って捨てる
///   - 同じ値を連続2回読んだら確定（間が confirmGap 以上空いたら数え直し）
///   - 直前に確定したのと同じ ISBN は sameIgnore の間は無視
///   - 取り消し・失敗した ISBN は「一度カメラから外れるまで」確定しない
final class ScanGate {
    static let confirmGap: TimeInterval = 1.5
    static let sameIgnore: TimeInterval = 10
    /// 取り消した本が「外れた」とみなすまでの、写らない時間（1フレームの読み損じで解けないように）
    static let gone: TimeInterval = 1.0

    private var candidate: (code: String, at: TimeInterval)?
    private var lastConfirmed: (code: String, at: TimeInterval)?
    private var held: (code: String, lastSeen: TimeInterval)?

    /// 1フレーム分の読み取り結果（何も読めなかったフレームは空配列）を渡す。確定した ISBN があれば返す
    func feed(_ codes: [String], now: TimeInterval) -> String? {
        let isbn = codes.first(where: ISBN.isBookIsbn13)
        if let h = held {
            if isbn == h.code {
                held = (h.code, now)
                candidate = nil
                return nil
            }
            // 別の本が写った、または gone 以上写っていない → 解く
            if isbn != nil || now - h.lastSeen >= Self.gone { held = nil } else { return nil }
        }
        guard let isbn else { return nil }
        if let last = lastConfirmed, last.code == isbn, now - last.at < Self.sameIgnore { return nil }
        if let c = candidate, c.code == isbn, now - c.at <= Self.confirmGap {
            candidate = nil
            lastConfirmed = (isbn, now)
            return isbn
        }
        candidate = (isbn, now)
        return nil
    }

    /// 取り消したとき・登録に失敗したとき。10秒の無視は解くが、
    /// その本が一度カメラから外れる（gone 以上写らない）か別の本が写るまでは確定しない
    func holdUntilGone(_ code: String, now: TimeInterval) {
        if lastConfirmed?.code == code { lastConfirmed = nil }
        if candidate?.code == code { candidate = nil }
        held = (code, now)
    }
}
