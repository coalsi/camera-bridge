import Foundation

// Notifications: the log of everything that was a notice (`NotificationLog`), for the page's Notifications section and its toasts.
//   GET  /notifications          { unread, notifications: [entry] }, newest first (the log is brought up to date first)
//   POST /notifications/shown    { shown: [entry], unread }: the current notices not yet shown as a toast, marked shown, so exactly one
//                                browser shows each, once
//   POST /notifications/read     { ids?: [string] } -> { unread }: those entries read, or all of them without `ids`
// An entry: { id, key, noticeID, kind, category (security|recording|cameras|system), severity, title, detail, cameraID, cameraName, action,
// date, read, toasted }.

extension WebApp {
    static let notificationRoutes: [Route] = [
        Route("GET", "notifications") { app, _ in await app.notificationList() },
        Route("POST", "notifications/shown") { app, _ in await app.notificationsShown() },
        Route("POST", "notifications/read", takesBody: true) { app, ctx in try app.notificationsRead(ctx) },
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

    private func currentNotices() async -> [NoticeResource] {
        let notices = NoticeResource.resources(for: await backend.overview(), now: Date())
        notifications.record(notices)
        return notices
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

    func notificationsRead(_ ctx: RequestContext) throws -> HTTPResponse {
        let body = try? decode(NotificationsRead.self, from: ctx)
        notifications.markRead(ids: body?.ids)
        return .json(["unread": notifications.unread])
    }
}
