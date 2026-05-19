import Foundation

/// Minimal Google Drive REST client. Uses the `drive.file` scope, which means
/// we can only see and modify files MyHealth itself created — the app cannot
/// touch the rest of the user's Drive.
///
/// Folder layout mirrors MyLifeDB:
///     MyHealth/apple-health/syncs/<batch-id>/<file>.jsonl
///     MyHealth/apple-health/manifest.json
struct GoogleDriveClient {
    let rootFolderName: String           // "MyHealth"
    let subPath: [String]                // ["apple-health"]

    private let urlSession: URLSession

    init(rootFolderName: String = "MyHealth",
         subPath: [String] = ["apple-health"],
         urlSession: URLSession = .shared) {
        self.rootFolderName = rootFolderName
        self.subPath = subPath
        self.urlSession = urlSession
    }

    func uploadFile(relativePath: String, localFile: URL) async throws {
        let token = try await DriveAuth.freshAccessToken()
        let parents = try await ensureFolderPath(
            components: subPath + relativePath.split(separator: "/").map(String.init).dropLast(),
            token: token
        )
        let fileName = (relativePath as NSString).lastPathComponent
        let data = try Data(contentsOf: localFile, options: .mappedIfSafe)
        try await uploadOrReplace(name: fileName, parent: parents, data: data, token: token)
    }

    func uploadBytes(relativePath: String, body: Data) async throws {
        let token = try await DriveAuth.freshAccessToken()
        let parents = try await ensureFolderPath(
            components: subPath + relativePath.split(separator: "/").map(String.init).dropLast(),
            token: token
        )
        let fileName = (relativePath as NSString).lastPathComponent
        try await uploadOrReplace(name: fileName, parent: parents, data: body, token: token)
    }

    /// Fetches the bytes at `<remote_path>/<relativePath>`, or returns nil if
    /// the file does not exist in Drive (404 or no match in our folder tree).
    func getFile(relativePath: String) async throws -> Data? {
        let token = try await DriveAuth.freshAccessToken()
        // Walk subPath + the leading components of relativePath; if any
        // segment is missing the file can't exist in our subtree.
        let relativeParents = relativePath.split(separator: "/").map(String.init).dropLast()
        let pathComponents: [String] = subPath + Array(relativeParents)
        guard let parent = try await findFolderPath(components: pathComponents, token: token) else {
            return nil
        }
        let fileName = (relativePath as NSString).lastPathComponent
        guard let fileID = try await findFile(name: fileName, parent: parent, mimeType: nil, token: token) else {
            return nil
        }
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!
        components.queryItems = [.init(name: "alt", value: "media")]
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    /// Read-only sibling of `ensureFolderPath`: returns nil at the first
    /// missing segment instead of creating folders.
    private func findFolderPath(components: [String], token: String) async throws -> String? {
        guard let rootID = try await findFile(
            name: rootFolderName, parent: "root",
            mimeType: "application/vnd.google-apps.folder", token: token
        ) else { return nil }
        var parent = rootID
        for c in components where !c.isEmpty {
            guard let next = try await findFile(
                name: c, parent: parent,
                mimeType: "application/vnd.google-apps.folder", token: token
            ) else { return nil }
            parent = next
        }
        return parent
    }

    // MARK: - Folder ensure

    /// Walks `components` from the user's root, creating missing folders. The
    /// outer `MyHealth` root folder is created at the user's Drive root.
    private func ensureFolderPath(components: [String], token: String) async throws -> String {
        var parent = try await ensureFolder(name: rootFolderName, parent: "root", token: token)
        for c in components {
            guard !c.isEmpty else { continue }
            parent = try await ensureFolder(name: c, parent: parent, token: token)
        }
        return parent
    }

    private func ensureFolder(name: String, parent: String, token: String) async throws -> String {
        if let id = try await findFile(name: name, parent: parent, mimeType: "application/vnd.google-apps.folder", token: token) {
            return id
        }
        return try await createFolder(name: name, parent: parent, token: token)
    }

    private func findFile(name: String, parent: String, mimeType: String?, token: String) async throws -> String? {
        var queryParts = [
            "name = '\(name.replacingOccurrences(of: "'", with: "\\'"))'",
            "'\(parent)' in parents",
            "trashed = false",
        ]
        if let mimeType { queryParts.append("mimeType = '\(mimeType)'") }
        let q = queryParts.joined(separator: " and ")
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            .init(name: "q", value: q),
            .init(name: "fields", value: "files(id, name)"),
            .init(name: "spaces", value: "drive"),
        ]
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await urlSession.data(for: req)
        try validate(resp, body: data)
        struct Response: Decodable { let files: [File]; struct File: Decodable { let id: String } }
        return try JSONDecoder().decode(Response.self, from: data).files.first?.id
    }

    private func createFolder(name: String, parent: String, token: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parent],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await urlSession.data(for: req)
        try validate(resp, body: data)
        struct Response: Decodable { let id: String }
        return try JSONDecoder().decode(Response.self, from: data).id
    }

    // MARK: - File upload (multipart create-or-replace)

    private func uploadOrReplace(name: String, parent: String, data: Data, token: String) async throws {
        if let existing = try await findFile(name: name, parent: parent, mimeType: nil, token: token) {
            try await updateFile(id: existing, data: data, token: token)
        } else {
            try await createFile(name: name, parent: parent, data: data, token: token)
        }
    }

    private func createFile(name: String, parent: String, data: Data, token: String) async throws {
        let boundary = "myhealth-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let metadata = ["name": name, "parents": [parent]] as [String: Any]
        let metaJSON = try JSONSerialization.data(withJSONObject: metadata)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metaJSON)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (resp, httpResp) = try await urlSession.data(for: req)
        try validate(httpResp, body: resp)
    }

    private func updateFile(id: String, data: Data, token: String) async throws {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media")!)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let (respBody, response) = try await urlSession.data(for: req)
        try validate(response, body: respBody)
    }

    private func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GoogleDrive", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no HTTP response"])
        }
        if !(200..<300).contains(http.statusCode) {
            let snippet = String(data: body, encoding: .utf8) ?? "<binary>"
            throw NSError(
                domain: "GoogleDrive", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(snippet)"]
            )
        }
    }
}
