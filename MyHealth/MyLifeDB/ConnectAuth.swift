import Foundation
#if os(iOS)
import UIKit
#endif

/// MyLifeDB Connect (OAuth 2.1 + PKCE) client.
///
/// Spec: https://my.xiaoyuanzhu.com/docs/internal/api/connect/
/// - Authorization Code grant + mandatory PKCE (S256)
/// - Custom URL scheme redirect for native apps
/// - Refresh tokens are single-use and rotated; replaying a rotated token
///   revokes the entire chain (we persist new tokens BEFORE discarding old).
///
/// Transport: the authorize URL is opened with `UIApplication.open(_:)` so
/// iOS Universal Links can hand off to the MyLifeDB app when installed (an
/// in-process `ASWebAuthenticationSession` would bypass that). The callback
/// arrives on our registered custom URL scheme and is routed back here via
/// `handleCallback(_:)` from the SwiftUI `.onOpenURL` handler at the app root.
@MainActor
final class ConnectAuth: NSObject {
    nonisolated static let clientID = "org.foss.myhealth.ios"
    nonisolated static let appName = "MyHealth"
    nonisolated static let redirectScheme = "org.foss.myhealth.ios"
    nonisolated static let redirectURI = "org.foss.myhealth.ios://oauth/callback"
    nonisolated static let defaultRemotePath = "/apps/myhealth/apple-health"

    /// How long we wait for the user to complete the external auth flow
    /// before giving up. The user has likely abandoned by then.
    private static let externalAuthTimeout: Duration = .seconds(300)

    /// Singleton — the `.onOpenURL` handler at the app root needs a stable
    /// target to forward callbacks to, since the URL arrives out-of-band
    /// from whichever view started the flow.
    static let shared = ConnectAuth()

    private var pendingContinuation: CheckedContinuation<URL, Error>?

    enum AuthError: Error, LocalizedError {
        case discoveryFailed
        case stateMismatch
        case userCancelled
        case authServerError(String)
        case tokenExchange(String)
        case noCode

        var errorDescription: String? {
            switch self {
            case .discoveryFailed: return "Could not load the MyLifeDB OAuth metadata."
            case .stateMismatch: return "OAuth state mismatch — the response didn't match this request."
            case .userCancelled: return "Authorization was cancelled."
            case .authServerError(let s): return "MyLifeDB rejected the request: \(s)"
            case .tokenExchange(let s): return "Token exchange failed: \(s)"
            case .noCode: return "No authorization code was returned."
            }
        }
    }

