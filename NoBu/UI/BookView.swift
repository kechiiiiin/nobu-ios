import SwiftUI

/// 本のページ。状態の4択ワンタップ・ひとこと・読書の回。
struct BookView: View {
    let id: Int

    @Environment(ToastCenter.self) private var toasts
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var detail: BookDetail?
    @State private var errorText: String?
    @State private var noteOpen = false
    @State private var nudge: DateNudge?
    @State private var editingBook = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let errorText {
                Text(errorText).foregroundStyle(.red).padding()
            } else if let detail {
                content(detail)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .navigationTitle(detail?.book.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $editingBook) {
            if let book = detail?.book {
                NavigationStack {
                    EditBookView(book: book) { updated in
                        detail?.book = updated
                    }
                }
            }
        }
    }

    private func content(_ detail: BookDetail) -> some View {
        let book = detail.book
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(book)
                statusPicker(book)
                if let nudge {
                    DateNudgeView(nudge: nudge, onDone: { self.nudge = nil }, onChanged: { await load() })
                } else {
                    Text("\(book.status.label)：\(JST.jstDate(book.status_at))")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                ReadingDaysSection(book: book, days: detail.days ?? [], sessions: detail.sessions, onChanged: { await load() })

                SessionsSection(book: book, sessions: detail.sessions, onChanged: { await load() })

                notes(detail)

                DisclosureGroup("書誌を直す・その他") { more(detail) }
                    .font(.subheadline)
            }
            .padding()
        }
    }

    // MARK: - 部品

    private func header(_ book: Book) -> some View {
        HStack(alignment: .top, spacing: 14) {
            CoverView(url: book.cover_url, title: book.title, size: .large)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.title3).bold()
                if let author = book.author, !author.isEmpty { Text(author).font(.subheadline) }
                if !book.meta.isEmpty { Text(book.meta).font(.caption).foregroundStyle(.secondary) }
                if let isbn = book.isbn13 { Text("ISBN \(isbn)").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
    }

    private func statusPicker(_ book: Book) -> some View {
        HStack(spacing: 4) {
            ForEach(Status.allCases) { status in
                Button { Task { await setStatus(status) } } label: {
                    // 5つ並ぶ（気になる／買った／読んでる／保留／読了）ので、狭い画面では縮める
                    Text(status.label)
                        .font(.footnote)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .background(book.status == status ? Color.accentColor : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(book.status == status ? Color.white : Color.primary)
                .accessibilityAddTraits(book.status == status ? [.isSelected] : [])
            }
        }
    }

    @ViewBuilder
    private func notes(_ detail: BookDetail) -> some View {
        if noteOpen || detail.book.status == .read {
            NoteComposer(bookId: detail.book.id, autoFocus: noteOpen) { note in
                self.detail?.notes.insert(note, at: 0)
                noteOpen = false
            }
        } else {
            Button("ひとことを書く") { noteOpen = true }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        ForEach(detail.notes) { note in
            NoteRow(note: note) { updated in
                if let index = self.detail?.notes.firstIndex(where: { $0.id == updated.id }) {
                    self.detail?.notes[index] = updated
                }
            } onDelete: {
                self.detail?.notes.removeAll { $0.id == note.id }
            }
        }
    }

    @ViewBuilder
    private func more(_ detail: BookDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("書誌を直す") { editingBook = true }
                    .buttonStyle(.bordered)
                if detail.book.isbn13 != nil {
                    Button("書誌を取り直す") { Task { await refetch() } }
                        .buttonStyle(.bordered)
                }
            }
            Button("本棚から消す", role: .destructive) { confirmDelete = true }
                .buttonStyle(.bordered)
                .confirmationDialog("「\(detail.book.title)」を本棚から消します。ひとことも消えます。",
                                    isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("消す", role: .destructive) { Task { await remove() } }
                }
            if !detail.events.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(detail.events) { event in
                        Text(eventText(event)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventText(_ event: BookEvent) -> String {
        let head = event.from_status.map { "\($0.label) → " } ?? "登録："
        return "\(JST.jstDate(event.at)) \(head)\(event.to_status.label)\(event.via == "scan" ? "（スキャン）" : "")"
    }

    // MARK: - 中身

    private func load() async {
        do {
            detail = try await NobuAPI.shared.book(id)
            errorText = nil
        } catch is CancellationError {
            return
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func setStatus(_ status: Status) async {
        guard let book = detail?.book else { return }
        guard status != book.status else {
            if status == .read { noteOpen = true }
            return
        }
        nudge = nil
        do {
            // 日付は今日で記録する（1タップで済む）。違えば直後に出る「昨日／日付を選ぶ」で直す
            let result = try await NobuAPI.shared.patch(book.id, ["status": .string(status.rawValue)])
            await load()
            model.shelfChanged()
            if status == .read { noteOpen = true }
            guard let eventID = result.event_id else { return }
            let session = result.session
            let started = session?.created_event_id == eventID && status == .reading
            let finished = session?.finished_event_id == eventID && status == .read
            if let session, started || finished {
                nudge = DateNudge(kind: started ? .start : .finish, session: session, eventID: eventID)
            } else {
                toasts.show(Toast(text: "「\(status.label)」にしました", undo: {
                    do {
                        _ = try await NobuAPI.shared.undo(eventId: eventID)
                        await load()
                        model.shelfChanged()
                    } catch {
                        toasts.error(error)
                    }
                }))
            }
        } catch {
            toasts.error(error)
        }
    }

    private func refetch() async {
        do {
            detail?.book = try await NobuAPI.shared.refetch(id).book
            toasts.show("書誌を取り直しました")
        } catch {
            toasts.error(error)
        }
    }

    private func remove() async {
        do {
            try await NobuAPI.shared.remove(id)
            model.shelfChanged()
            toasts.show("消しました")
            dismiss()
        } catch {
            toasts.error(error)
        }
    }
}

// MARK: - ひとこと

/// ひとことを書く欄。**Enter は改行のまま**（保存はボタン）。
/// 日本語入力の変換確定を「保存」と取り違えないための決めごと（設計書 §9）。
private struct NoteComposer: View {
    let bookId: Int
    let autoFocus: Bool
    let onSaved: (BookNote) -> Void

    @Environment(ToastCenter.self) private var toasts
    @State private var text = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .frame(minHeight: 84)
                .focused($focused)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("ひとこと（Enter は改行。保存はボタンで）")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text("非公開で保存します").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { if autoFocus { focused = true } }
    }

    private func save() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let note = try await NobuAPI.shared.addNote(bookId: bookId, body: body)
            text = ""
            focused = false
            onSaved(note)
        } catch {
            toasts.error(error)
        }
    }
}

private struct NoteRow: View {
    let note: BookNote
    let onChange: (BookNote) -> Void
    let onDelete: () -> Void

    @Environment(ToastCenter.self) private var toasts
    @State private var editing = false
    @State private var text = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                TextEditor(text: $text).frame(minHeight: 84)
                HStack {
                    Spacer()
                    Button("やめる") { editing = false }.buttonStyle(.bordered)
                    Button("保存") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(note.body).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    Text(JST.jstDate(note.created_at))
                    Button(note.is_public == 1 ? "公開" : "非公開") { Task { await togglePublic() } }
                    Button("直す") { text = note.body; editing = true }
                    Button("消す") { confirmDelete = true }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .confirmationDialog("このひとことを消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive) { Task { await remove() } }
        }
    }

    private func save() async {
        do {
            onChange(try await NobuAPI.shared.editNote(note.id, ["body": .string(text)]))
            editing = false
        } catch {
            toasts.error(error)
        }
    }

    private func togglePublic() async {
        do {
            onChange(try await NobuAPI.shared.editNote(note.id, ["is_public": .bool(note.is_public != 1)]))
        } catch {
            toasts.error(error)
        }
    }

    private func remove() async {
        do {
            try await NobuAPI.shared.deleteNote(note.id)
            onDelete()
        } catch {
            toasts.error(error)
        }
    }
}

// MARK: - 書誌の手直し

/// 書誌を直す。**Enter で送らない**（保存はツールバーのボタンだけ）
private struct EditBookView: View {
    let book: Book
    let onSaved: (Book) -> Void

    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var publisher = ""
    @State private var pubdate = ""
    @State private var isbn13 = ""
    @State private var coverURL = ""
    @State private var busy = false

    var body: some View {
        Form {
            LabeledContent("書名") { TextField("", text: $title) }
            LabeledContent("著者") { TextField("", text: $author) }
            LabeledContent("出版社") { TextField("", text: $publisher) }
            LabeledContent("発行") { TextField("", text: $pubdate) }
            LabeledContent("ISBN") { TextField("", text: $isbn13).keyboardType(.numberPad) }
            Section {
                TextField("書影の URL（楽天・版元ドットコムの画像だけ）", text: $coverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .navigationTitle("書誌を直す")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            title = book.title
            author = book.author ?? ""
            publisher = book.publisher ?? ""
            pubdate = book.pubdate ?? ""
            isbn13 = book.isbn13 ?? ""
            coverURL = book.cover_url ?? ""
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let body: [String: JSONValue] = [
                "title": .string(title),
                "author": .string(author),
                "publisher": .string(publisher),
                "pubdate": .string(pubdate),
                "isbn13": .string(isbn13),
                "cover_url": .string(coverURL),
            ]
            onSaved(try await NobuAPI.shared.patch(book.id, body).book)
            toasts.show("直しました")
            dismiss()
        } catch {
            toasts.error(error)
        }
    }
}
