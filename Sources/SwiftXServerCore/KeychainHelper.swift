import Foundation
import Security

public enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

public enum KeychainHelper {
    public static let serviceName = "macxserver-launcher"

    /// Master switch. When true, every call is a no-op (store/delete do nothing,
    /// retrieve returns nil), so nothing ever touches the macOS Keychain.
    ///
    /// Disabled in Debug builds on purpose: the dev app is ad-hoc signed and its
    /// signature changes on every rebuild, so macOS treats each build as a new,
    /// unauthorized app and pops a Keychain access prompt for any stored item.
    /// That churn makes Keychain use impractical during development, so Debug
    /// skips it entirely (launchers just prompt for a password each time; the
    /// Helios secret dialog holds nothing). Release builds are stably Dev-ID
    /// signed, so the Keychain works normally and this is `false`.
    public static let enabled: Bool = {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }()

    public static func store(account: String, password: String) throws {
        guard enabled else { return }
        guard let data = password.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: account
            ]
            status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public static func retrieve(account: String) -> String? {
        guard enabled else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        guard enabled else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
