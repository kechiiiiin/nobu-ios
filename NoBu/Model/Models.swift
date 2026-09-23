import Foundation

/// Worker の `shared/types.ts` と同じ形。フィールド名はサーバーの JSON に合わせる（snake_case のまま）。

/// paused（保留）＝読んでいる途中で止めているもの。読書の回は開いたまま残る
enum Status: String, Codable, CaseIterable, Identifiable, Sendable {
    case want, bought, reading, paused, read

    var id: String { rawValue }
    var label: String {
        switch self {
        case .want:    return "気になる"
        case .bought:  return "買った"
        case .reading: return "読んでる"
        case .paused:  return "保留"
        case .read:    return "読了"
        }
    }
}

struct Owned: Codable, Hashable, Sendable {
    let id: Int
    let status: Status
}

/// 検索・ISBN 引きの候補（まだ本棚に無い本）。POST /api/books にそのまま送り返す
struct Candidate: Codable, Hashable, Sendable, Identifiable {
    var isbn13: String?
    var title: String
    var author: String?
    var publisher: String?
    var pubdate: String?
    var cover_url: String?
    var cover_kind: String
    var cover_unverified: Bool?
    var meta_source: String
    var owned: Owned?

    var id: String { (isbn13 ?? "") + title }

    /// 「著者・出版社・発行年」の1行
    var meta: String {
        [author, publisher, pubdate.map { String($0.prefix(4)) }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・")
    }
}

struct Book: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    /// 持ち主。いまは1人だけ（Worker が古いときのために省略可にしてある）
    var user_id: Int?
    var isbn13: String?
    var title: String
    var author: String?
    var publisher: String?
    var pubdate: String?
    var cover_url: String?
    var cover_kind: String
    var meta_source: String
    var status: Status
    var status_at: String
    /// 最新の読了日（JST の 'YYYY-MM-DD'）
    var finished_at: String?
    var is_public: Int
    var created_at: String
    var updated_at: String
    /// 一覧のときだけ: 読書中の回の読み始めた日
    var reading_since: String?

    var meta: String {
        [publisher, pubdate].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・")
    }
}

/// 読書の1回。started_on が nil＝読み始め不明、finished_on が nil＝読書中（または中断中）
struct ReadingSession: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var book_id: Int
    var started_on: String?
    var finished_on: String?
    var created_event_id: Int?
    var finished_event_id: Int?
    var created_at: String
    var updated_at: String
}

/// 実際に読んだ日（JST の 'YYYY-MM-DD'）。同じ本の同じ日は1行だけ
struct ReadingDay: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var book_id: Int
    var on: String
    /// 状態の切り替えで自動的に入った日の印（手で押した「今日読んだ」は nil）
    var created_event_id: Int?
    var created_at: String
}

struct BookEvent: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var book_id: Int
    var from_status: Status?
    var to_status: Status
    var at: String
    var via: String?
}

struct BookNote: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var book_id: Int
    var body: String
    var is_public: Int
    var created_at: String
    var updated_at: String
}

struct SearchResponse: Codable, Sendable {
    var candidates: [Candidate]
    var sources: [String]
    var rakuten: String
}

struct AddResponse: Codable, Sendable {
    /// "created" / "advanced" / "already"
    var result: String
    var book: Book
    var event_id: Int?
    var session: ReadingSession?
}

struct PatchResponse: Codable, Sendable {
    var book: Book
    var event_id: Int?
    var session: ReadingSession?
}

struct BookDetail: Codable, Sendable {
    var book: Book
    var notes: [BookNote]
    var events: [BookEvent]
    /// 新しい順
    var sessions: [ReadingSession]
    /// 読んだ日。新しい順。
    /// ⚠️ Worker より先にアプリだけ新しくなっても本のページが壊れないよう、省略可にしてある
    var days: [ReadingDay]?
}

