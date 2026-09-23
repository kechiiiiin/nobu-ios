import Foundation
import Security

/// Keychain の汎用パスワード1項目。**ソースにハードコードしない**（health-sync と同じ作り）。
///
/// アクセシビリティは `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
/// - `WhenUnlocked` 系は将来バックグラウンドから読めない
/// - `ThisDeviceOnly` でバックアップに乗らない
struct KeychainSecret {
    private static let service = "jp.kechiiiiin.nobu"
    let account: String

    func save(_ value: String) throws {
        // ⚠️ 削除クエリは class / service / account だけに絞る（kSecValueData 等を混ぜると errSecParam になる報告がある）
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !value.isEmpty else { return }   // 空文字は「削除」として扱う

        var addQuery = deleteQuery
        addQuery[kSecValueData as String] = Data(value.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain への保存に失敗 (status=\(status))"])
        }
    }

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var isStored: Bool { !(load() ?? "").isEmpty }
}

/// Cloudflare Access のサービストークン（`CF-Access-Client-Id` / `CF-Access-Client-Secret`）。
/// **2項目とも Keychain**（UserDefaults にもファイルにも残さない）。
enum AccessTokenStore {
    static let clientID = KeychainSecret(account: "cf-access-client-id")
    static let clientSecret = KeychainSecret(account: "cf-access-client-secret")

    static var isComplete: Bool { clientID.isStored && clientSecret.isStored }

    /// 画面に出してよい程度の手がかり（Client ID の先頭だけ。シークレットは決して出さない）
    static var hint: String? {
        guard let id = clientID.load(), !id.isEmpty else { return nil }
        return String(id.prefix(8)) + "…"
    }
}
