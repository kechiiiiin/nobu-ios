import Foundation

enum APIError: LocalizedError {
    /// Keychain にサービストークンが無い
    case notConfigured
    /// Access を通れなかった（401/403、ログイン画面への転送）
    case unauthorized
    case http(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "サービストークンが入っていません（設定タブ）"
        case .unauthorized:  return "Cloudflare Access を通れませんでした（サービストークンを確かめてください）"
        case .transport(let m): return "通信できませんでした（\(m)）"
        case .http(let code, let e):
            switch e {
            case "bad_isbn":              return "ISBN が正しくありません"
            case "title_required":        return "書名が要ります"
            case "bad_date":              return "日付が正しくありません"
            case "future_date":           return "未来の日付は入れられません"
            case "finished_before_started": return "読了日が読み始めより前になっています"
            case "finished_required":     return "読了日が要ります"
            case "empty_session":         return "日付をどちらか入れてください"
            case "close_with_button":     return "いま読んでいる回は「読了」ボタンで閉じてください"
            case "open_session_delete":   return "いま読んでいる回は消せません（状態を戻してから）"
            case "isbn_taken":            return "その ISBN の本がもうあります"
            case "not_latest":            return "最新の記録ではないので取り消せません"
            case "not_found":             return "見つかりませんでした"
            case "bad_cursor", "bad_limit": return "記録の続きを読めませんでした"
            case "days_required":         return "日付を選んでください"
            case "too_many_days":         return "日付が多すぎます"
            case "bad_status":            return "状態が正しくありません"
            default:                      return "エラー（\(code) \(e)）"
            }
        }
    }
}

/// リダイレクトを追わない（Access のセッション切れは別オリジンのログイン画面への 302。
/// 追いかけると HTML の 200 になって「成功」に見えてしまう）
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// NoBu の Worker（https://nobu.kechiiiiin.com）を叩く。
/// 認証は Cloudflare Access の**サービストークン**（`CF-Access-Client-Id` / `CF-Access-Client-Secret`）。
/// 値は Keychain から毎回読む（Keychain に入れ直せば、アプリを入れ直さなくても効く）。
final class NobuAPI {
    static let shared = NobuAPI()

    static let baseURL = URL(string: "https://nobu.kechiiiiin.com")!

