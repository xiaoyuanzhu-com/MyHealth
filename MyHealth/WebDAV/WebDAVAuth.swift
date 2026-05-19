import Foundation
import Security

/// User-supplied WebDAV connection. `base_url` is the server's WebDAV root
/// (e.g. `https://example.com/remote.php/dav/files/alice`). `root_folder` is
/// the subfolder we'll create and write into (defaults to "MyHealth").
struct WebDAVCredentials: Codable, Equatable {
    var base_url: String
    var username: String
    var password: String
    var root_folder: String

    var displayHost: String {
        URL(string: base_url)?.host ?? base_url
    }
}

/// Keychain-backed storage for WebDAV credentials. Mirrors `TokenStore` —
/// delete-then-add to avoid `SecItemUpdate` accessibility edge cases.
enum WebDAVStore {
    static let service = "org.foss.myhealth.ios"
    static let account = "webdav-credentials"

    static func save(_ creds: WebDAVCredentials) throws {
        let data = try JSONEncoder().encode(creds)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { throw WebDAVStoreError.keychain(status) }
    }

    static func load() -> WebDAVCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess { return nil }
        guard let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(WebDAVCredentials.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum WebDAVStoreError: Error {
    case keychain(OSStatus)
}
