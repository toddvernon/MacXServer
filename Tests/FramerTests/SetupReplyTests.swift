import XCTest
@testable import Framer

final class SetupReplyTests: XCTestCase {

    // MARK: - Refused

    private let refusedNoWayMSB: [UInt8] = [
        0x00, 0x06,             // status=0 (Failed), reason length=6
        0x00, 0x0B,             // protocol-major=11
        0x00, 0x00,             // protocol-minor=0
        0x00, 0x02,             // additional data = 2 4-byte units
        0x4E, 0x6F, 0x20, 0x77, 0x61, 0x79,   // "No way"
        0x00, 0x00,             // pad to 4-byte boundary
    ]

    func testEncodeRefused() {
        let r = SetupRefused(protocolMajor: 11, protocolMinor: 0, reason: Array("No way".utf8))
        XCTAssertEqual(r.encode(byteOrder: .msbFirst), refusedNoWayMSB)
    }

    func testDecodeRefused() throws {
        let reply = try SetupReply.decode(from: refusedNoWayMSB, byteOrder: .msbFirst)
        guard case .refused(let r) = reply else {
            XCTFail("expected refused, got \(reply)")
            return
        }
        XCTAssertEqual(r.protocolMajor, 11)
        XCTAssertEqual(r.protocolMinor, 0)
        XCTAssertEqual(String(decoding: r.reason, as: UTF8.self), "No way")
    }

    func testRoundTripRefused() throws {
        let original = SetupRefused(protocolMajor: 11, protocolMinor: 0, reason: Array("No way".utf8))
        let bytes = original.encode(byteOrder: .lsbFirst)
        let reply = try SetupReply.decode(from: bytes, byteOrder: .lsbFirst)
        guard case .refused(let r) = reply else {
            XCTFail("expected refused")
            return
        }
        XCTAssertEqual(original, r)
        XCTAssertEqual(bytes, r.encode(byteOrder: .lsbFirst))
    }

    // MARK: - Authenticate

    private let authTryAgainMSB: [UInt8] = [
        0x02,                                       // status=2 (Authenticate)
        0x00, 0x00, 0x00, 0x00, 0x00,               // 5 unused
        0x00, 0x03,                                 // additional data = 3 4-byte units
        0x54, 0x72, 0x79, 0x20, 0x61, 0x67, 0x61, 0x69, 0x6E,  // "Try again"
        0x00, 0x00, 0x00,                           // pad
    ]

    func testEncodeAuthenticate() {
        let a = SetupAuthenticate(reason: Array("Try again".utf8))
        XCTAssertEqual(a.encode(byteOrder: .msbFirst), authTryAgainMSB)
    }

    func testDecodeAuthenticate() throws {
        let reply = try SetupReply.decode(from: authTryAgainMSB, byteOrder: .msbFirst)
        guard case .authenticate(let a) = reply else {
            XCTFail("expected authenticate, got \(reply)")
            return
        }
        // Decoder returns reason + padding (the spec gives no way to recover n exactly).
        XCTAssertEqual(a.reason.count, 12)
        XCTAssertEqual(Array(a.reason.prefix(9)), Array("Try again".utf8))
        XCTAssertEqual(Array(a.reason.suffix(3)), [0x00, 0x00, 0x00])
    }

    func testRoundTripAuthenticate() throws {
        let original = SetupAuthenticate(reason: Array("Try again".utf8))
        let bytes = original.encode(byteOrder: .lsbFirst)
        let reply = try SetupReply.decode(from: bytes, byteOrder: .lsbFirst)
        guard case .authenticate(let a) = reply else {
            XCTFail("expected authenticate")
            return
        }
        XCTAssertEqual(bytes, a.encode(byteOrder: .lsbFirst))
    }

    // MARK: - Accepted

