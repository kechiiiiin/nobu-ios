import SwiftUI

// MARK: - 「読んでる」「読了」を押した直後の日付の付け替え

/// 既定は今日で記録済み。直後に「昨日にする／日付を選ぶ／取り消す」を8秒だけ出す（Web 版の DateNudge と同じ）。
struct DateNudge: Identifiable, Equatable {
    enum Kind { case start, finish }
    let id = UUID()
    let kind: Kind
    let session: ReadingSession
    let eventID: Int
}

struct DateNudgeView: View {
    let nudge: DateNudge
    let onDone: () -> Void
    let onChanged: () async -> Void

    @Environment(ToastCenter.self) private var toasts
    @State private var day = ""
    @State private var picking = false
    @State private var busy = false

    private var isStart: Bool { nudge.kind == .start }
    private var field: String { isStart ? "started_on" : "finished_on" }
    private var label: String { isStart ? "読み始め" : "読了" }
    private var today: String { JST.today() }
    private var yesterday: String { JST.addDays(today, -1) }

    /// 読了日を昨日にできるのは、読み始めた日より後のときだけ
    private var canUseYesterday: Bool {
        guard day != yesterday else { return false }
        if !isStart, let started = nudge.session.started_on, yesterday < started { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(label)：\(JST.friendly(day))で記録しました").font(.footnote)
            HStack(spacing: 8) {
                if canUseYesterday {
                    Button("昨日にする") { Task { await change(to: yesterday) } }
                        .buttonStyle(.bordered).disabled(busy)
                }
                if picking {
                    DatePicker("", selection: dateBinding, in: range, displayedComponents: .date)
                        .labelsHidden()
                        .disabled(busy)
                } else {
                    Button("日付を選ぶ") { picking = true }
                        .buttonStyle(.bordered).disabled(busy)
                }
                Button("取り消す") { Task { await undo() } }
                    .buttonStyle(.bordered).disabled(busy)
                Spacer(minLength: 0)
                Button("閉じる", action: onDone).font(.caption)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { if day.isEmpty { day = (isStart ? nudge.session.started_on : nudge.session.finished_on) ?? today } }
        // 触らなければ8秒で消える（日付を選んでいる間は消さない）
        .task(id: "\(picking)-\(busy)-\(day)") {
            guard !picking, !busy else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            onDone()
        }
    }

    private var range: ClosedRange<Date> {
        let upper = JST.date(from: today) ?? Date()
        let lowerDay = isStart ? nil : nudge.session.started_on
        let lower = lowerDay.flatMap(JST.date(from:)) ?? JST.date(from: "1900-01-01") ?? upper
        return min(lower, upper)...upper
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { JST.date(from: day) ?? Date() },
            set: { newValue in Task { await change(to: JST.day(from: newValue)) } }
        )
    }

    private func change(to newDay: String) async {
        guard !newDay.isEmpty, newDay != day, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await NobuAPI.shared.editSession(nudge.session.id, [field: .string(newDay)])
            day = newDay
            picking = false
            await onChanged()
        } catch {
            toasts.error(error)
        }
    }

    private func undo() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await NobuAPI.shared.undo(eventId: nudge.eventID)
            onDone()
            await onChanged()
            toasts.show("取り消しました")
        } catch {
            toasts.error(error)
        }
    }
}

// MARK: - 読書の回

struct SessionsSection: View {
    let book: Book
    let sessions: [ReadingSession]
    let onChanged: () async -> Void

    @State private var editing: SessionTarget?

