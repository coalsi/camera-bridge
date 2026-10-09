import BridgeSupport
import Crypto
import Foundation
import Synchronization

/// Serves the web interface's files (`linux/web/` on a development machine, `/usr/share/camera-bridge/web` on the system).
///
/// - Only GET and HEAD. `/` is `index.html`; there is no directory listing and no fallback page (the interface routes in the
///   URL's `#fragment`), so an unknown path is a plain 404.
/// - A path is decoded once, must not contain `..`, empty or dot-leading segments, backslashes or NUL, and must still resolve
///   inside the directory after symbolic links are followed.
/// - Files are read when first asked for and again when their modification date or size changes. Each has a strong `ETag` (a
///   SHA-256 prefix of its content), so a browser's `If-None-Match` is answered with 304. Pages, scripts and styles carry
///   `Cache-Control: no-cache` (always revalidate: there is no build step to put a hash in their names); images and fonts may be
///   kept for a day.
/// - Content types are explicit and every response says `nosniff` (the application adds the rest of the security headers).
final class StaticFiles: Sendable {
    private struct Entry: Sendable {
        var data: Data
        var etag: String
        var contentType: String
        var modified: Date
        var size: Int
    }

    static let maximumFileSize = 8 * 1024 * 1024

    private let root: URL?
    /// The directory's resolved path without a trailing slash.
    private let rootPath: String
    private let cache = Mutex<[String: Entry]>([:])

    init(directory: URL?) {
        root = directory?.standardizedFileURL.resolvingSymlinksInPath()
        var path = root?.path(percentEncoded: false) ?? ""
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        rootPath = path
    }

    var isAvailable: Bool { root != nil }

    func response(for request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            var headers = HTTPHeaders()
            headers["Allow"] = "GET, HEAD"
            return HTTPResponse(status: 405, headers: headers)
        }
        guard let root else { return Self.missing }
        guard let relative = Self.relativePath(for: request.path) else { return Self.notFound }
        let file = root.appending(path: relative, directoryHint: .notDirectory)
        // Symbolic links may not lead out of the directory.
        let resolved = file.resolvingSymlinksInPath()
        guard resolved.path(percentEncoded: false).hasPrefix(rootPath + "/") else { return Self.notFound }
        guard let entry = load(resolved, key: relative) else { return Self.notFound }

        var headers = HTTPHeaders()
        headers["Content-Type"] = entry.contentType
        headers["ETag"] = entry.etag
        headers["X-Content-Type-Options"] = "nosniff"
        headers["Cache-Control"] = Self.cacheControl(for: relative)
        headers["Last-Modified"] = HTTPDate.string(from: entry.modified)
        if let match = request.headers["If-None-Match"], Self.matches(match, etag: entry.etag) {
            return HTTPResponse(status: 304, headers: headers)
        }
        return HTTPResponse(status: 200, headers: headers, body: .data(entry.data))
    }

    // MARK: Paths

    /// The file a request path names, relative to the directory; nil for anything that is not a plain path below it.
    static func relativePath(for rawPath: String) -> String? {
        guard rawPath.hasPrefix("/"), let decoded = rawPath.removingPercentEncoding else { return nil }
        guard !decoded.contains("\0"), !decoded.contains("\\") else { return nil }
        let path = decoded == "/" ? "/index.html" : decoded
        var segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        segments.removeFirst()   // the empty text before the leading slash
        guard !segments.isEmpty else { return nil }
        for segment in segments where segment.isEmpty || segment.hasPrefix(".") { return nil }
        return segments.joined(separator: "/")
    }

    private static func cacheControl(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "svg", "ico", "woff2", "webp": "public, max-age=86400"
        default: "no-cache"
        }
    }

    private static func matches(_ header: String, etag: String) -> Bool {
        if header.trimmingCharacters(in: .whitespaces) == "*" { return true }
        return header.split(separator: ",").contains {
            let candidate = $0.trimmingCharacters(in: .whitespaces)
            return candidate == etag || candidate == "W/" + etag
        }
    }

    static func contentType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "webmanifest": "application/manifest+json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "ico": "image/x-icon"
        case "woff2": "font/woff2"
        case "txt": "text/plain; charset=utf-8"
        case "map": "application/json; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    // MARK: Reading

    private func load(_ url: URL, key: String) -> Entry? {
        let path = url.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= Self.maximumFileSize,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        if let cached = cache.withLock({ $0[key] }), cached.modified == modified, cached.size == size { return cached }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let entry = Entry(data: data, etag: "\"\(digest)\"", contentType: Self.contentType(for: key), modified: modified, size: size)
        cache.withLock { cache in
            if cache.count > 256 { cache.removeAll() }
            cache[key] = entry
        }
        return entry
    }

    private static let notFound = HTTPResponse.text("Not found\n", status: 404)
    private static let missing = HTTPResponse.text("The web interface files are not installed on this system.\n", status: 404)
}