    // 132-byte accepted reply, MSB byte order.
    // 8-byte header + 124 bytes of additional data (lenIn4 = 31).
    // Configuration: 1 pixmap format, 1 screen, 1 depth on the screen, 1 visual
    // (PseudoColor 8-bit), vendor "Vintage Sun".
    private let acceptedSunStyleMSB: [UInt8] = [
        // ----- header -----
        0x01, 0x00,                 // status=1 (Success), unused
        0x00, 0x0B,                 // protocol-major = 11
        0x00, 0x00,                 // protocol-minor = 0
        0x00, 0x1F,                 // lenIn4 = 31

        // ----- fixed body (32 bytes) -----
        0x12, 0x34, 0x56, 0x78,     // releaseNumber
        0x00, 0x10, 0x00, 0x00,     // resourceIdBase
        0x00, 0x0F, 0xFF, 0xFF,     // resourceIdMask
        0x00, 0x00, 0x01, 0x00,     // motionBufferSize = 256
        0x00, 0x0B, 0xFF, 0xFF,     // vendorLen=11, maximumRequestLength=65535
        0x01, 0x01, 0x01, 0x01,     // nScreens=1, nFormats=1, imgByteOrder=MSB(1), bitOrder=Most(1)
        0x20, 0x20, 0x08, 0xFF,     // scanlineUnit=32, scanlinePad=32, minKey=8, maxKey=255
        0x00, 0x00, 0x00, 0x00,     // unused

        // ----- vendor (11 bytes + 1 byte pad) -----
        0x56, 0x69, 0x6E, 0x74, 0x61, 0x67, 0x65, 0x20,  // "Vintage "
        0x53, 0x75, 0x6E,                                 // "Sun"
        0x00,                                             // pad

        // ----- pixmap formats (1 × 8 bytes) -----
        0x08, 0x08, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00,   // depth=8, bpp=8, scanlinePad=32, 5 pad

        // ----- screens (1 × 72 bytes) -----
        0x10, 0x00, 0x00, 0x05,     // root
        0x10, 0x00, 0x00, 0x20,     // defaultColormap
        0x00, 0xFF, 0xFF, 0xFF,     // whitePixel
        0x00, 0x00, 0x00, 0x00,     // blackPixel
        0x00, 0x00, 0x00, 0x00,     // currentInputMasks
        0x05, 0x00,                 // widthInPixels = 1280
        0x04, 0x00,                 // heightInPixels = 1024
        0x01, 0x90,                 // widthInMillimeters = 400
        0x01, 0x2C,                 // heightInMillimeters = 300
        0x00, 0x01,                 // minInstalledMaps = 1
        0x00, 0x01,                 // maxInstalledMaps = 1
        0x00, 0x00, 0x00, 0x23,     // rootVisual
        0x00, 0x00, 0x08, 0x01,     // backingStores=Never, saveUnders=0, rootDepth=8, nDepths=1
        // depth (8 bytes header + 24 byte visual)
        0x08, 0x00,                 // depth=8, unused
        0x00, 0x01,                 // nVisuals=1
        0x00, 0x00, 0x00, 0x00,     // unused
        // visual (24 bytes)
        0x00, 0x00, 0x00, 0x23,     // visualId
        0x03, 0x08,                 // class=PseudoColor, bitsPerRgbValue=8
        0x01, 0x00,                 // colormapEntries=256
        0x00, 0x00, 0x00, 0x00,     // redMask
        0x00, 0x00, 0x00, 0x00,     // greenMask
        0x00, 0x00, 0x00, 0x00,     // blueMask
        0x00, 0x00, 0x00, 0x00,     // unused
    ]

    private func makeSunStyleAccepted() -> SetupAccepted {
        let visual = VisualType(
            visualId: 0x00000023,
            visualClass: .pseudoColor,
            bitsPerRgbValue: 8,
            colormapEntries: 256,
            redMask: 0,
            greenMask: 0,
            blueMask: 0
        )
        let depth = Depth(depth: 8, visuals: [visual])
        let screen = Screen(
            root: 0x10000005,
            defaultColormap: 0x10000020,
            whitePixel: 0x00FFFFFF,
            blackPixel: 0,
            currentInputMasks: 0,
            widthInPixels: 1280,
            heightInPixels: 1024,
            widthInMillimeters: 400,
            heightInMillimeters: 300,
            minInstalledMaps: 1,
            maxInstalledMaps: 1,
            rootVisual: 0x00000023,
            backingStores: .never,
            saveUnders: false,
            rootDepth: 8,
            allowedDepths: [depth]
        )
        let format = PixmapFormat(depth: 8, bitsPerPixel: 8, scanlinePad: 32)
        return SetupAccepted(
            protocolMajor: 11,
            protocolMinor: 0,
            releaseNumber: 0x12345678,
            resourceIdBase: 0x00100000,
            resourceIdMask: 0x000FFFFF,
            motionBufferSize: 256,
            maximumRequestLength: 65535,
            imageByteOrder: .msbFirst,
            bitmapFormatBitOrder: .mostSignificant,
            bitmapFormatScanlineUnit: 32,
            bitmapFormatScanlinePad: 32,
            minKeycode: 8,
            maxKeycode: 255,
            vendor: Array("Vintage Sun".utf8),
            pixmapFormats: [format],
            screens: [screen]
        )
    }

    func testEncodeAcceptedSunStyle() {
        let accepted = makeSunStyleAccepted()
        let bytes = accepted.encode(byteOrder: .msbFirst)
        XCTAssertEqual(bytes.count, 132)
        XCTAssertEqual(bytes, acceptedSunStyleMSB)
    }

    func testDecodeAcceptedSunStyle() throws {
        let reply = try SetupReply.decode(from: acceptedSunStyleMSB, byteOrder: .msbFirst)
        guard case .accepted(let a) = reply else {
            XCTFail("expected accepted")
            return
        }
        XCTAssertEqual(a, makeSunStyleAccepted())
    }

    func testRoundTripAcceptedLSB() throws {
        let original = makeSunStyleAccepted()
        let bytes = original.encode(byteOrder: .lsbFirst)
        let reply = try SetupReply.decode(from: bytes, byteOrder: .lsbFirst)
        guard case .accepted(let a) = reply else {
            XCTFail("expected accepted")
            return
        }
        XCTAssertEqual(original, a)
        XCTAssertEqual(bytes, a.encode(byteOrder: .lsbFirst))
    }

    func testRoundTripAcceptedMSB() throws {
        let original = makeSunStyleAccepted()
        let bytes = original.encode(byteOrder: .msbFirst)
        let reply = try SetupReply.decode(from: bytes, byteOrder: .msbFirst)
        guard case .accepted(let a) = reply else {
            XCTFail("expected accepted")
            return
        }
        XCTAssertEqual(original, a)
        XCTAssertEqual(bytes, a.encode(byteOrder: .msbFirst))
    }

    // MARK: - Dispatch

    func testDecodeRejectsInvalidStatus() {
        let bad: [UInt8] = [0x05, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertThrowsError(try SetupReply.decode(from: bad, byteOrder: .lsbFirst)) { error in
            XCTAssertEqual(error as? FramerError, .invalidStatus(0x05))
        }
    }
}