    private let session: URLSession
    private let noRedirect = NoRedirect()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(configuration: config)
    }

    var isConfigured: Bool { AccessTokenStore.isComplete }

    // MARK: - 下まわり

    private func request(_ method: String, _ path: String, body: Data? = nil) throws -> URLRequest {
        guard let id = AccessTokenStore.clientID.load(), !id.isEmpty,
              let secret = AccessTokenStore.clientSecret.load(), !secret.isEmpty else {
            throw APIError.notConfigured
        }
        guard let url = URL(string: path, relativeTo: Self.baseURL) else { throw APIError.transport("URL が作れません") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
        req.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func call<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> T {
        let data = try await raw(method, path, body: body)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.transport("応答を読めませんでした")
        }
    }

    @discardableResult
    private func raw(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> Data {
        var payload: Data?
        if let body { payload = try? encoder.encode(AnyEncodable(body)) }
        let req = try request(method, path, body: payload)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req, delegate: noRedirect)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as NSError).code == NSURLErrorCancelled { throw CancellationError() }
            throw APIError.transport((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("応答がありません") }
        // Access のログイン画面への転送・401/403 はどれも「通れなかった」
        if (300..<400).contains(http.statusCode) || http.statusCode == 401 || http.statusCode == 403 {
            throw APIError.unauthorized
        }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if !type.contains("application/json") {
            // JSON 以外が返る＝ログイン画面などの HTML
            throw APIError.unauthorized
        }
        if !(200..<300).contains(http.statusCode) {
            let code = (try? JSONDecoder().decode([String: AnyCode].self, from: data))?["error"]?.string ?? "error"
            throw APIError.http(http.statusCode, code)
        }
        return data
    }

    // MARK: - API（web/api.ts と同じ並び）

    func me() async throws -> MeResponse { try await call("GET", "/api/me") }

    func search(_ q: String) async throws -> SearchResponse {
        let escaped = q.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
        return try await call("GET", "/api/search?q=\(escaped)")
    }

    func books(status: Status?) async throws -> [Book] {
        struct R: Decodable { let books: [Book] }
        let path = status.map { "/api/books?status=\($0.rawValue)" } ?? "/api/books"
        let r: R = try await call("GET", path)
        return r.books
    }

    func book(_ id: Int) async throws -> BookDetail { try await call("GET", "/api/books/\(id)") }

    /// タイムライン（「記録」）。`before` は前のページの `next` をそのまま渡す（新しい順・続きは古い方へ）
    func timeline(before: String? = nil, limit: Int = 50) async throws -> TimelineResponse {
        var path = "/api/timeline?limit=\(limit)"
        if let before, !before.isEmpty {
            // カーソルには '#' が入る。エスケープしないとフラグメント扱いでクエリが切れる
            path += "&before=\(before.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")"
        }
        return try await call("GET", path)
    }

    func addCandidate(_ candidate: Candidate, status: Status) async throws -> AddResponse {
        struct Body: Encodable { let candidate: Candidate; let status: Status; let via = "search" }
        return try await call("POST", "/api/books", body: Body(candidate: candidate, status: status))
    }

    func addIsbn(_ isbn: String, status: Status) async throws -> AddResponse {
        struct Body: Encodable { let isbn: String; let status: Status; let via = "scan" }
        return try await call("POST", "/api/books", body: Body(isbn: isbn, status: status))
    }

    func addManual(_ manual: ManualBook, status: Status) async throws -> AddResponse {
        struct Body: Encodable { let manual: ManualBook; let status: Status; let via = "manual" }
        return try await call("POST", "/api/books", body: Body(manual: manual, status: status))
    }

    /// 状態の切り替え（`on` は JST の日付・省略＝今日）・書誌の手直し・公開/非公開
    func patch(_ id: Int, _ body: [String: JSONValue]) async throws -> PatchResponse {
        try await call("PATCH", "/api/books/\(id)", body: body)
    }

    /// 「記録する」。状態と日付をまとめて確定する（サーバー側で1バッチ＝途中で半分だけ残らない）。
    /// `days` は JST の 'YYYY-MM-DD'。「読んでる」「読了」は複数、それ以外はひとつだけ
    func record(_ id: Int, status: Status, days: [String]) async throws -> RecordResponse {
        struct Body: Encodable { let status: Status; let days: [String] }
        return try await call("POST", "/api/books/\(id)/record", body: Body(status: status, days: days))
    }

    /// 公開／非公開（非公開にすると RSS に出なくなる。本棚・記録には今までどおり出る）
    func setPublic(_ id: Int, _ isPublic: Bool) async throws -> Book {
        try await patch(id, ["is_public": .bool(isPublic)]).book
    }

    func addSession(bookId: Int, started: String?, finished: String?) async throws -> SessionResponse {
        // 型を明示する（`body` は `any Encodable` なので、辞書リテラルのままでは要素の型が決まらない）
        let body: [String: JSONValue] = ["started_on": .string(started), "finished_on": .string(finished)]
        return try await call("POST", "/api/books/\(bookId)/sessions", body: body)
    }

    func editSession(_ id: Int, _ body: [String: JSONValue]) async throws -> SessionResponse {
        try await call("PATCH", "/api/sessions/\(id)", body: body)
    }

    func deleteSession(_ id: Int) async throws -> BookResponse { try await call("DELETE", "/api/sessions/\(id)") }

    /// 読んだ日にする（`on` を省くと今日）。二度押しても増えない
    func markDay(bookId: Int, on: String? = nil) async throws -> ReadingDay {
        let body: [String: JSONValue] = on.map { ["on": .string($0)] } ?? [:]
        let r: DayResponse = try await call("POST", "/api/books/\(bookId)/days", body: body)
        return r.day
    }

    func unmarkDay(bookId: Int, on: String) async throws { _ = try await raw("DELETE", "/api/books/\(bookId)/days/\(on)") }

    func refetch(_ id: Int) async throws -> BookResponse { try await call("POST", "/api/books/\(id)/refetch") }

    func remove(_ id: Int) async throws { _ = try await raw("DELETE", "/api/books/\(id)") }

    func undo(eventId: Int) async throws -> UndoResponse { try await call("POST", "/api/events/\(eventId)/undo") }

    func addNote(bookId: Int, body: String, isPublic: Bool = false) async throws -> BookNote {
        let payload: [String: JSONValue] = ["body": .string(body), "is_public": .bool(isPublic)]
        let r: NoteResponse = try await call("POST", "/api/books/\(bookId)/notes", body: payload)
        return r.note
    }

    func editNote(_ id: Int, _ body: [String: JSONValue]) async throws -> BookNote {
        let r: NoteResponse = try await call("PATCH", "/api/notes/\(id)", body: body)
        return r.note
    }

    func deleteNote(_ id: Int) async throws { _ = try await raw("DELETE", "/api/notes/\(id)") }
}

// MARK: - JSON の小道具

/// `[String: JSONValue]` で任意のボディを作る（null を明示的に送れることが要る。
/// 読書の回の日付は「null＝不明／読書中」で、キーを省くのとは意味が違う）
enum JSONValue: Encodable {
    case string(String?)
    case int(Int)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): if let v { try c.encode(v) } else { try c.encodeNil() }
        case .int(let v):    try c.encode(v)
        case .bool(let v):   try c.encode(v)
        }
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// エラー本文の `{"error": "..."}` を取り出すだけの器
private struct AnyCode: Decodable {
    let string: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        string = try? c.decode(String.self)
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#")
        return set
    }()
}
