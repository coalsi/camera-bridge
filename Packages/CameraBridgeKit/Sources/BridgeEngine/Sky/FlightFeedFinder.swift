import CameraAdapters
import Foundation

/// Finds the flight feeds on the box's own network, for Settings to offer ("Find a feed").
///
/// **It looks only at the LAN, and only a little.** The addresses it asks are the box's neighbours: the hosts in its own neighbour (ARP)
/// table, so ones on a network the box is attached to and has already talked to. It builds no address of its own, it never counts upwards
/// from one, and it takes only private addresses (10/8, 172.16/12, 192.168/16), at most `maximumHosts` of them. For each it asks the four
/// places a feed usually is (`paths`: tar1090, dump1090-fa and PiAware's SkyAware on port 80, and dump1090 on port 8080), one request each,
/// `parallel` at a time, each with `timeout` and a bounded answer; a redirect is never followed. Nothing is written down or logged: not the
/// addresses, not the answers.
enum FlightFeedFinder {
    /// Where a feed is served, after a host: a path on port 80, or a port and a path.
    static let paths = ["/tar1090/data/aircraft.json", "/dump1090-fa/data/aircraft.json", "/skyaware/data/aircraft.json", ":8080/data/aircraft.json"]
    static let maximumHosts = 64
    static let parallel = 8
    static let timeout: Duration = .milliseconds(1_500)

    /// The addresses worth asking, from the text of the neighbour table: the first `maximumHosts` complete entries with a private IPv4 address,
    /// each with every one of `paths`, in the table's order.
    static func candidates(neighbours: String) -> [URL] {
        var hosts: [String] = []
        for entry in NeighborTable.ipv4s(in: neighbours) {
            if hosts.count >= maximumHosts { break }
            if let host = privateAddress(entry) { hosts.append(host) }
        }
        return hosts.flatMap { host in paths.compactMap { URL(string: "http://\(host)\($0)") } }
    }

    /// The addresses among `candidates(neighbours:)` that answer with a flight feed (an empty sky counts), in their order. A cancelled caller
    /// gets what was found by then.
    static func find(http: any SkyHTTP, neighbours: String) async -> [URL] {
        let urls = candidates(neighbours: neighbours)
        guard !urls.isEmpty else { return [] }
        var found = [Bool](repeating: false, count: urls.count)
        await withTaskGroup(of: (Int, Bool).self) { group in
            var next = 0
            func startNext() {
                guard next < urls.count, !Task.isCancelled else { return }
                let index = next
                next += 1
                group.addTask { (index, await isFeed(at: urls[index], http: http)) }
            }
            for _ in 0..<min(parallel, urls.count) { startNext() }
            for await (index, answered) in group {
                found[index] = answered
                startNext()
            }
        }
        return zip(urls, found).filter(\.1).map(\.0)
    }

    private static func isFeed(at url: URL, http: any SkyHTTP) async -> Bool {
        guard let answer = try? await http.get(url, timeout: timeout, maximumBytes: AircraftFeedParser.maximumBytes),
              (200..<300).contains(answer.status) else { return false }
        return AircraftFeedParser.isFeed(answer.body)
    }

    /// `text` as a plain dotted IPv4 address (four numbers of 0 to 255 written without leading zeros, which some resolvers read as octal) in a
    /// private range, or nil.
    static func privateAddress(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.utf8.allSatisfy({ (0x30...0x39).contains($0) }), part == "0" || part.first != "0",
                  let value = Int(part), value <= 255 else { return nil }
            octets.append(value)
        }
        let isPrivate = octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)
        return isPrivate ? octets.map(String.init).joined(separator: ".") : nil
    }
}
