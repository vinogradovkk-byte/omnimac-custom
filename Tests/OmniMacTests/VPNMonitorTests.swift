import XCTest
@testable import OmniMac

final class VPNMonitorTests: XCTestCase {
    func testFindsFortiClientServiceInScutilList() {
        let list = """
        Available network connection services in the current set (*=enabled):
        * (Disconnected)   3F456E82-E215-4CE7-8E60-AA7CA7ED77A8 VPN (com.fortinet.forticlient.macos.vpn) "VPN" [VPN:com.fortinet.forticlient.macos.vpn]
        * (Connected)      11111111-2222-3333-4444-555555555555 Other (com.apple.vpn) "Other" [VPN:com.apple.vpn]
        """
        XCTAssertEqual(VPNMonitor.serviceID(inList: list), "3F456E82-E215-4CE7-8E60-AA7CA7ED77A8")
        XCTAssertNil(VPNMonitor.serviceID(inList: "Available network connection services in the current set (*=enabled):\n"))
    }

    func testParsesScutilStatus() {
        XCTAssertEqual(VPNMonitor.status(fromOutput: "Connected\nExtended Status <dictionary> {"), .connected)
        XCTAssertEqual(VPNMonitor.status(fromOutput: "Connecting\n"), .connecting)
        XCTAssertEqual(VPNMonitor.status(fromOutput: "Disconnecting"), .disconnecting)
        XCTAssertEqual(VPNMonitor.status(fromOutput: "Disconnected\n"), .disconnected)
        XCTAssertEqual(VPNMonitor.status(fromOutput: ""), .unavailable)
    }
}

final class MailLauncherTests: XCTestCase {
    func testReadsUnreadCountOnlyFromInboxLabel() {
        XCTAssertEqual(MailLauncher.unreadCount(inLabel: "Входящие; Непрочитанных сообщений: 8"), 8)
        XCTAssertEqual(MailLauncher.unreadCount(inLabel: "Входящие"), 0)
        XCTAssertEqual(MailLauncher.unreadCount(inLabel: "Inbox; Unread: 15"), 15)
        XCTAssertNil(MailLauncher.unreadCount(inLabel: "Удаленные; Непрочитанных сообщений: 1"))
        XCTAssertNil(MailLauncher.unreadCount(inLabel: "Черновики; Сообщений: 2"))
    }
}
