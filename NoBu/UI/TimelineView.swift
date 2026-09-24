import SwiftUI

/// 記録。日付ごとに「何をしたか」を新しい順に並べる（Reads のプロフィールの時系列表示が元）。
///
/// 出すのは2つだけ:
///   1. 状態の変化（買った／読み始めた／読了／保留にした／気になるに入れた）
///   2. その日に読んだ本（同じ日は1行にまとめる）
/// ひとこと感想は出さない。並べ替えも併合も Worker（`GET /api/timeline`）がやるので、
/// ここは受け取った順に日付で区切って描くだけ。
struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [TimelineItem] = []
    @State private var next: String?
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorText: String?

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
                    ForEach(section.items) { item in row(item) }
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
        .navigationDestination(for: TimelineRead.self) { ReadDayView(read: $0) }
        .refreshable { await reload() }
        // 他の画面で登録・状態変更をしたら読み直す（本棚と同じ合図）
        .task(id: model.shelfToken) { await reload() }
    }

    // MARK: - 行

    @ViewBuilder
    private func row(_ item: TimelineItem) -> some View {
        switch item {
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
        case .read(let r):
            readRow(r)
        }
    }

    /// 「読んだ」。**1冊でも複数でも同じ形**（書影＋書名＋「読んだ」＋右端の「>」ひとつ）。
    /// 1冊ならその本のページへ、複数ならその日に読んだ本の一覧（`ReadDayView`）へ行く。
    ///
    /// ⚠️ 行の中に `NavigationLink` を入れ子にしないこと（2026-09-24）。List は中の NavigationLink
    /// ごとに「>」を付けるので、書影ごとにリンクにしていた頃は書影のあいだに「>」が並び、
    /// 書名も「A／B」と繋げていたので1行に見えず崩れていた。
    @ViewBuilder
    private func readRow(_ r: TimelineRead) -> some View {
        if let only = r.books.first, r.books.count == 1 {
            NavigationLink(value: only.id) { readBody(r) }
        } else {
            NavigationLink(value: r) { readBody(r) }
        }
    }

    private func readBody(_ r: TimelineRead) -> some View {
        HStack(alignment: .center, spacing: 10) {
            StackedCovers(books: r.books)
            VStack(alignment: .leading, spacing: 2) {
                Text(readTitle(r)).font(.subheadline).lineLimit(2)
                Text(r.books.count > 1 ? "\(r.books.count)冊 読んだ" : "読んだ")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("読んだ：" + r.books.map(\.title).joined(separator: "、"))
    }

    /// 1冊なら書名、複数なら「最初の書名 ほか◯冊」（書名を繋げると長くて読めない）
    private func readTitle(_ r: TimelineRead) -> String {
        guard let first = r.books.first else { return "" }
        return r.books.count > 1 ? "\(first.title) ほか\(r.books.count - 1)冊" : first.title
    }

    // MARK: - 日付ごとのまとまり（すでに新しい順で届いているので、続いた同じ日をまとめるだけ）

    private struct DaySection: Identifiable {
        let day: String
        var items: [TimelineItem]
        var id: String { day }
    }

    private var sections: [DaySection] {
        var out: [DaySection] = []
        for item in items {
            if out.last?.day == item.day { out[out.count - 1].items.append(item) }
            else { out.append(DaySection(day: item.day, items: [item])) }
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

/// 書影を少しずつ右へずらして重ねる（複数冊を1行に収めるため）。手前（最初の本）がいちばん上。
/// **枠は1冊ぶんのまま**にして、奥の書影は書名とのあいだの余白（10pt）へはみ出させる——
/// こうすると1冊の行・状態の行と書名の頭が揃う。
private struct StackedCovers: View {
    let books: [TimelineBook]
    private static let step: CGFloat = 4

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(books.prefix(3).enumerated().reversed()), id: \.element.id) { index, book in
                CoverView(url: book.cover_url, title: book.title, size: .tiny)
                    .offset(x: CGFloat(index) * Self.step)
            }
        }
        .frame(width: CoverView.Size.tiny.width, height: CoverView.Size.tiny.height, alignment: .topLeading)
    }
}

/// ある日に読んだ本（記録タブで複数冊まとまった「読んだ」の行から開く）。各行はその本のページへ。
struct ReadDayView: View {
    let read: TimelineRead

    var body: some View {
        List(read.books) { book in
            NavigationLink(value: book.id) {
                HStack(spacing: 10) {
                    CoverView(url: book.cover_url, title: book.title, size: .tiny)
                    Text(book.title).font(.subheadline).lineLimit(2)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationTitle("\(read.day) に読んだ本")
        .navigationBarTitleDisplayMode(.inline)
    }
}
