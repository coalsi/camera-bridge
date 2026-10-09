import Foundation
import Testing
import TestSupport
@testable import BridgeWeb

@Suite(.timeLimit(.minutes(1))) struct StaticFilesTests {
    /// A directory with a few files, a secret next to it, and a harness serving it.
    private final class Site: Sendable {
        let root: TemporaryDirectory
        let web: URL
        let harness: Harness

        init() throws {
            root = try TemporaryDirectory(prefix: "cb-static")
            web = root.url.appending(path: "web", directoryHint: .isDirectory)
            let fm = FileManager.default
            try fm.createDirectory(at: web.appending(path: "app"), withIntermediateDirectories: true)
            try fm.createDirectory(at: web.appending(path: ".git"), withIntermediateDirectories: true)
            try Data("<!doctype html><title>Camera Bridge</title>".utf8).write(to: web.appending(path: "index.html"))
            try Data("export const x = 1;".utf8).write(to: web.appending(path: "app/main.js"))
            try Data("body{margin:0}".utf8).write(to: web.appending(path: "app/style.css"))
            try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: web.appending(path: "icon.svg"))
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: web.appending(path: "logo.png"))
            try Data("{}".utf8).write(to: web.appending(path: "site.webmanifest"))
            try Data("[core]".utf8).write(to: web.appending(path: ".git/config"))
            try Data("hidden".utf8).write(to: web.appending(path: ".env"))
            try Data("TOP SECRET".utf8).write(to: root.url.appending(path: "secret.txt"))
            try fm.createSymbolicLink(at: web.appending(path: "escape.txt"), withDestinationURL: root.url.appending(path: "secret.txt"))
            try fm.createSymbolicLink(at: web.appending(path: "inside.html"), withDestinationURL: web.appending(path: "index.html"))
            harness = try Harness(staticDirectory: web)
        }

        deinit { root.remove() }

        func get(_ path: String, headers: [(String, String)] = [], method: String = "GET") async -> Answer {
            await harness.send(method, path, headers: headers)
        }
    }

    @Test func theIndexIsServedAtTheRoot() async throws {
        let site = try Site()
        let answer = await site.get("/")
        #expect(answer.status == 200)
        #expect(answer.headers["Content-Type"] == "text/html; charset=utf-8")
        #expect(answer.text.contains("<title>Camera Bridge</title>"))
        #expect(answer.headers["Cache-Control"] == "no-cache")
        #expect(answer.headers["X-Content-Type-Options"] == "nosniff")
        #expect(answer.headers["Last-Modified"]?.hasSuffix("GMT") == true)
        #expect(await site.get("/index.html").text == answer.text)
    }

    @Test(arguments: [
        ("/app/main.js", "text/javascript; charset=utf-8", "no-cache"),
        ("/app/style.css", "text/css; charset=utf-8", "no-cache"),
        ("/icon.svg", "image/svg+xml", "public, max-age=86400"),
        ("/logo.png", "image/png", "public, max-age=86400"),
        ("/site.webmanifest", "application/manifest+json; charset=utf-8", "no-cache"),
    ])
    func contentTypesAndCachingFollowTheFileKind(path: String, type: String, cache: String) async throws {
        let site = try Site()
        let answer = await site.get(path)
        #expect(answer.status == 200)
        #expect(answer.headers["Content-Type"] == type)
        #expect(answer.headers["Cache-Control"] == cache)
    }

    @Test func aBrowserThatHasTheFileIsTold304() async throws {
        let site = try Site()
        let first = await site.get("/app/main.js")
        let etag = try #require(first.headers["ETag"])
        #expect(etag.hasPrefix("\"") && etag.hasSuffix("\""))
        let again = await site.get("/app/main.js", headers: [("If-None-Match", etag)])
        #expect(again.status == 304)
        #expect(again.body.isEmpty)
        #expect(again.headers["ETag"] == etag)
        #expect(await site.get("/app/main.js", headers: [("If-None-Match", "W/\(etag)")]).status == 304)
        #expect(await site.get("/app/main.js", headers: [("If-None-Match", "\"other\", \(etag)")]).status == 304)
        #expect(await site.get("/app/main.js", headers: [("If-None-Match", "*")]).status == 304)
        #expect(await site.get("/app/main.js", headers: [("If-None-Match", "\"other\"")]).status == 200)
    }

    @Test func aChangedFileGetsANewETag() async throws {
        let site = try Site()
        let before = await site.get("/app/main.js")
        try Data("export const x = 2; // longer now".utf8).write(to: site.web.appending(path: "app/main.js"))
        let after = await site.get("/app/main.js")
        #expect(after.text.contains("x = 2"))
        #expect(after.headers["ETag"] != before.headers["ETag"])
        #expect(await site.get("/app/main.js", headers: [("If-None-Match", try #require(before.headers["ETag"]))]).status == 200)
    }

    @Test func headSendsNoBody() async throws {
        let site = try Site()
        let answer = await site.get("/app/main.js", method: "HEAD")
        #expect(answer.status == 200)
        #expect(answer.headers["Content-Type"] == "text/javascript; charset=utf-8")
    }

    @Test func onlyReadingIsAllowed() async throws {
        let site = try Site()
        for method in ["POST", "PUT", "DELETE", "PATCH"] {
            let answer = await site.get("/app/main.js", method: method)
            #expect(answer.status == 405, "\(method)")
            #expect(answer.headers["Allow"] == "GET, HEAD")
        }
    }

    @Test(arguments: [
        "/../secret.txt", "/%2e%2e/secret.txt", "/..%2fsecret.txt", "/app/../../secret.txt", "/app/%2e%2e/%2e%2e/secret.txt", "//secret.txt",
        "/app/..", "/./index.html", "/app//main.js", "/.env", "/.git/config", "/%2eenv", "/app/main.js%00.png", "/app%5c..%5csecret.txt", "/escape.txt",
        "/app/", "/app", "/nothing.js", "/%ff%fe", "/index.html/",
    ])
    func pathsOutsideTheSiteAreNotFound(path: String) async throws {
        let site = try Site()
        let answer = await site.get(path)
        #expect(answer.status == 404, "\(path) answered \(answer.status)")
        #expect(!answer.text.contains("TOP SECRET"))
        #expect(!answer.text.contains("hidden"))
    }

    @Test func aSymbolicLinkInsideTheSiteWorks() async throws {
        let site = try Site()
        #expect(await site.get("/inside.html").status == 200)
    }

    @Test func aMissingDirectoryIsExplained() async throws {
        let harness = try Harness(staticDirectory: nil)
        let answer = await harness.send("GET", "/")
        #expect(answer.status == 404)
        #expect(answer.text.contains("not installed"))
        let gone = try Harness(staticDirectory: URL(fileURLWithPath: "/nonexistent/camera-bridge-web"))
        #expect(await gone.send("GET", "/").status == 404)
    }

    @Test func theApiIsNotShadowedByFiles() async throws {
        let site = try Site()
        try FileManager.default.createDirectory(at: site.web.appending(path: "api/v1"), withIntermediateDirectories: true)
        try Data("shadow".utf8).write(to: site.web.appending(path: "api/v1/status"))
        let answer = await site.get("/api/v1/status")
        #expect(answer.status == 200)
        #expect(answer.json["product"] as? String == "Camera Bridge OS")
    }

    @Test func relativePathRules() {
        #expect(StaticFiles.relativePath(for: "/") == "index.html")
        #expect(StaticFiles.relativePath(for: "/a/b.js") == "a/b.js")
        #expect(StaticFiles.relativePath(for: "/a%20b.js") == "a b.js")
        #expect(StaticFiles.relativePath(for: "a") == nil)
        #expect(StaticFiles.relativePath(for: "/a/../b") == nil)
        #expect(StaticFiles.relativePath(for: "/a//b") == nil)
        #expect(StaticFiles.relativePath(for: "/a/.b") == nil)
        #expect(StaticFiles.relativePath(for: "/a\\b") == nil)
        #expect(StaticFiles.relativePath(for: "/a%00") == nil)
    }
}
