import Foundation
import Security

/// Keychain-backed storage for MyLifeDB Connect tokens.
///
/// Refresh tokens are single-use and rotated on every refresh — we MUST persist
/// the new refresh token before discarding the previous access token. Replaying
/// an already-rotated token causes the entire token chain to be revoked.
///
/// We store the entire `MyLifeDBSession` blob as a JSON-encoded item so the
/// access token, refresh token, scope, base URL and timestamps round-trip
/// atomically.
struct MyLifeDBSession: Codable {
    var base_url: String           // e.g. "https://my.xiaoyuanzhu.com"
    var client_id: String          // "com.xiaoyuanzhu.MyHealth"
    var redirect_uri: String       // "com.xiaoyuanzhu.MyHealth://oauth/callback"
    var remote_path: String        // "/apps/apple-health"
    var scope: String              // granted scope echoed by /token

    var access_token: String
    var refresh_token: String
    var token_type: String         // always "Bearer"
    var expires_in: Int            // seconds, from /token response
    var refresh_expires_in: Int    // seconds, from /token response
    var saved_at: Int              // unix seconds when this snapshot was saved

    var accessExpiry: Date { Date(timeIntervalSince1970: TimeInterval(saved_at + expires_in)) }
    var refreshExpiry: Date { Date(timeIntervalSince1970: TimeInterval(saved_at + refresh_expires_in)) }
}

enum TokenStoreError: Error {
    case keychain(OSStatus)
    case decode
}

struct TokenStore {
    static let service = "com.xiaoyuanzhu.MyHealth"
    static let account = "mylifedb-session"

    static func save(_ session: MyLifeDBSession) throws {
        let data = try JSONEncoder().encode(session)
        // Delete-then-add to avoid SecItemUpdate edge cases when attributes
        // (especially accessibility) change.
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
        if status != errSecSuccess { throw TokenStoreError.keychain(status) }
    }

    static func load() throws -> MyLifeDBSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { throw TokenStoreError.keychain(status) }
        guard let data = item as? Data else { throw TokenStoreError.decode }
        return try JSONDecoder().decode(MyLifeDBSession.self, from: data)
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