    /// いま開いている（読み終えていない）一番新しい回
    private var latestOpen: Int? {
        sessions.filter { $0.finished_on == nil }.map(\.id).max()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("読書の記録").font(.headline)
            if sessions.isEmpty {
                Text("「読んでる」「読了」を押すと、ここに日付が残ります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                let text = sessionText(session, bookStatus: book.status, isLatestOpen: session.id == latestOpen)
                HStack(spacing: 6) {
                    Text(text.range).font(.subheadline)
                    if !text.note.isEmpty {
                        Text("（\(text.note)）").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("直す") { editing = .existing(session) }.font(.caption)
                }
            }
            Button("前に読んだ記録を足す") { editing = .new }.font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editing) { target in
            NavigationStack {
                SessionEditorView(
                    bookId: book.id,
                    session: target.session,
                    // いま読んでいる回は読了日を触らせない（閉じるのは「読了」ボタン）
                    current: book.status == .reading && target.session?.id == latestOpen,
                    onChanged: onChanged
                )
            }
        }
    }

    enum SessionTarget: Identifiable {
        case new
        case existing(ReadingSession)

        var id: Int { session?.id ?? 0 }
        var session: ReadingSession? {
            if case .existing(let s) = self { return s }
            return nil
        }
    }
}

/// 回の手直し・追加。本の状態と食い違わないよう（サーバーも同じ検査をする）:
///   - いま読んでいる回は読了日欄を出さない・消せない
///   - 読み終えた回・新しく足す回は読了日が要る
struct SessionEditorView: View {
    let bookId: Int
    let session: ReadingSession?
    let current: Bool
    let onChanged: () async -> Void

    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var hasStarted = false
    @State private var started = Date()
    @State private var hasFinished = false
    @State private var finished = Date()
    @State private var busy = false
    @State private var confirmDelete = false

    private var today: Date { JST.date(from: JST.today()) ?? Date() }
    /// 読み終えた回・新しく足す回は読了日が必須
    private var needFinish: Bool { !current && (session == nil || session?.finished_on != nil) }
    private var canSave: Bool {
        if busy { return false }
        if needFinish && !hasFinished { return false }
        return hasStarted || hasFinished
    }

    var body: some View {
        Form {
            Section {
                Toggle("読み始めた日を入れる", isOn: $hasStarted)
                if hasStarted {
                    DatePicker("読み始めた日", selection: $started,
                               in: ...(hasFinished ? finished : today), displayedComponents: .date)
                }
            } footer: {
                Text("入れなければ「読み始め不明」で残ります。")
            }
            if current {
                Section { Text("読み終えたら「読了」ボタンで閉じます。").font(.footnote).foregroundStyle(.secondary) }
            } else {
                Section {
                    Toggle(needFinish ? "読了日" : "読了日を入れる（空＝中断中のまま）", isOn: $hasFinished)
                        .disabled(needFinish && hasFinished)
                    if hasFinished {
                        DatePicker("読了日", selection: $finished,
                                   in: (hasStarted ? started : Date.distantPast)...today, displayedComponents: .date)
                    }
                }
            }
            if let session, !current {
                Section {
                    Button("この回の記録を消す", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("この回の記録を消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("消す", role: .destructive) { Task { await remove(session.id) } }
                        }
                }
            }
        }
        .navigationTitle(session == nil ? "前に読んだ記録" : "読書の回を直す")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: fill)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }.disabled(!canSave)
            }
        }
    }

    private func fill() {
        if let day = session?.started_on, let date = JST.date(from: day) {
            hasStarted = true
            started = date
        }
        if let day = session?.finished_on, let date = JST.date(from: day) {
            hasFinished = true
            finished = date
        }
        if needFinish && session == nil { hasFinished = true }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let startedOn = hasStarted ? JST.day(from: started) : nil
        let finishedOn = hasFinished ? JST.day(from: finished) : nil
        do {
            if let session {
                // いま読んでいる回は読了日を送らない（サーバーも close_with_button で拒む）
                var body: [String: JSONValue] = ["started_on": .string(startedOn)]
                if !current { body["finished_on"] = .string(finishedOn) }
                _ = try await NobuAPI.shared.editSession(session.id, body)
            } else {
                _ = try await NobuAPI.shared.addSession(bookId: bookId, started: startedOn, finished: finishedOn)
            }
            await onChanged()
            dismiss()
        } catch {
            toasts.error(error)
        }
    }

    private func remove(_ id: Int) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await NobuAPI.shared.deleteSession(id)
            await onChanged()
            dismiss()
        } catch {
            toasts.error(error)
        }
    }
}
