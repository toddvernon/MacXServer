import XCTest
@testable import SwiftXCaptureCore

final class StartupHintTests: XCTestCase {

    func testDisplayNumberFromPort() {
        XCTAssertEqual(StartupHint.displayNumber(forPort: 6000), 0)
        XCTAssertEqual(StartupHint.displayNumber(forPort: 6001), 1)
        XCTAssertEqual(StartupHint.displayNumber(forPort: 6010), 10)
        XCTAssertNil(StartupHint.displayNumber(forPort: 5999))
        XCTAssertNil(StartupHint.displayNumber(forPort: 80))
    }

    func testDisplayHintListsNonLoopbackInterfaces() {
        let interfaces = [
            NetworkInterface(name: "lo0", address: "127.0.0.1", isLoopback: true),
            NetworkInterface(name: "en0", address: "192.168.1.50", isLoopback: false),
            NetworkInterface(name: "en1", address: "10.0.0.5", isLoopback: false),
        ]
        let hint = StartupHint.displayHint(forListenPort: 6000, interfaces: interfaces)
        XCTAssertTrue(hint.contains("192.168.1.50:0"))
        XCTAssertTrue(hint.contains("10.0.0.5:0"))
        XCTAssertFalse(hint.contains("127.0.0.1"))
        XCTAssertTrue(hint.contains("en0"))
        XCTAssertTrue(hint.contains("en1"))
    }

    func testDisplayHintUsesPortDerivedDisplayNumber() {
        let interfaces = [NetworkInterface(name: "en0", address: "10.0.0.1", isLoopback: false)]
        let hint = StartupHint.displayHint(forListenPort: 6005, interfaces: interfaces)
        XCTAssertTrue(hint.contains("10.0.0.1:5"))
    }

    func testDisplayHintWhenOnlyLoopbackPresent() {
        let interfaces = [NetworkInterface(name: "lo0", address: "127.0.0.1", isLoopback: true)]
        let hint = StartupHint.displayHint(forListenPort: 6000, interfaces: interfaces)
        XCTAssertTrue(hint.contains("no non-loopback"))
    }

    func testDisplayHintWhenNoInterfaces() {
        let hint = StartupHint.displayHint(forListenPort: 6000, interfaces: [])
        XCTAssertTrue(hint.contains("no non-loopback"))
    }

    func testDisplayHintNonStandardPort() {
        let interfaces = [NetworkInterface(name: "en0", address: "10.0.0.1", isLoopback: false)]
        let hint = StartupHint.displayHint(forListenPort: 80, interfaces: interfaces)
        XCTAssertTrue(hint.contains("non-standard"))
    }

    func testEnumerateIPv4InterfacesReturnsLoopback() {
        // Live system call. Every Mac has lo0 (127.0.0.1) up.
        let interfaces = enumerateIPv4Interfaces()
        XCTAssertTrue(interfaces.contains { $0.address == "127.0.0.1" && $0.isLoopback })
    }
}
