import SwiftUI

/// 記録。日付ごとに「何をしたか」を新しい順に並べる（Reads のプロフィールの時系列表示が元）。
///
/// 出すのは2つだけ:
///   1. 状態の変化（買った／読み始めた／読了／保留にした／気になるに入れた）
///   2. その日に読んだ本（同じ日に複数冊でも、1冊ずつ他の行と同じ形で並べる）
/// ひとこと感想は出さない。並べ替えは Worker（`GET /api/timeline`）がやるので、
/// ここは受け取った順に日付で区切って描くだけ。Worker は同じ日の複数冊を1件（`books` 配列）に
/// まとめて返すが、アプリ側で1冊ずつの行へ展開する（2026-09-24。以前は「◯◯ ほか◯冊」の
/// 1行にまとめていたが、1冊ずつ普通の行として見たいという要望で戻した）。
struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [TimelineItem] = []
    @State private var next: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorText: String?

    /// 表示用に1行ぶんへ展開した後の行。`.read` は `TimelineRead.books` を1冊ずつに割る。
    private enum Row: Identifiable {
        case status(TimelineStatus)
        case read(day: String, id: String, book: TimelineBook)

        var id: String {
            switch self {
            case .status(let s): return s.cursor
            case .read(_, let id, _): return id
            }
        }
        var day: String {
            switch self {
            case .status(let s): return s.day
            case .read(let day, _, _): return day
            }
        }
    }

    /// `items` を1行ずつに展開したもの。同じ `TimelineRead` から出た行が id で衝突しないよう、
    /// カーソル（並びの鍵。重複しない）に本の id を足して行ごとの id にする。
    private var rows: [Row] {
        items.flatMap { item -> [Row] in
            switch item {
            case .status(let s):
                return [.status(s)]
            case .read(let r):
                return r.books.map { .read(day: r.day, id: "\(r.cursor)-\($0.id)", book: $0) }
            }
        }
    }

    var body: some View {
        List {
            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red)
            }
            if loading && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            } else if items.isEmpty && errorText == nil {
                Text("まだ記録がありません。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in self.row(row) }
                } header: {
                    Text(JST.friendly(section.day))
                }
            }
            if next != nil {
                // 下まで来たら続き（古い方）を読む
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .task { await loadMore() }
            }
        }
        .listStyle(.plain)
        // 素の List はバーの下に 22pt の余白を自前で足す（`scrollContent` の上マージン）。
        // 日付の見出しには元から上下の余白があるので、重ねるとタイトルの下が間延びする（2026-09-24）
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationTitle("記録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsToolbarItem() }
        .bookDestination()
        .refreshable { await reload() }
        // 他の画面で登録・状態変更をしたら読み直す（本棚と同じ合図）
        .task(id: model.shelfToken) { await reload() }
    }

    // MARK: - 行

    @ViewBuilder
    private func row(_ row: Row) -> some View {
        switch row {
        case .status(let s):
            NavigationLink(value: s.book.id) {
                HStack(alignment: .center, spacing: 10) {
                    CoverView(url: s.book.cover_url, title: s.book.title, size: .tiny)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.book.title).font(.subheadline).lineLimit(2)
                        Text(eventLabel(from: s.from_status, to: s.to_status))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        case .read(_, _, let book):
            NavigationLink(value: book.id) {
                HStack(alignment: .center, spacing: 10) {
                    CoverView(url: book.cover_url, title: book.title, size: .tiny)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).font(.subheadline).lineLimit(2)
                        Text("読んだ").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 日付ごとのまとまり（すでに新しい順で届いているので、続いた同じ日をまとめるだけ）

    private struct DaySection: Identifiable {
        let day: String
        var rows: [Row]
        var id: String { day }
    }

    private var sections: [DaySection] {
        var out: [DaySection] = []
        for row in rows {
            if out.last?.day == row.day { out[out.count - 1].rows.append(row) }
            else { out.append(DaySection(day: row.day, rows: [row])) }
        }
        return out
    }

    // MARK: - 読み込み

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await NobuAPI.shared.timeline()
            items = r.items
            next = r.next
            errorText = nil
        } catch is CancellationError {
            return
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loadingMore, let cursor = next else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let r = try await NobuAPI.shared.timeline(before: cursor)
            // 読み直しと行き違って古い続きが返ってきても混ざらないよう、カーソルが動いていないときだけ足す
            guard next == cursor else { return }
            items.append(contentsOf: r.items)
            next = r.next
        } catch is CancellationError {
            return
        } catch {
            // 続きが読めなかったら、それ以上せがまない（引っぱって更新でやり直せる）
            next = nil
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
