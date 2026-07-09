import Foundation
import Security

/// Stores saved-server passwords in the login Keychain (keyed by the connection's
/// id), so a remembered connection doesn't prompt on every connect. A non-sandboxed
/// app reaches the login keychain without special entitlements.
enum KeychainStore {
    private static let service = "com.scarcrux.pathem.remote"

    private static func base(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    static func password(for id: UUID) -> String? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(for id: UUID) -> Bool { password(for: id) != nil }

    static func setPassword(_ password: String, for id: UUID) {
        SecItemDelete(base(id) as CFDictionary)  // replace any existing
        var add = base(id)
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }

    static func removePassword(for id: UUID) {
        SecItemDelete(base(id) as CFDictionary)
    }

    /// Delete every Pathem-stored password (used by "Reset Pathem Data" for a clean uninstall).
    static func removeAll() {
        SecItemDelete(
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
                as CFDictionary)
    }
}
