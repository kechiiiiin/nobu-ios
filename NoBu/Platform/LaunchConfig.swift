import Foundation

/// Mac からサービストークンを流し込む入口（iPhone で長い文字列を打たずに済ませる）。
///
/// ⚠️ **シークレットはソースに一切含まれない。** 値は外から渡す。経路は2つ:
///
/// 1. **ファイルの取り込み（推奨）** — Mac から `devicectl device copy to` でアプリのコンテナの
///    `tmp/` に置くと、**次にアプリが起動したとき** Keychain へ移して**ファイルは即削除**する。
///    起動引数と違ってプロセス一覧に値が載らない。`make import-access` がこの形。
///
///        tmp/nobu-import-access-client-id      → Keychain `cf-access-client-id`
///        tmp/nobu-import-access-client-secret  → Keychain `cf-access-client-secret`
///
/// 2. **起動引数**（端末が手元にあるときのテスト用）。⚠️ アプリへの引数の前に `--` が必須:
///
///        xcrun devicectl device process launch --device <UUID> --terminate-existing \
///          jp.kechiiiiin.nobu -- -nobuAccessId <id> -nobuAccessSecret <secret>
///
/// どちらも値は **Keychain へ移す**（UserDefaults には残さない）。
enum LaunchConfig {

    static let importFilePrefix = "nobu-import-"

    @discardableResult
    static func applyIfPresent() -> [String] {
        var applied = importCredentialFiles()
        let arguments = ProcessInfo.processInfo.arguments

        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.index(after: index) < arguments.endIndex else { return nil }
            let candidate = arguments[arguments.index(after: index)]
            return candidate.hasPrefix("-") ? nil : candidate
        }

        if let id = value(after: "-nobuAccessId"), !id.isEmpty {
            try? AccessTokenStore.clientID.save(id)
            applied.append("accessId→Keychain")
        }
        if let secret = value(after: "-nobuAccessSecret"), !secret.isEmpty {
            try? AccessTokenStore.clientSecret.save(secret)
            applied.append("accessSecret→Keychain")
        }
        return applied
    }

    /// `tmp/nobu-import-*` に置かれたファイルを Keychain へ移し、**成否にかかわらず消す**
    /// （秘密をファイルのまま残さない。失敗したら Mac からもう一度置けばよい）
    private static func importCredentialFiles() -> [String] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        var applied: [String] = []
        let items: [(file: String, secret: KeychainSecret, label: String)] = [
            ("access-client-id", AccessTokenStore.clientID, "accessId(file)→Keychain"),
            ("access-client-secret", AccessTokenStore.clientSecret, "accessSecret(file)→Keychain")
        ]
        for item in items {
            let url = tmp.appendingPathComponent(importFilePrefix + item.file)
            guard fm.fileExists(atPath: url.path) else { continue }
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url) else { continue }
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, (try? item.secret.save(value)) != nil {
                applied.append(item.label)
            }
        }
        return applied
    }
}
