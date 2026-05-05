public enum CaptureFile {
    public static let magic: [UInt8] = [0x58, 0x54, 0x41, 0x50]   // "XTAP"
    public static let version: UInt8 = 1
    public static let headerSize: Int = 8
    public static let frameHeaderSize: Int = 13                   // dir(1) + ts(8) + len(4)
}
