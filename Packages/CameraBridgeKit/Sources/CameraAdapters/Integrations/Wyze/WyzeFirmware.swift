import Foundation

/// Which Wyze firmware has the official RTSP server (turned on in the Wyze app: camera settings > Advanced > RTSP; `rtsp://admin:…@<ip>/stream0`
/// main, `/stream1` sub, port 554). From Wyze's release notes (October 2026): Cam v4 4.52.17.x, Cam v3 4.36.16.5654 and Pan v3
/// 4.50.16.5654 onwards. The v3 Pro and other models are not listed; the old RTSP beta firmware (4.19.x, 4.28.x, 4.61.x) is not counted.
public enum WyzeFirmware {
    /// Product model → the first firmware with RTSP.
    public static let rtspMinimum: [String: String] = [
        "HL_CAM4": "4.52.17.0",
        "WYZE_CAKP2JFUS": "4.36.16.5654",
        "HL_PAN3": "4.50.16.5654",
    ]

    /// Whether `firmware` (dotted numbers) is at least the model's first RTSP firmware. Unknown models and unreadable versions: false.
    public static func hasRTSP(model: String, firmware: String) -> Bool {
        guard let minimum = rtspMinimum[model.uppercased()] else { return false }
        return isAtLeast(firmware, minimum)
    }

    /// Compares dotted versions part by part as numbers (`4.52.17.19` > `4.52.9.5332`); missing parts count as 0. A part that is not a
    /// number makes the version unreadable (false).
    public static func isAtLeast(_ version: String, _ minimum: String) -> Bool {
        guard let have = parts(version), let need = parts(minimum) else { return false }
        for index in 0..<max(have.count, need.count) {
            let a = index < have.count ? have[index] : 0
            let b = index < need.count ? need[index] : 0
            if a != b { return a > b }
        }
        return true
    }

    static func parts(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 else { return nil }
        var result: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.utf8.count <= 9, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }
}
