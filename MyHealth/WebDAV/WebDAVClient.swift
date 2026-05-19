import Foundation

/// Minimal WebDAV client using HTTP Basic auth. Implements the small subset
/// MyHealth needs: PUT (upload), GET (read), and MKCOL (folder create) on
/// the per-segment path under the user-configured root folder.
///
/// Folder layout mirrors the other destinations:
///     <root_folder>/apple-health/YYYY/MM/DD/<kebab-type>.json
///     <root_folder>/apple-health/YYYY/MM/DD/workout-<UUID>.json
struct WebDAVClient {
    let credentials: WebDAVCredentials
    let subPath: [String]
    private let urlSession: URLSession

    init(credentials: WebDAVCredentials,
         subPath: [String] = ["apple-health"],
         urlSession: URLSession = .shared) {
        self.credentials = credentials
        self.subPath = subPath
        self.urlSession = urlSession
    }

    func uploadFile(relativePath: String, localFile: URL) async throws {
        let data = try Data(contentsOf: localFile, options: .mappedIfSafe)
        try await uploadBytes(relativePath: relativePath, body: data)
    }

    func uploadBytes(relativePath: String, body: Data) async throws {
        let segments = pathSegments(relativePath: relativePath)
        try await ensureCollections(segments: Array(segments.dropLast()))
        let url = try makeURL(segments: segments)
        try await put(url: url, data: body)
    }

    /// Reads bytes at the given path, or returns nil on 404.
    func getFile(relativePath: String) async throws -> Data? {
        let url = try makeURL(segments: pathSegments(relativePath: relativePath))
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw WebDAVError.transport("no HTTP response")
        }
        switch http.statusCode {
        case 200..<300: return data
        case 404: return nil
        default:
            throw WebDAVError.http(http.statusCode, snippet(data))
        }
    }

    /// Lightweight connectivity check used by the settings screen — issues a
    /// PROPFIND on the root folder (creating it first if necessary) and
    /// validates that credentials + URL resolve to a writable collection.
    func verifyAccess() async throws {
        try await ensureCollections(segments: rootSegments())
        let url = try makeURL(segments: rootSegments())
        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        req.setValue("0", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let body = """
        <?xml version="1.0" encoding="utf-8"?>\
        <D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop></D:propfind>
        """
        req.httpBody = body.data(using: .utf8)
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw WebDAVError.transport("no HTTP response")
        }
        // 207 Multi-Status is the success code for PROPFIND; some servers
        // return 200 for plain OK.
        if !(http.statusCode == 207 || (200..<300).contains(http.statusCode)) {
            throw WebDAVError.http(http.statusCode, snippet(data))
        }
    }

    // MARK: - Path / URL plumbing

    private func rootSegments() -> [String] {
        let root = credentials.root_folder
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        return root + subPath
    }

    private func pathSegments(relativePath: String) -> [String] {
        let rel = relativePath
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        return rootSegments() + rel
    }

    private func makeURL(segments: [String]) throws -> URL {
        guard let base = URL(string: credentials.base_url) else {
            throw WebDAVError.badBaseURL
        }
        var url = base
        for seg in segments {
            url = url.appendingPathComponent(seg, isDirectory: false)
        }
        return url
    }

    private func authHeader() -> String {
        let raw = "\(credentials.username):\(credentials.password)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    private func snippet(_ data: Data) -> String {
        String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
    }

    // MARK: - HTTP verbs

    private func put(url: URL, data: Data) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        req.httpBody = data
        let (body, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw WebDAVError.transport("no HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            throw WebDAVError.http(http.statusCode, snippet(body))
        }
    }

    /// Creates each collection in the path, top-down. 405 Method Not Allowed
    /// is the standard "already exists" response and is treated as success.
    private func ensureCollections(segments: [String]) async throws {
        var prefix: [String] = []
        for seg in segments {
            prefix.append(seg)
            let url = try makeURL(segments: prefix)
            try await mkcol(url: url)
        }
    }

    private func mkcol(url: URL) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "MKCOL"
        req.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        let (body, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw WebDAVError.transport("no HTTP response")
        }
        switch http.statusCode {
        case 200..<300, 405: return
        default:
            throw WebDAVError.http(http.statusCode, snippet(body))
        }
    }
}

enum WebDAVError: Error, LocalizedError {
    case badBaseURL
    case transport(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badBaseURL: return "Invalid WebDAV base URL."
        case .transport(let s): return "Network error: \(s)"
        case .http(let code, let body): return "WebDAV returned HTTP \(code): \(body)"
        }
    }
}
