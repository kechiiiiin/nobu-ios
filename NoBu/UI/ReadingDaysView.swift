import SwiftUI

/// 読んだ日。「今日読んだ」ボタン1つと、月のカレンダー（Web 版の ReadingDays と同じ）。
/// 読んだ日は塗り、読書の回（読み始め〜読了。読書中なら今日まで）は薄い下地で示す。
/// 日をタップすると足したり消したりできる。未来の日は押せない。
struct ReadingDaysSection: View {
    let book: Book
    let days: [ReadingDay]
    let sessions: [ReadingSession]
    let onChanged: () async -> Void

    private static let weekdays = ["日", "月", "火", "水", "木", "金", "土"]
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

    @Environment(ToastCenter.self) private var toasts
    @State private var month = JST.month(of: JST.today())
    @State private var busy = false

    private var today: String { JST.today() }
    private var marked: Set<String> { Set(days.map(\.on)) }
    private var readToday: Bool { marked.contains(today) }
    private var monthDays: [String] { JST.days(inMonth: month) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("読んだ日").font(.headline)
            HStack(spacing: 10) {
                Button { Task { await toggle(today) } } label: {
                    Text(readToday ? "今日読んだ ✓" : "今日読んだ")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14).padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .background(readToday ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(readToday ? Color.white : Color.accentColor)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: readToday ? 0 : 1.5))
                .disabled(busy)
                .accessibilityAddTraits(readToday ? [.isSelected] : [])
                Text(readToday ? "もう一度押すと取り消します" : "押すと今日が記録されます")
                    .font(.caption).foregroundStyle(.secondary)
            }
            calendar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var calendar: some View {
        VStack(spacing: 4) {
            HStack {
                Button { month = JST.addMonths(month, -1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("前の月")
                Spacer()
                Text(title).font(.subheadline.bold())
                Spacer()
                Button { month = JST.addMonths(month, 1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("次の月")
                    .disabled(month >= JST.month(of: today))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            LazyVGrid(columns: Self.columns, spacing: 3) {
                ForEach(Self.weekdays, id: \.self) { w in
                    Text(w).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(0..<JST.weekday(of: monthDays.first ?? today), id: \.self) { _ in
                    Color.clear.frame(height: 34)
                }
                ForEach(monthDays, id: \.self) { day in cell(day) }
            }
            Text("日をタップすると、読んだ日を足したり消したりできます（薄い色は読書の回の期間）。")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var title: String {
        let year = month.prefix(4)
        let m = Int(month.suffix(2)) ?? 0
        let count = monthDays.filter { marked.contains($0) }.count
        // 数は「その月に読んだ日の数」。0 のときは出さない（「0日」が日付に見えるため）
        return count > 0 ? "\(year)年\(m)月　読んだ日 \(count)日" : "\(year)年\(m)月"
    }

    private func cell(_ day: String) -> some View {
        let isRead = marked.contains(day)
        let future = day > today
        return Button { Task { await toggle(day) } } label: {
            Text(String(Int(day.suffix(2)) ?? 0))
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
        }
        .buttonStyle(.plain)
        .background(background(day, isRead: isRead), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if day == today { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5) }
        }
        .foregroundStyle(isRead ? Color.white : future ? Color.secondary.opacity(0.5) : Color.primary)
        .disabled(busy || future)
        .accessibilityLabel("\(day)\(isRead ? "（読んだ日）" : "")")
        .accessibilityAddTraits(isRead ? [.isSelected] : [])
    }

    private func background(_ day: String, isRead: Bool) -> Color {
        if isRead { return .accentColor }
        return inSession(day) ? Color.accentColor.opacity(0.18) : .clear
    }

    /// その日が読書の回（読み始め〜読了。読書中なら今日まで）の中か
    private func inSession(_ day: String) -> Bool {
        sessions.contains { session in
            guard let from = session.started_on ?? session.finished_on else { return false }
            let to = session.finished_on ?? today
            return day >= from && day <= to
        }
    }

    private func toggle(_ day: String) async {
        guard !busy, day <= today else { return }
        busy = true
        defer { busy = false }
        do {
            if marked.contains(day) { try await NobuAPI.shared.unmarkDay(bookId: book.id, on: day) }
            else { _ = try await NobuAPI.shared.markDay(bookId: book.id, on: day) }
            await onChanged()
        } catch {
            toasts.error(error)
        }
    }
}
