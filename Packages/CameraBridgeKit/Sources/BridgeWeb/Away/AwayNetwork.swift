import Foundation

/// A global IPv6 address of the box, as the system marks it. Which one Away from home publishes is chosen in BridgeWeb (the stable one), so the
/// platform lists them all.
public struct AwayAddress: Sendable, Equatable {
    public var address: String
    public var prefixLength: Int
    /// Seconds the address stays preferred; `UInt32.max` is forever.
    public var preferredLifetime: UInt32
    public var isTemporary: Bool
    public var isDeprecated: Bool

    public init(address: String, prefixLength: Int, preferredLifetime: UInt32, isTemporary: Bool = false, isDeprecated: Bool = false) {
        self.address = address
        self.prefixLength = prefixLength
        self.preferredLifetime = preferredLifetime
        self.isTemporary = isTemporary
        self.isDeprecated = isDeprecated
    }
}

/// What Away from home needs to know about the box's network. Portable: the Linux box reads netlink behind it, tests use a fake.
public protocol AwayNetwork: Sendable {
    /// The global (2000::/3) addresses on the interface with the IPv6 default route, flagged as the kernel says.
    func globalIPv6() async -> [AwayAddress]
    /// Every network the LAN interfaces are on, "address/prefixLength" (for example "10.77.3.9/24"), IPv4 and IPv6.
    func ownPrefixes() async -> [String]
    /// A new subscription per read; one element whenever the addresses may have changed. It carries no address: the reader looks again.
    /// The subscription exists once the property has been read, so a change right after is not lost.
    var changes: AsyncStream<Void> { get }
}