/// 「記録する」の結果（POST /api/books/:id/record）。
/// 状態の切り替えと読んだ日を1回で確定するので、返ってくるのは確定後の本のページまるごと
struct RecordResponse: Decodable, Sendable {
    var detail: BookDetail
    /// 取り消し用。状態が変わらなかった（読んだ日だけ足した）ときは nil
    var event_id: Int?
}

struct MeResponse: Codable, Sendable {
    var email: String
    var rakuten: Bool
    var counts: [String: Int]
}

struct NoteResponse: Codable, Sendable { var note: BookNote }
struct DayResponse: Codable, Sendable { var day: ReadingDay }
struct SessionResponse: Codable, Sendable { var session: ReadingSession; var book: Book }
struct BookResponse: Codable, Sendable { var book: Book }
struct UndoResponse: Codable, Sendable { var result: String; var book: Book? }
struct OKResponse: Codable, Sendable { var ok: Bool }

// MARK: - タイムライン（「記録」タブ。GET /api/timeline）

/// タイムラインに出す本（書影と書名だけ）
struct TimelineBook: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var title: String
    var cover_url: String?
    var cover_kind: String
}

/// 状態が変わった1件
struct TimelineStatus: Codable, Hashable, Sendable {
    var cursor: String
    var day: String
    var event_id: Int
    var at: String
    var from_status: Status?
    var to_status: Status
    var via: String?
    var book: TimelineBook
}

/// その日に読んだ本（同じ日は1件にまとまっている）
struct TimelineRead: Codable, Hashable, Sendable {
    var cursor: String
    var day: String
    var books: [TimelineBook]
}

/// `kind` で分かれる1件。Worker の `TimelineItem` と同じ
enum TimelineItem: Decodable, Hashable, Sendable, Identifiable {
    case status(TimelineStatus)
    case read(TimelineRead)

    private enum Key: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .kind)
        switch kind {
        case "read":   self = .read(try TimelineRead(from: decoder))
        case "status": self = .status(try TimelineStatus(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "知らない kind: \(kind)"))
        }
    }

    /// 並びの鍵。次のページの `before` にもなる（重複しないので id に使える）
    var cursor: String {
        switch self {
        case .status(let s): return s.cursor
        case .read(let r):   return r.cursor
        }
    }
    var id: String { cursor }

    /// JST の日付
    var day: String {
        switch self {
        case .status(let s): return s.day
        case .read(let r):   return r.day
        }
    }
}

struct TimelineResponse: Decodable, Sendable {
    var items: [TimelineItem]
    /// 次のページの `before`。これ以上無ければ nil
    var next: String?
}

/// タイムラインの「何をしたか」（Worker の `eventLabel` と同じ）
func eventLabel(from: Status?, to: Status) -> String {
    if to == .reading, from == .paused { return "読書を再開した" }
    switch to {
    case .want:    return "気になるに入れた"
    case .bought:  return "買った"
    case .reading: return "読み始めた"
    case .paused:  return "保留にした"
    case .read:    return "読了"
    }
}

/// 手入力（見つからない本）
struct ManualBook: Codable, Sendable {
    var title = ""
    var author = ""
    var publisher = ""
    var pubdate = ""
    var isbn13 = ""
}

/// 1回分の表示（web の sessionText と同じ）。
/// 例: 2026-09-10 〜 2026-09-23（14日）／2026-09-10 〜（読書中・3日目）
func sessionText(_ s: ReadingSession, bookStatus: Status, isLatestOpen: Bool, today: String = JST.today()) -> (range: String, note: String) {
    let from = s.started_on ?? "（読み始め不明）"
    if let fin = s.finished_on {
        let note = s.started_on.map { "\(JST.daysInclusive(from: $0, to: fin))日" } ?? ""
        return ("\(from) 〜 \(fin)", note)
    }
    if bookStatus == .reading, isLatestOpen, let started = s.started_on {
        return ("\(from) 〜", "読書中・\(JST.daysInclusive(from: started, to: today))日目")
    }
    return ("\(from) 〜", "中断")
}
