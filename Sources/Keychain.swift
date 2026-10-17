import Foundation
import Security

/// 遠端辨識的 API key 只放 Keychain，不進 UserDefaults、不進記錄檔
enum Keychain {
    private static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// 沒有這個項目時 value 是 nil、status 是 errSecItemNotFound；其他非 errSecSuccess 代表讀取失敗（例如使用者拒絕存取）
    static func get(service: String, account: String) -> (value: String?, status: OSStatus) {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return (nil, status) }
        return (String(data: data, encoding: .utf8), status)
    }

    /// 空字串代表刪除；本來就沒有的項目刪除也算成功
    static func set(_ value: String, service: String, account: String) -> OSStatus {
        let q = query(service: service, account: account)
        guard !value.isEmpty else {
            let status = SecItemDelete(q as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = q
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil)
    }
}
