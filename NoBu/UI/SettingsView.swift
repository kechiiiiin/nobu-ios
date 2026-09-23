import SwiftUI

/// 設定。サービストークンが入っているかの確認と、接続テスト（`GET /api/me`）。
///
/// ⚠️ **シークレットの値は決して画面に出さない。** 出すのは「入っている／いない」と、
/// Client ID の先頭8文字だけ（`AccessTokenStore.hint`）。Client Secret は一切触れない。
struct SettingsView: View {
    private enum Result: Equatable {
        case none, testing
        case ok(String)
        case failed(String)
    }

    @State private var result: Result = .none
    @State private var stored = AccessTokenStore.isComplete
    @State private var hint = AccessTokenStore.hint
    @State private var counts: [String: Int] = [:]
    @State private var rakuten = false

    var body: some View {
        List {
            Section {
                LabeledContent("Client ID", value: hint ?? "（入っていません）")
                LabeledContent("Client Secret", value: AccessTokenStore.clientSecret.isStored ? "入っています" : "（入っていません）")
            } header: {
                Text("サービストークン")
            } footer: {
                Text("Cloudflare Access のサービストークン。値は Keychain にだけ置き、画面には出しません。入れ直すときは Mac で `make import-access`（次の起動で取り込みます）。")
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("いまの接続を確かめる")
                        if result == .testing {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(!stored || result == .testing)

                switch result {
                case .ok(let email):
                    LabeledContent("つながりました", value: email)
                    LabeledContent("楽天の書誌", value: rakuten ? "使える" : "キー未設定")
                    ForEach(Status.allCases) { status in
                        LabeledContent(status.label, value: "\(counts[status.rawValue] ?? 0)冊")
                    }
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                default:
                    EmptyView()
                }
            } header: {
                Text("接続テスト")
            } footer: {
                Text("つなぎ先: \(NobuAPI.baseURL.absoluteString)")
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Mac から流し込んだ直後は、起動し直すと入る
            stored = AccessTokenStore.isComplete
            hint = AccessTokenStore.hint
        }
    }

    private func test() async {
        result = .testing
        do {
            let me = try await NobuAPI.shared.me()
            counts = me.counts
            rakuten = me.rakuten
            result = .ok(me.email)
        } catch {
            result = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
