import Framer

// BIG-REQUESTS extension dumper.
//
// One opcode (Enable). After the client sends Enable and gets the reply
// with the new max-request-size, subsequent core requests may use the
// extended 32-bit length-prefix format (length=0 in the 16-bit slot,
// real length in bytes 4-7). This dumper only reports the Enable
// request itself; honoring the extended length-prefix in the framer's
// core decoder is a separate concern (the prefix has the same shape
// regardless of which client emitted it).

public enum BigRequestsDumper: ExtensionDumper {
    public static let extensionName = "BIG-REQUESTS"
    public static let eventCount = 0

    public static func formatRequest(bytes: [UInt8], byteOrder: ByteOrder) -> String? {
        guard bytes.count >= 2 else { return nil }
        switch bytes[1] {
        case BigReqMinor.enable:
            return "BigReqEnable"
        default:
            return nil
        }
    }

    public static func formatEvent(bytes: [UInt8], firstEvent: UInt8, byteOrder: ByteOrder) -> String? {
        nil   // no events
    }
}
