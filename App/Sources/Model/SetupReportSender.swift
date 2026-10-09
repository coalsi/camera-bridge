import BridgeSupport
import Foundation

/// Sends a setup report the person agreed to send. Anything that goes wrong is logged (without the report) and
/// otherwise ignored: a report is a courtesy, never something the person has to deal with.
protocol SetupReportSending {
    /// Posts exactly these bytes. True when the server accepted them.
    func send(_ body: Data) async -> Bool
}

struct LiveSetupReportSender: SetupReportSending {
    private let log = Log(category: "Reports")

    func send(_ body: Data) async -> Bool {
        var request = URLRequest(url: CameraBridgeService.setupReportsEndpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(CameraBridgeService.clientHeaderValue, forHTTPHeaderField: CameraBridgeService.clientHeaderName)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                log.warning("Setup report not sent: no HTTP answer")
                return false
            }
            guard http.statusCode == 202 else {
                log.warning("Setup report not sent: the server answered \(http.statusCode)")
                return false
            }
            log.info("Setup report sent")
            return true
        } catch {
            log.warning("Setup report not sent (\(type(of: error)))")
            return false
        }
    }
}
