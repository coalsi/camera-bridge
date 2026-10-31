import Foundation

/// A browser's `User-Agent` as a person names it: "Safari on iPhone", "Chrome on Windows", "Firefox on Linux" (the Signed-in browsers
/// list). Never more than 60 printable characters, whatever was sent.
enum BrowserLabel {
    static func describe(_ userAgent: String?) -> String {
        guard let agent = userAgent?.trimmingCharacters(in: .whitespaces), !agent.isEmpty else { return "A browser" }
        let browser = browserName(agent), system = systemName(agent)
        switch (browser, system) {
        case let (browser?, system?): return "\(browser) on \(system)"
        case let (browser?, nil): return browser
        case let (nil, system?): return "A browser on \(system)"
        case (nil, nil):
            // A tool rather than a browser ("curl/8.7.1", "HomeAssistant/2026.10"): its name, made safe.
            let name = agent.split(separator: "/").first.map(String.init) ?? agent
            let safe = String(name.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }.map(Character.init)).trimmingCharacters(in: .whitespaces)
            return safe.isEmpty ? "A browser" : String(safe.prefix(60))
        }
    }

    /// The order matters: Edge and Opera also say Chrome and Safari, Chrome also says Safari.
    private static func browserName(_ agent: String) -> String? {
        if agent.contains("Edg/") || agent.contains("EdgiOS") || agent.contains("EdgA/") { return "Edge" }
        if agent.contains("OPR/") || agent.contains("Opera") { return "Opera" }
        if agent.contains("Firefox/") || agent.contains("FxiOS") { return "Firefox" }
        if agent.contains("SamsungBrowser/") { return "Samsung Internet" }
        if agent.contains("CriOS") || agent.contains("Chrome/") || agent.contains("Chromium/") { return "Chrome" }
        if agent.contains("Safari/") && agent.contains("Version/") { return "Safari" }
        if agent.contains("AppleWebKit/") && (agent.contains("iPhone") || agent.contains("iPad")) { return "Safari" }
        return nil
    }

    /// iPadOS asks for the desktop site and says Macintosh, so an iPad may show as a Mac.
    private static func systemName(_ agent: String) -> String? {
        if agent.contains("iPhone") { return "iPhone" }
        if agent.contains("iPad") { return "iPad" }
        if agent.contains("Android") { return "Android" }
        if agent.contains("CrOS") { return "ChromeOS" }
        if agent.contains("Macintosh") || agent.contains("Mac OS X") { return "Mac" }
        if agent.contains("Windows") { return "Windows" }
        if agent.contains("Linux") || agent.contains("X11") { return "Linux" }
        return nil
    }
}
