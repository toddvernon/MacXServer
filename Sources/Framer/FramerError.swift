public enum FramerError: Error, Equatable, Sendable {
    case truncated(needed: Int, available: Int)
    case invalidByteOrder(UInt8)
    case invalidStatus(UInt8)
    case invalidEnum(name: String, value: UInt32)
    case invalidOpcode(expected: UInt8, got: UInt8)
    /// A well-framed request whose body is internally inconsistent — e.g. a
    /// value-list request whose length word disagrees with its value-mask
    /// popcount, or a keysym request with a zero per-keycode count. These are
    /// caught by the request-loop and answered with BadLength/BadValue on the
    /// wire. This case exists so a MALFORMED CLIENT REQUEST becomes a
    /// throwable error rather than tripping an initializer precondition, which
    /// would trap the whole server process. See CODE_AUDIT_2026-07 §0.
    case malformedRequest(name: String)
}

/// Validate a value-list request body BEFORE its byte count reaches a request
/// initializer whose precondition would trap on a mismatch. Guards the two
/// ways a hostile/short length word breaks: a negative/misaligned byte count
/// (which would trap `readBytes`) and a slot count that disagrees with the
/// value-mask popcount (which would trap the init). Well-formed requests
/// (length word derived from the popcount, as every real client and our own
/// encoder produce) pass unchanged.
public func validateValueList(byteCount: Int, maskPopcount: Int,
                              request: String) throws {
    guard byteCount >= 0, byteCount % 4 == 0,
          byteCount / 4 == maskPopcount else {
        throw FramerError.malformedRequest(name: request)
    }
}
