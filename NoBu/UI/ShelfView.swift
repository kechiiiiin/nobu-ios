import SwiftUI

/// 本棚。状態（読んでる／買った／気になる／読了／保留）で切り替える書影の格子。
/// 読了だけは年ごとの見出しでまとめる（Web 版の shelf.tsx と同じ並び）。
/// 保留はいちばん右（めったに見ないので端へ・2026-09-23）。
///
/// ⚠️ **格子から状態は変えられない**（2026-09-23）。書影を押すと本のページへ行くだけ。
/// 状態を変える入口を本のページ一本に絞ってあるのは、記録が RSS で公開されるため——
/// 一覧での誤タップがそのまま公開に載るのを避ける。
struct ShelfView: View {
    private static let tabs: [Status] = [.reading, .bought, .want, .read, .paused]
    private static let columns = [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: 14, alignment: .top)]

    @Environment(AppModel.self) private var model
    @State private var status: Status = .reading
    @State private var books: [Book] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                picker
                if let errorText {
                    Text(errorText).font(.callout).foregroundStyle(.red).padding(.horizontal)
                }
                if loading && books.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if books.isEmpty && errorText == nil {
                    Text("まだありません。").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(groups, id: \.label) { group in
                    if !group.label.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(group.label).font(.headline)
                            Text("\(group.books.count)冊").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 14) {
                        ForEach(group.books) { book in
                            NavigationLink(value: book.id) { cell(book) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("本棚")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsToolbarItem() }
        .bookDestination()
        .refreshable { await load() }
        // タブを変えたとき・他の画面で登録したときに読み直す
        .task(id: Key(status: status, token: model.shelfToken)) { await load() }
    }

    private struct Key: Equatable { let status: Status; let token: Int }

    /// 状態の切替え。5つをセグメントに詰めると窮屈なので、**横に流せるチップ**にしてある
    /// （ラベルと冊数を両方出せて、将来 状態が増えても潰れない・2026-09-23 Keisuke の選択）。
    ///
    /// ⚠️ **チップは縦スクロールの中身の先頭に置く。`safeAreaInset(edge: .top)` に戻さないこと**（2026-09-24）。
    /// 以前は `safeAreaInset` に置いて `.background(.bar)` を敷いていたが、そうすると横 ScrollView の枠が
    /// ナビゲーションバーの下まで伸び、iOS 26 のスクロールエッジ効果（バーの下に敷かれるぼかし）と
    /// 重なって**チップの帯が塗りつぶされ、1つも見えなくなった**（押せるし状態も変わるのに見えない）。
    /// `.scrollEdgeEffectHidden` で打ち消すとシミュレータ（26.0〜26.5）では直ったが、実機の 26.6.2 では
    /// 真っ黒のままだった——OS の装飾を打ち消す手はバージョンごとに効いたり効かなかったりする。
    /// 中身の一部にしておけば、バーの装飾とはそもそも重ならない。スクロールすると一緒に上へ流れるが、
    /// 上へ戻せば（ステータスバーのタップでも）また押せる。固定ヘッダ（pinned）にしないのも同じ理由で、
    /// 固定するとバーの直下＝エッジ効果の縁に張りつくことになる。
    private var picker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.tabs) { s in
                    Button { status = s } label: { chip(s) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("shelf-chip-\(s.rawValue)")
                        .accessibilityLabel(s.label)
                        .accessibilityAddTraits(s == status ? [.isSelected] : [])
                }
            }
            .padding(.horizontal)
        }
    }

    private func chip(_ s: Status) -> some View {
        let selected = s == status
        return HStack(spacing: 5) {
            Text(s.label).font(.subheadline.weight(selected ? .semibold : .regular))
            if let n = model.counts[s.rawValue] {
                Text("\(n)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: Capsule())
    }

    private func cell(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverView(url: book.cover_url, title: book.title, size: .small)
            Text(book.title).font(.caption2).lineLimit(2).foregroundStyle(.primary)
            if book.status == .reading || book.status == .paused, let since = book.reading_since {
                Text("\(since)〜").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if book.status == .read, let finished = book.finished_at {
                Text("\(JST.jstDate(finished)) 読了").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(width: CoverView.Size.small.width, alignment: .leading)
    }

    private struct Group: Identifiable {
        let label: String
        var books: [Book]
        var id: String { label }
    }

    /// 読了は「読了した年」ごと、それ以外はひとかたまり
    private var groups: [Group] {
        guard status == .read else { return books.isEmpty ? [] : [Group(label: "", books: books)] }
        var out: [Group] = []
        for book in books {
            let year = String(JST.jstDate(book.finished_at ?? book.status_at).prefix(4))
            if let index = out.firstIndex(where: { $0.label == year }) { out[index].books.append(book) }
            else { out.append(Group(label: year.isEmpty ? "—" : year, books: [book])) }
        }
        return out
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            books = try await NobuAPI.shared.books(status: status)
            errorText = nil
        } catch is CancellationError {
            return
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await model.refreshCounts()
    }
}
