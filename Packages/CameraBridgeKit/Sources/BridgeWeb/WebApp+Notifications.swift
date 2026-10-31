import Foundation

// Notifications: the log of everything that was a notice (`NotificationLog`), for the page's Notifications section and its toasts.
//   GET  /notifications          { unread, notifications: [entry] }, newest first (the log is brought up to date first)
//   POST /notifications/shown    { shown: [entry], unread }: the current notices not yet shown as a toast, marked shown, so exactly one
//                                browser shows each, once
//   POST /notifications/read     { ids?: [string] } -> { unread }: those entries read, or all of them without `ids`
//   POST /notifications/dismiss  { id } -> { dismissed: true }: puts away a notice whose action is "dismiss" (the damaged configuration's);
//                                400 for any other notice (they go away on their own)
// An entry: { id, key, noticeID, kind, category (security|recording|cameras|system), severity, title, detail, cameraID, cameraName, action,
// date, read, toasted }.

extension WebApp {
    static let notificationRoutes: [Route] = [
        Route("GET", "notifications") { app, _ in await app.notificationList() },
        Route("POST", "notifications/shown") { app, _ in await app.notificationsShown() },
        Route("POST", "notifications/read", takesBody: true) { app, ctx in try app.notificationsRead(ctx) },
        Route("POST", "notifications/dismiss", takesBody: true) { app, ctx in try await app.notificationDismiss(ctx) },
    ]

    private struct NotificationList: Encodable {
        var unread: Int
        var notifications: [NotificationEntry]
    }

    private struct NotificationsShown: Encodable {
        var shown: [NotificationEntry]
        var unread: Int
    }

    private struct NotificationsRead: Decodable {
        var ids: [String]?
    }

    private struct NotificationDismiss: Decodable {
        var id: String
    }

    /// The notices now, and a burst of wrong passwords of the last day (in the log since it began; here so that a browser can claim its toast).
    private func currentNotices() async -> [NoticeResource] {
        let notices = NoticeResource.resources(for: await backend.overview(), now: Date())
        notifications.record(notices)
        guard let alert = await auth.signInAlert() else { return notices }
        let signIn = NoticeResource.signInNotice(alert)
        notifications.recordEvent(signIn, now: alert.since)
        return notices + [signIn]
    }

    func notificationList() async -> HTTPResponse {
        _ = await currentNotices()
        return .json(NotificationList(unread: notifications.unread, notifications: notifications.entries()))
    }

    func notificationsShown() async -> HTTPResponse {
        let notices = await currentNotices()
        let shown = notifications.claim(notices)
        return .json(NotificationsShown(shown: shown, unread: notifications.unread))
    }

    func notificationDismiss(_ ctx: RequestContext) async throws -> HTTPResponse {
        let body = try decode(NotificationDismiss.self, from: ctx)
        guard body.id == NoticeResource.configurationRecoveredID else {
            throw APIError.badRequest("This notice goes away by itself once the bridge no longer needs you.", field: "id")
        }
        await backend.acknowledgeConfigurationRecovery()
        return .json(["dismissed": true])
    }

    func notificationsRead(_ ctx: RequestContext) throws -> HTTPResponse {
        let body = try? decode(NotificationsRead.self, from: ctx)
        notifications.markRead(ids: body?.ids)
        return .json(["unread": notifications.unread])
    }
}
