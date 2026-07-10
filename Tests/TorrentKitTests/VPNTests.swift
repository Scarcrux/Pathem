import Foundation
import Testing

@testable import TorrentKit

#if canImport(Network)
    @Suite struct VPNMonitorTests {
        typealias Addr = VPNMonitor.Addr

        @Test func classifiesRealTunnelAndRejectsSystemUtuns() {
            // Mirrors a real Mac: utun0..6 carry only an IPv6 link-local address (system tunnels for
            // Continuity / iCloud Private Relay), utun7 is a live Tailscale tunnel with a routable
            // CGNAT address, en0/en9 are physical. Only utun7 is a VPN.
            let addrs: [Addr] = [
                .init(name: "lo0", isUp: true, isPointToPoint: false, isRoutable: false),
                .init(name: "en0", isUp: true, isPointToPoint: false, isRoutable: true),
                .init(name: "en9", isUp: true, isPointToPoint: false, isRoutable: true),
                .init(name: "utun0", isUp: true, isPointToPoint: true, isRoutable: false),  // fe80:: only
                .init(name: "utun3", isUp: true, isPointToPoint: true, isRoutable: false),
                .init(name: "utun7", isUp: true, isPointToPoint: true, isRoutable: false),  // its fe80::
                .init(name: "utun7", isUp: true, isPointToPoint: true, isRoutable: true),   // 100.100.32.62
            ]
            #expect(VPNMonitor.vpnInterfaces(from: addrs) == ["utun7"])
        }

        @Test func requiresPointToPointUpAndRoutable() {
            // VPN-named but not point-to-point, or down, or link-local-only -> not a tunnel.
            #expect(VPNMonitor.vpnInterfaces(from: [
                .init(name: "utun2", isUp: true, isPointToPoint: false, isRoutable: true)]).isEmpty)
            #expect(VPNMonitor.vpnInterfaces(from: [
                .init(name: "utun2", isUp: false, isPointToPoint: true, isRoutable: true)]).isEmpty)
            #expect(VPNMonitor.vpnInterfaces(from: [
                .init(name: "utun2", isUp: true, isPointToPoint: true, isRoutable: false)]).isEmpty)
            // A real PPP/IPsec tunnel is recognized.
            #expect(VPNMonitor.vpnInterfaces(from: [
                .init(name: "ppp0", isUp: true, isPointToPoint: true, isRoutable: true)]) == ["ppp0"])
        }

        @Test func classifiesNamesAndAddresses() {
            #expect(VPNMonitor.isVPNName("utun7"))
            #expect(VPNMonitor.isVPNName("ppp0"))
            #expect(VPNMonitor.isVPNName("ipsec0"))
            #expect(!VPNMonitor.isVPNName("en0"))
            #expect(!VPNMonitor.isVPNName("bridge100"))
            #expect(VPNMonitor.isLinkLocalOrLoopback("fe80::1%utun0"))
            #expect(VPNMonitor.isLinkLocalOrLoopback("127.0.0.1"))
            #expect(VPNMonitor.isLinkLocalOrLoopback("169.254.1.1"))
            #expect(VPNMonitor.isLinkLocalOrLoopback("::1"))
            #expect(!VPNMonitor.isLinkLocalOrLoopback("100.100.32.62"))
            #expect(!VPNMonitor.isLinkLocalOrLoopback("192.168.1.5"))
        }

        @Test func enumerateReturnsHostInterfaces() {
            // Live, but structural only (VPN presence is environment-dependent): the host always has
            // loopback, and classifying real interfaces must not crash.
            let addrs = VPNMonitor.enumerate()
            #expect(addrs.contains { $0.name == "lo0" })
            _ = VPNMonitor.vpnInterfaces(from: addrs)
        }

        @Test func activeVPNNameIsATunnelOrNil() async {
            // Non-flaky live check: whatever the host's VPN state, the detected name (if any) must be
            // a real tunnel name -- never a physical interface.
            let name = await VPNMonitor().activeVPNName()
            if let name { #expect(VPNMonitor.isVPNName(name)) }
        }
    }
#endif
