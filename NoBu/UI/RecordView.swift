import SwiftUI

/// 「記録する」の下ごしらえ。**状態を選ぶ → 日を決める → 「記録する」で確定**の三手のうち、真ん中と三手目。
///
/// なぜこうしたか（2026-09-23 Keisuke との合意）:
///   記録を RSS で公開するので、**誤タップがそのまま公開に載る**のを止めたい。
///   RSS は一度読まれたら取り消せないので、「載ってから消す」ではなく**載る前に止める**。
///   だから確定を押すまで何ひとつ保存しない。
///
/// 日は複数選べる（「読んでる」「読了」のとき）。選んだ日はそのまま読んだ日になり、
/// **いちばん早い日＝読み始めた日**。「読了」は**いちばん遅い日＝読了日**。
/// 既定は今日が選ばれた状態なので、そのまま「記録する」を押せば一手で終わる。
struct RecordPanel: View {
    let book: Book
    let status: Status
    @Binding var picked: Set<String>
    let busy: Bool
    let onCancel: () -> Void
    let onCommit: () -> Void

    /// 日を複数選べるのは「読んでる」「読了」だけ（読んだ日を作る状態）
    private var multi: Bool { status == .reading || status == .read }
    private var sorted: [String] { picked.sorted() }
    private var earliest: String? { sorted.first }
    private var latest: String? { sorted.last }
    /// 変わらない状態で、しかも日も残さないなら押しても何も起きない
    private var noop: Bool { !multi && status == book.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("「\(status.label)」で記録します").font(.subheadline.bold())
            Text(summary).font(.caption).foregroundStyle(.secondary)

            DayPicker(selection: $picked, multi: multi)

            if multi {
                Text("日をタップして足したり外したりできます（最後のひとつは外せません）。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if noop {
                Text("すでに「\(status.label)」です。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Button("やめる", action: onCancel).buttonStyle(.bordered).disabled(busy)
                Spacer()
                Button("記録する", action: onCommit)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || picked.isEmpty || noop)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5))
    }

    /// いま何が記録されるかを1行で（押す前に分かるように）
    private var summary: String {
        guard let earliest, let latest else { return "日付を選んでください" }
        switch status {
        case .reading:
            let head = "読み始め：\(JST.friendly(earliest))"
            return picked.count > 1 ? "\(head)・読んだ日 \(picked.count)日" : head
        case .read:
            let head = "読了：\(JST.friendly(latest))"
            return picked.count > 1 ? "\(head)・読み始め \(earliest)・読んだ日 \(picked.count)日" : head
        default:
            return "日付：\(JST.friendly(latest))"
        }
    }
}

/// 月のカレンダー。**選ぶだけ**で、サーバーには触らない（確定は「記録する」）。
/// `multi` が false のときは、タップした日ひとつに置き換わる。未来の日は押せない。
struct DayPicker: View {
    @Binding var selection: Set<String>
    let multi: Bool

    private static let weekdays = ["日", "月", "火", "水", "木", "金", "土"]
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

    @State private var month: String?

    private var today: String { JST.today() }
    /// 最初に開く月は「選ばれている日のうち、いちばん新しいものの月」
    private var shown: String { month ?? JST.month(of: selection.max() ?? today) }
    private var days: [String] { JST.days(inMonth: shown) }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Button { month = JST.addMonths(shown, -1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("前の月")
                Spacer()
                Text(title).font(.subheadline.bold())
                Spacer()
                Button { month = JST.addMonths(shown, 1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("次の月")
                    .disabled(shown >= JST.month(of: today))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            LazyVGrid(columns: Self.columns, spacing: 3) {
                ForEach(Self.weekdays, id: \.self) { w in
                    Text(w).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(0..<JST.weekday(of: days.first ?? today), id: \.self) { _ in
                    Color.clear.frame(height: 34)
                }
                ForEach(days, id: \.self) { day in cell(day) }
            }
        }
        .padding(10)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var title: String {
        let year = shown.prefix(4)
        let m = Int(shown.suffix(2)) ?? 0
        let count = days.filter { selection.contains($0) }.count
        return count > 0 ? "\(year)年\(m)月　\(count)日" : "\(year)年\(m)月"
    }

    private func cell(_ day: String) -> some View {
        let chosen = selection.contains(day)
        let future = day > today
        return Button { tap(day) } label: {
            Text(String(Int(day.suffix(2)) ?? 0))
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
        }
        .buttonStyle(.plain)
        .background(chosen ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if day == today { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5) }
        }
        .foregroundStyle(chosen ? Color.white : future ? Color.secondary.opacity(0.5) : Color.primary)
        .disabled(future)
        .accessibilityLabel("\(day)\(chosen ? "（選んでいます）" : "")")
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }

    private func tap(_ day: String) {
        guard day <= today else { return }
        if !multi {
            selection = [day]
            return
        }
        if selection.contains(day) {
            // ひとつも選んでいない状態は作らせない（記録できなくなるので）
            if selection.count > 1 { selection.remove(day) }
        } else {
            selection.insert(day)
        }
    }
}
