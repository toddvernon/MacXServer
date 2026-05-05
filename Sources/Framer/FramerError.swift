public enum FramerError: Error, Equatable, Sendable {
    case truncated(needed: Int, available: Int)
    case invalidByteOrder(UInt8)
    case invalidStatus(UInt8)
    case invalidEnum(name: String, value: UInt32)
    case invalidOpcode(expected: UInt8, got: UInt8)
}
