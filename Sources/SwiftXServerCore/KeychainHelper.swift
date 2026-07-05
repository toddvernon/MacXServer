import Foundation
import Security

public enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
}

public enum KeychainHelper {
    public static let serviceName = "macxserver-launcher"

    /// Master switch. When true, secrets live in the macOS Keychain. When false
    /// (Debug), they live in a 0600 plaintext dev file instead (see below).
    ///
    /// Disabled in Debug builds on purpose: the dev app is ad-hoc signed and its
    /// signature changes on every rebuild, so macOS treats each build as a new,
    /// unauthorized app and pops a Keychain access prompt for any stored item.
    /// That churn makes the real Keychain impractical during development. Release
    /// builds are stably Dev-ID signed, so the Keychain works normally.
    public static let enabled: Bool = {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }()

    /// Debug-only fallback store: a 0600 plaintext JSON file so secrets persist
    /// across the ad-hoc rebuild churn (the Keychain would prompt every launch).
    /// NEVER used in Release (Keychain is enabled there). Plaintext is acceptable
    /// only because it's the developer's own machine and dev-scoped.
    private static let fallbackPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(".macxserver-dev-secrets.json")

    private static func fallbackLoad() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackPath)),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func fallbackSave(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: URL(fileURLWithPath: fallbackPath), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fallbackPath)
    }

    public static func store(account: String, password: String) throws {
        guard enabled else {
            var dict = fallbackLoad(); dict[account] = password; fallbackSave(dict); return
        }
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
        guard enabled else { return fallbackLoad()[account] }
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
        guard enabled else {
            var dict = fallbackLoad(); dict[account] = nil; fallbackSave(dict); return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
