import BridgeSupport
import CameraAdapters
import Foundation

/// Loads and refreshes the camera profiles feed: the copy bundled with the app is the fallback, a downloaded copy is
/// cached in Application Support, and the server is asked at most once per 24 hours (with `If-None-Match`).
/// Nothing about the person, their cameras or their network is sent: it is a plain GET of a public file.
final class CameraProfileService {
    /// Cached feed metadata.
    struct Metadata: Codable, Equatable {
        var etag: String?
        var lastCheck: Date?
    }

    /// Performs one request (tests inject answers; the app uses an ephemeral `URLSession`).
    typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let bundledResourceName = "CameraProfiles"

    private let directory: URL
    private let bundle: Bundle
    private let fetch: Fetch
    private let now: () -> Date
    private let log = Log(category: "Profiles")
    private var feedURL: URL { directory.appending(path: "camera-profiles.json") }
    private var metadataURL: URL { directory.appending(path: "camera-profiles-meta.json") }

    init(directory: URL = CameraProfileService.defaultDirectory, bundle: Bundle = .main,
         fetch: @escaping Fetch = CameraProfileService.liveFetch, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.bundle = bundle
        self.fetch = fetch
        self.now = now
    }

    static var defaultDirectory: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "CameraBridge", directoryHint: .isDirectory).appending(path: "CameraProfiles", directoryHint: .isDirectory)
    }

    static func liveFetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    // MARK: Current feed

    /// The downloaded feed if there is a valid one, else the bundled seed, else an empty feed.
    func currentFeed() -> CameraProfileFeed {
        if let data = try? Data(contentsOf: feedURL), let feed = CameraProfileFeed.decode(data) { return feed }
        return bundledFeed()
    }

    func bundledFeed() -> CameraProfileFeed {
        guard let url = bundle.url(forResource: Self.bundledResourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url), let feed = CameraProfileFeed.decode(data) else { return .empty }
        return feed
    }

    // MARK: Refresh

    var metadata: Metadata {
        guard let data = try? Data(contentsOf: metadataURL), let value = try? JSONDecoder().decode(Metadata.self, from: data) else { return Metadata() }
        return value
    }

    /// What a refresh found.
    enum RefreshOutcome: Equatable {
        /// A newer feed arrived and was cached.
        case updated(CameraProfileFeed)
        /// The server has nothing newer (304).
        case upToDate
        /// Not due yet (the last check was less than 24 hours ago) and the check wasn't forced.
        case notDue
        /// The server couldn't be reached or its answer wasn't a feed (logged, never shown as an alert).
        case failed
    }

    /// What Settings shows about the feed in use.
    struct Status: Equatable {
        var version: String
        var profileCount: Int
        /// The feed's own "updated" text, when it has one.
        var updated: String?
        /// A downloaded copy is in use (else the one bundled with the app).
        var isDownloaded: Bool
        /// When the server last answered (an update or "nothing newer"); nil: never.
        var lastCheck: Date?
    }

    func status() -> Status {
        let downloaded = (try? Data(contentsOf: feedURL)).flatMap(CameraProfileFeed.decode)
        let feed = downloaded ?? bundledFeed()
        return Status(version: feed.version, profileCount: feed.profiles.count, updated: feed.updated, isDownloaded: downloaded != nil,
                      lastCheck: metadata.lastCheck)
    }

    /// Asks the server for a newer feed when the last check was 24 hours ago or more. Returns the new feed when one
    /// arrived; nil when it wasn't due, nothing changed, or anything went wrong (logged, never shown).
    func refreshIfDue() async -> CameraProfileFeed? {
        if case .updated(let feed) = await refresh(force: false) { return feed }
        return nil
    }

    /// `refreshIfDue()` with the outcome; `force` asks the server even when the last check was recent (Settings › Check
    /// Now).
    func refresh(force: Bool) async -> RefreshOutcome {
        var meta = metadata
        let started = now()
        guard force || CameraProfileRefreshPolicy.isDue(lastCheck: meta.lastCheck, now: started) else { return .notDue }

        var request = URLRequest(url: CameraBridgeService.cameraProfilesEndpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Only send a validator for a copy that is still on disk.
        if let etag = meta.etag, FileManager.default.fileExists(atPath: feedURL.path) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await fetch(request)
            switch response.statusCode {
            case 304:
                meta.lastCheck = started
                save(meta)
                log.info("Camera profiles are up to date")
                return .upToDate
            case 200:
                guard let feed = CameraProfileFeed.decode(data) else {
                    log.warning("Camera profiles: the server's answer was not a profiles feed")
                    return .failed
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: feedURL, options: .atomic)
                meta.etag = response.value(forHTTPHeaderField: "ETag")
                meta.lastCheck = started
                save(meta)
                log.info("Camera profiles updated to version \(feed.version) (\(feed.profiles.count) profiles)")
                return .updated(feed)
            default:
                log.warning("Camera profiles: the server answered \(response.statusCode)")
                return .failed
            }
        } catch {
            log.warning("Camera profiles could not be refreshed (\(type(of: error)))")
            return .failed
        }
    }

    private func save(_ meta: Metadata) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(meta).write(to: metadataURL, options: .atomic)
        } catch {
            log.warning("Camera profiles: could not save the check time (\(type(of: error)))")
        }
    }
}
