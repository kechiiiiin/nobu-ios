import SwiftUI

/// さがす（トップ）。2文字以上で自動検索、候補から1タップで登録。
///
/// ⚠️ **検索は Enter で走らせない**。日本語入力の変換確定の Enter を「送信」と取り違えないための
/// 決めごと（設計書 §9）。入力が変わるたびに `.task(id:)` が作り直され、前の待ち時間ごと
/// 取り消される＝そのまま 400ms のデバウンスになる。キーボードの改行キーは閉じるだけ。
struct SearchView: View {
    private static let quick: [Status] = [.want, .bought, .reading]

    @Environment(ToastCenter.self) private var toasts
    @Environment(AppModel.self) private var model

    @State private var query = ""
    @State private var candidates: [Candidate]?
    @State private var loading = false
    @State private var errorText: String?
    @State private var manualOpen = false
    @FocusState private var focused: Bool

    var body: some View {
        List {
            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red)
            }
            if let candidates {
                if candidates.isEmpty && !loading {
                    Text("見つかりませんでした。").foregroundStyle(.secondary)
                }
                ForEach(candidates) { candidate in
                    row(candidate)
                }
            } else {
                hint
            }
            Button("見つからない本を手で入れる") { manualOpen = true }
                .font(.footnote)
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top) { searchBar }
        .navigationTitle("さがす")
        .navigationBarTitleDisplayMode(.inline)
        .bookDestination()
        .sheet(isPresented: $manualOpen) {
            NavigationStack {
                ManualFormView(initialTitle: query.first?.isNumber == true ? "" : query)
            }
        }
        .task(id: query) { await search() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("書名か ISBN（2文字から）", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                // 検索は入力の変化で走る。改行キーはキーボードを閉じるだけ（変換確定と取り違えない）
                .onSubmit { focused = false }
            if loading {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("書名の一部を打つと、候補が出ます。「気になる／買った／読んでる」を押せば登録です。")
            Text("書店では「スキャン」からバーコードにかざすと「買った」で入ります。")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func row(_ candidate: Candidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CoverView(url: candidate.cover_url, title: candidate.title, size: .medium)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title).font(.subheadline).lineLimit(3)
                if !candidate.meta.isEmpty {
                    Text(candidate.meta).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let owned = candidate.owned {
                    NavigationLink(value: owned.id) {
                        Text("本棚にあります：\(owned.status.label) ›").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                } else {
                    HStack(spacing: 6) {
                        ForEach(Self.quick) { status in
                            Button(status.label) { Task { await add(candidate, status) } }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 中身

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else {
            loading = false
            if term.isEmpty { candidates = nil; errorText = nil }
            return
        }
        // 打っている間は走らせない（次の文字で task ごと取り消される）
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        loading = true
        defer { loading = false }
        do {
            candidates = try await NobuAPI.shared.search(term).candidates
            errorText = nil
        } catch is CancellationError {
            return
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func add(_ candidate: Candidate, _ status: Status) async {
        do {
            let result = try await NobuAPI.shared.addCandidate(candidate, status: status)
            if result.result == "already" {
                toasts.show(Toast(text: "もう本棚にあります（\(result.book.status.label)）",
                                  title: result.book.title, coverURL: result.book.cover_url))
            } else {
                toasts.show(Toast(
                    text: "「\(status.label)」に入れました",
                    title: result.book.title,
                    coverURL: result.book.cover_url,
                    undo: result.event_id.map { eventID in
                        {
                            do {
                                _ = try await NobuAPI.shared.undo(eventId: eventID)
                                mark(candidate, owned: nil)
                                model.shelfChanged()
                            } catch {
                                toasts.error(error)
                            }
                        }
                    }
                ))
            }
            mark(candidate, owned: Owned(id: result.book.id, status: result.book.status))
            model.shelfChanged()
        } catch {
            toasts.error(error)
        }
    }

    /// 同じ ISBN の候補にも「本棚にあります」を反映する（Web 版と同じ）
    private func mark(_ candidate: Candidate, owned: Owned?) {
        candidates = candidates?.map { current in
            guard current.id == candidate.id
                    || (current.isbn13 != nil && current.isbn13 == candidate.isbn13) else { return current }
            var copy = current
            copy.owned = owned
            return copy
        }
    }
}

/// 見つからない本を手で入れる
struct ManualFormView: View {
    let initialTitle: String

    @Environment(ToastCenter.self) private var toasts
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var form = ManualBook()
    @State private var status: Status = .want
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                LabeledContent("書名") { TextField("必須", text: $form.title) }
                LabeledContent("著者") { TextField("", text: $form.author) }
                LabeledContent("出版社") { TextField("", text: $form.publisher) }
                LabeledContent("発行") { TextField("例: 2024-05", text: $form.pubdate) }
                LabeledContent("ISBN") {
                    TextField("あれば", text: $form.isbn13).keyboardType(.numberPad)
                }
            }
            Section {
                // 登録のときに選べるのは4つ（「保留」は読み始めてから本のページで選ぶ。Web 版と同じ）
                Picker("状態", selection: $status) {
                    ForEach([Status.want, .bought, .reading, .read]) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("手で入れる")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if form.title.isEmpty { form.title = initialTitle } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("やめる") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("登録する") { Task { await save() } }
                    .disabled(busy || form.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await NobuAPI.shared.addManual(form, status: status)
            toasts.show(Toast(text: result.result == "already" ? "その ISBN はもう本棚にあります" : "登録しました",
                              title: result.book.title, coverURL: result.book.cover_url))
            model.shelfChanged()
            dismiss()
        } catch {
            toasts.error(error)
        }
    }
}
