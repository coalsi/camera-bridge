import Testing
@testable import CameraAdapters

/// The box's neighbour table (Linux `/proc/net/arp`): the addresses of the hosts on its own network (the sky detector's feed finder looks only
/// at these).
@Suite struct NeighborTableTests {
    static let table = """
    IP address       HW type     Flags       HW address            Mask     Device
    192.168.77.1     0x1         0x2         a4:91:b1:00:11:22     *        enp1s0
    192.168.77.20    0x1         0x2         2c:aa:8e:00:00:20     *        enp1s0
    192.168.77.21    0x1         0x0         00:00:00:00:00:00     *        enp1s0
    192.168.77.22    0x1         0x0         2c:aa:8e:00:00:22     *        enp1s0
    192.168.77.23    0x1         0x6         2C:AA:8E:00:00:23     *        enp1s0
    192.168.77.255   0x1         0x6         ff:ff:ff:ff:ff:ff     *        enp1s0
    192.168.77.30    0x1         0x2         00:00:00:00:00:00     *        enp1s0
    fe80::1          0x1         0x2         2c:aa:8e:00:00:09     *        enp1s0
    8.8.8.8          0x1         0x2         2c:aa:8e:00:00:88     *        enp1s0
    192.168.77.20    0x1         0x2         2c:aa:8e:00:00:20     *        wlan0
    """

    @Test func listsTheCompleteEntries() {
        // In the table's order, each address once: the incomplete entries (flags 0x0, an all-zero MAC) and the broadcast entry are left out.
        // Addresses of any range are listed (choosing among them is the caller's); an IPv6 entry is not an IPv4 address.
        #expect(NeighborTable.ipv4s(in: Self.table) == ["192.168.77.1", "192.168.77.20", "192.168.77.23", "8.8.8.8"])
    }

    @Test func anEmptyOrOddTableListsNothing() {
        #expect(NeighborTable.ipv4s(in: "").isEmpty)
        #expect(NeighborTable.ipv4s(in: "IP address HW type Flags HW address Mask Device\n").isEmpty)
        #expect(NeighborTable.ipv4s(in: "not a table\n\n  \n999.1.1.1 0x1 0x2 aa:bb:cc:dd:ee:ff * eth0\n1.2.3 0x1 0x2 aa:bb:cc:dd:ee:ff * eth0").isEmpty)
        // Tabs and Windows line ends.
        #expect(NeighborTable.ipv4s(in: "192.168.77.5\t0x1\t0x2\taa:bb:cc:dd:ee:01\t*\teth0\r\n192.168.77.6 0x1 0x2 aa:bb:cc:dd:ee:02 * eth0\r\n")
                == ["192.168.77.5", "192.168.77.6"])
        // A short line, flags that are not hex, a MAC that is not one.
        #expect(NeighborTable.ipv4s(in: "192.168.77.5 0x1 0x2\n192.168.77.6 0x1 0xZZ aa:bb:cc:dd:ee:02 * eth0\n192.168.77.7 0x1 0x2 xx * eth0").isEmpty)
    }

    @Test func theCameraLookupStillSkipsTheSameEntries() {
        // `ipv4(forMAC:)` shares the line reading: the last complete entry of a MAC wins, an incomplete one is skipped.
        #expect(NeighborTable.ipv4(forMAC: "2caa8e000020", in: Self.table) == "192.168.77.20")
        #expect(NeighborTable.ipv4(forMAC: "2C-AA-8E-00-00-22", in: Self.table) == nil)
        #expect(NeighborTable.ipv4(forMAC: "2caa8e000023", in: Self.table) == "192.168.77.23")
    }
}