    /// Called by the SwiftUI `.onOpenURL` handler at the app root. Returns
    /// `true` if the URL belonged to an in-flight OAuth flow and was
    /// consumed; `false` otherwise (so other handlers can try it).
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.redirectScheme.lowercased(),
              url.host?.lowercased() == "oauth",
              url.path == "/callback" else {
            return false
        }
        guard let cont = pendingContinuation else { return false }
        pendingContinuation = nil
        cont.resume(returning: url)
        return true
    }

    /// Discovery + browser sign-in + token exchange. On success, persists a
    /// session in Keychain via `TokenStore` and returns it.
    func signIn(
        baseURL: URL,
        remotePath: String = ConnectAuth.defaultRemotePath
    ) async throws -> MyLifeDBSession {
        let metadata = try await discover(baseURL: baseURL)
        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.generateState()
        let scope = "files.write:\(remotePath)"

        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "app_name", value: Self.appName),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizeURL = components.url else { throw AuthError.discoveryFailed }

        let callbackURL = try await runExternalAuth(authorizeURL: authorizeURL)
        let (code, returnedState, error) = parseCallback(callbackURL)
        if let error { throw AuthError.authServerError(error) }
        guard returnedState == state else { throw AuthError.stateMismatch }
        guard let code else { throw AuthError.noCode }

        let token = try await exchange(
            tokenEndpoint: metadata.tokenEndpoint,
            code: code,
            verifier: verifier
        )

        let now = Int(Date().timeIntervalSince1970)
        let session = MyLifeDBSession(
            base_url: baseURL.absoluteString,
            client_id: Self.clientID,
            redirect_uri: Self.redirectURI,
            remote_path: remotePath,
            scope: token.scope ?? scope,
            access_token: token.access_token,
            refresh_token: token.refresh_token,
            token_type: token.token_type,
            expires_in: token.expires_in,
            refresh_expires_in: token.refresh_expires_in ?? token.expires_in,
            saved_at: now
        )
        try TokenStore.save(session)
        return session
    }

    /// Refreshes an access token. The refresh token is rotated — we save the
    /// new session to Keychain *before* the caller might use the old one.
    static func refresh(_ session: MyLifeDBSession) async throws -> MyLifeDBSession {
        guard let baseURL = URL(string: session.base_url) else {
            throw AuthError.discoveryFailed
        }
        let metadata = try await ConnectAuth().discover(baseURL: baseURL)
        let body = formEncode([
            "grant_type": "refresh_token",
            "refresh_token": session.refresh_token,
            "client_id": session.client_id,
        ])
        let token = try await postToken(url: metadata.tokenEndpoint, body: body)
        let now = Int(Date().timeIntervalSince1970)
        var rotated = session
        rotated.access_token = token.access_token
        rotated.refresh_token = token.refresh_token
        rotated.expires_in = token.expires_in
        rotated.refresh_expires_in = token.refresh_expires_in ?? token.expires_in
        rotated.saved_at = now
        rotated.scope = token.scope ?? session.scope
        // Persist BEFORE returning — replaying the old refresh token would
        // revoke the chain.
        try TokenStore.save(rotated)
        return rotated
    }

    /// Best-effort revoke + local clear. Safe to call when offline — Keychain
    /// is always cleared.
    static func signOut(_ session: MyLifeDBSession) async {
        if let url = URL(string: session.base_url + "/connect/revoke") {
            let body = formEncode([
                "token": session.refresh_token,
                "token_type_hint": "refresh_token",
                "client_id": session.client_id,
            ])
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            _ = try? await URLSession.shared.data(for: req)
        }
        TokenStore.clear()
    }

    // MARK: - Internals

    struct Metadata {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let revocationEndpoint: URL?
    }

    private struct DiscoveryResponse: Decodable {
        let authorization_endpoint: String
        let token_endpoint: String
        let revocation_endpoint: String?
    }

    func discover(baseURL: URL) async throws -> Metadata {
        let url = baseURL.appendingPathComponent(".well-known/oauth-authorization-server")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.discoveryFailed
        }
        let decoded = try JSONDecoder().decode(DiscoveryResponse.self, from: data)
        guard let auth = URL(string: decoded.authorization_endpoint),
              let tok = URL(string: decoded.token_endpoint) else {
            throw AuthError.discoveryFailed
        }
        return Metadata(
            authorizationEndpoint: auth,
            tokenEndpoint: tok,
            revocationEndpoint: decoded.revocation_endpoint.flatMap(URL.init(string:))
        )
    }

    /// Hands the authorize URL off to the system browser (which on iOS will
    /// route to a Universal Link handler — the MyLifeDB app — when installed,
    /// otherwise opens in Safari). Suspends until `handleCallback(_:)` is
    /// invoked by `.onOpenURL` or the timeout elapses.
    private func runExternalAuth(authorizeURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            // Defensive: if a prior flow leaked a continuation, cancel it so
            // we don't strand two completions on the same pending slot.
            if let stale = pendingContinuation {
                pendingContinuation = nil
                stale.resume(throwing: AuthError.userCancelled)
            }
            pendingContinuation = cont

            #if os(iOS)
            Task { @MainActor in
                let opened = await UIApplication.shared.open(authorizeURL)
                if !opened, let stuck = pendingContinuation {
                    pendingContinuation = nil
                    stuck.resume(throwing: AuthError.authServerError("could not open authorize URL"))
                }
            }
            #else
            pendingContinuation = nil
            cont.resume(throwing: AuthError.authServerError("external browser auth requires iOS"))
            return
            #endif

            // Watchdog: if the user never returns, fail the await.
            Task { @MainActor in
                try? await Task.sleep(for: Self.externalAuthTimeout)
                if let stuck = pendingContinuation {
                    pendingContinuation = nil
                    stuck.resume(throwing: AuthError.userCancelled)
                }
            }
        }
    }

    private func parseCallback(_ url: URL) -> (code: String?, state: String?, error: String?) {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        let dict = Dictionary(uniqueKeysWithValues: items.compactMap { i -> (String, String)? in
            guard let v = i.value else { return nil }
            return (i.name, v)
        })
        return (dict["code"], dict["state"], dict["error"])
    }

    fileprivate struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let token_type: String
        let expires_in: Int
        let refresh_expires_in: Int?
        let scope: String?
    }

    private func exchange(
        tokenEndpoint: URL,
        code: String,
        verifier: String
    ) async throws -> TokenResponse {
        let body = ConnectAuth.formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ])
        return try await ConnectAuth.postToken(url: tokenEndpoint, body: body)
    }

    fileprivate static func postToken(url: URL, body: Data) async throws -> TokenResponse {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.tokenExchange("no response")
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            throw AuthError.tokenExchange("HTTP \(http.statusCode) \(body)")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    static func formEncode(_ kv: [String: String]) -> Data {
        var c = URLComponents()
        c.queryItems = kv.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (c.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
    }
}
