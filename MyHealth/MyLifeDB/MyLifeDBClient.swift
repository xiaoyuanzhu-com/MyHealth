import Foundation
import CryptoKit

/// HTTP client for MyLifeDB's `/raw/*` byte API. Handles automatic refresh on
/// `401 AUTH_INVALID_TOKEN` per the Connect spec.
actor MyLifeDBClient {
    private var session: MyLifeDBSession
    private let urlSession: URLSession

    init(session: MyLifeDBSession, urlSession: URLSession = .shared) {
        self.session = session
        self.urlSession = urlSession
    }

    /// Uploads `localFile` to `<remote_path>/<relativePath>` using
    /// `PUT /raw/<absolute_remote_path>`. Streams the file from disk to keep
    /// memory flat for large workout-route batches.
    func putFile(relativePath: String, localFile: URL) async throws {
        let absolute = absolutePath(relativePath)
        let url = try makeRawURL(absolute: absolute)
        let data = try Data(contentsOf: localFile, options: .mappedIfSafe)
        try await put(url: url, data: data)
    }

    /// Convenience for in-memory uploads (e.g., manifest.json).
    func putBytes(relativePath: String, body: Data, contentType: String = "application/octet-stream") async throws {
        let absolute = absolutePath(relativePath)
        let url = try makeRawURL(absolute: absolute)
        try await put(url: url, data: body, contentType: contentType)
    }

    /// Reads bytes at `<remote_path>/<relativePath>`, or returns nil on 404.
    func getFile(relativePath: String) async throws -> Data? {
        let absolute = absolutePath(relativePath)
        let url = try makeRawURL(absolute: absolute)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try await execute(req)
    }

    var currentSession: MyLifeDBSession { session }

    // MARK: - Internals

    private func absolutePath(_ relative: String) -> String {
        let root = session.remote_path.hasPrefix("/") ? session.remote_path : "/" + session.remote_path
        let trimmedRel = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        return root.hasSuffix("/") ? root + trimmedRel : root + "/" + trimmedRel
    }

    private func makeRawURL(absolute: String) throws -> URL {
        guard let base = URL(string: session.base_url) else {
            throw MyLifeDBError.badBaseURL
        }
        let rawPath = "/raw" + absolute
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = rawPath
        guard let url = components?.url else { throw MyLifeDBError.badBaseURL }
        return url
    }

    private func put(url: URL, data: Data, contentType: String = "application/octet-stream") async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        req.setValue(sha256Hex(data), forHTTPHeaderField: "X-Content-SHA256")
        req.httpBody = data

        _ = try await execute(req)
    }

    /// Executes a request with automatic refresh-on-401, returning the body
    /// on 200/204 or nil on 404.
    private func execute(_ original: URLRequest) async throws -> Data? {
        var req = original
        req.setValue("Bearer \(session.access_token)", forHTTPHeaderField: "Authorization")

        let method = req.httpMethod ?? "?"
        let path = req.url?.path ?? "?"
        let reqBytes = req.httpBody?.count ?? 0

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            print("MyHealth: mld \(method) \(path) bytes=\(reqBytes) → transport error: \(error.localizedDescription)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            print("MyHealth: mld \(method) \(path) bytes=\(reqBytes) → no HTTP response")
            throw MyLifeDBError.transport("no HTTP response")
        }

        switch http.statusCode {
        case 200, 201, 204:
            print("MyHealth: mld \(method) \(path) bytes=\(reqBytes) → \(http.statusCode)")
            return data
        case 404:
            print("MyHealth: mld \(method) \(path) bytes=\(reqBytes) → 404")
            return nil
        case 401:
            // Refresh and retry once.
            print("MyHealth: mld \(method) \(path) → 401, refreshing token")
            let refreshed = try await ConnectAuth.refresh(session)
            self.session = refreshed
            var retry = original
            retry.setValue("Bearer \(refreshed.access_token)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResp) = try await urlSession.data(for: retry)
            guard let retryHTTP = retryResp as? HTTPURLResponse else {
                print("MyHealth: mld \(method) \(path) → no HTTP response after refresh")
                throw MyLifeDBError.transport("no HTTP response after refresh")
            }
            if (200..<300).contains(retryHTTP.statusCode) {
                print("MyHealth: mld \(method) \(path) bytes=\(reqBytes) → \(retryHTTP.statusCode) (after refresh)")
                return retryData
            }
            if retryHTTP.statusCode == 404 {
                print("MyHealth: mld \(method) \(path) → 404 (after refresh)")
                return nil
            }
            let body = String(data: retryData, encoding: .utf8) ?? ""
            print("MyHealth: mld \(method) \(path) bytes=\(reqBytes) → \(retryHTTP.statusCode) (after refresh) body=\(body.prefix(200))")
            throw MyLifeDBError.http(retryHTTP.statusCode, body: body)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            print("MyHealth: mld \(method) \(path) bytes=\(reqBytes) → \(http.statusCode) body=\(body.prefix(200))")
            throw MyLifeDBError.http(http.statusCode, body: body)
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum MyLifeDBError: Error, LocalizedError {
    case badBaseURL
    case transport(String)
    case http(Int, body: String)

    var errorDescription: String? {
        switch self {
        case .badBaseURL: return "Invalid MyLifeDB base URL."
        case .transport(let s): return "Network error: \(s)"
        case .http(let code, let body): return "MyLifeDB returned HTTP \(code): \(body)"
        }
    }
}
