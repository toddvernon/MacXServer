import Foundation

// X Logical Font Description parser. Format from the X11 spec:
//
//   -FOUNDRY-FAMILY-WEIGHT-SLANT-SETWIDTH-ADD_STYLE-PIXEL_SIZE-POINT_SIZE
//   -RESOLUTION_X-RESOLUTION_Y-SPACING-AVERAGE_WIDTH-CHARSET_REGISTRY-CHARSET_ENCODING
//
// 14 fields, separated by '-'. Numeric fields can be '*' for "any". The leading
// '-' is the field separator (not a 0th field), so a fully-specified XLFD
// produces 14 components after the prefix.
//
// Example:
//   -misc-fixed-medium-r-semicondensed--13-120-75-75-c-60-iso8859-1
//
// (note empty addStyle between two consecutive dashes)
//
// We don't try to parse partial / wildcarded XLFDs here — that's a ListFonts
// pattern-matching concern. This struct represents a fully-decoded XLFD.

public struct XLFD: Equatable, Sendable {
    public var foundry: String
    public var family: String
    public var weight: String
    public var slant: String                // "r" / "i" / "o" / etc
    public var setwidth: String
    public var addStyle: String
    public var pixelSize: Int               // 0 if "*" or unspecified
    public var pointSize: Int               // tenths of a point; 0 if unspecified
    public var resolutionX: Int             // dpi; 0 if unspecified
    public var resolutionY: Int
    public var spacing: String              // "c" (charcell) / "m" (monospace) / "p" (proportional) / "*"
    public var averageWidth: Int            // tenths of a pixel; 0 if unspecified
    public var charsetRegistry: String
    public var charsetEncoding: String

    public init(
        foundry: String = "*", family: String = "*", weight: String = "*",
        slant: String = "*", setwidth: String = "*", addStyle: String = "",
        pixelSize: Int = 0, pointSize: Int = 0,
        resolutionX: Int = 0, resolutionY: Int = 0,
        spacing: String = "*", averageWidth: Int = 0,
        charsetRegistry: String = "*", charsetEncoding: String = "*"
    ) {
        self.foundry = foundry
        self.family = family
        self.weight = weight
        self.slant = slant
        self.setwidth = setwidth
        self.addStyle = addStyle
        self.pixelSize = pixelSize
        self.pointSize = pointSize
        self.resolutionX = resolutionX
        self.resolutionY = resolutionY
        self.spacing = spacing
        self.averageWidth = averageWidth
        self.charsetRegistry = charsetRegistry
        self.charsetEncoding = charsetEncoding
    }

    /// Parse a full XLFD string. Returns nil if it doesn't have the expected
    /// 14 fields with leading '-'. Numeric fields containing '*' or empty
    /// strings parse to 0. Tolerant of '-' inside families like "new century
    /// schoolbook" — we don't have any such families with internal dashes
    /// in the substitution table, so a strict 14-field split is fine.
    public static func parse(_ s: String) -> XLFD? {
        guard s.hasPrefix("-") else { return nil }
        let body = String(s.dropFirst())
        let parts = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 14 else { return nil }

        return XLFD(
            foundry: parts[0], family: parts[1], weight: parts[2],
            slant: parts[3], setwidth: parts[4], addStyle: parts[5],
            pixelSize: numericField(parts[6]),
            pointSize: numericField(parts[7]),
            resolutionX: numericField(parts[8]),
            resolutionY: numericField(parts[9]),
            spacing: parts[10],
            averageWidth: numericField(parts[11]),
            charsetRegistry: parts[12],
            charsetEncoding: parts[13]
        )
    }

    /// Format back to the canonical 14-field string. Numeric zeros become
    /// '*'. Round-trips with `parse` for sane inputs.
    public func format() -> String {
        func num(_ n: Int) -> String { n == 0 ? "*" : String(n) }
        return "-\(foundry)-\(family)-\(weight)-\(slant)-\(setwidth)-\(addStyle)-\(num(pixelSize))-\(num(pointSize))-\(num(resolutionX))-\(num(resolutionY))-\(spacing)-\(num(averageWidth))-\(charsetRegistry)-\(charsetEncoding)"
    }

    private static func numericField(_ s: String) -> Int {
        if s == "*" || s.isEmpty { return 0 }
        return Int(s) ?? 0
    }
}
