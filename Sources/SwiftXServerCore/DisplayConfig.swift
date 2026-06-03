import Foundation
import AppKit

// Picks a logical-root size + scale factor that fits the connected
// display per `SERVER_RESOLUTION_SCALING_AND_FONTS.md`. Goal: highest
// scale (preferring 3x) with logical width in 960..1280 that fits without
// overflowing native pixel dimensions. ~90 DPI reported regardless, so
// Sun-era Xt/Motif font auto-sizing stays sane.
//
// As of 2026-05-08 the picker still hands back integer scales, but the
// type is `Double` so callers can override with a fractional scale (e.g.
// 2.5x) when they want the iTerm2-weight stroke at 3x physical size.
// Phase 1's invariant of clean N×N device-pixel blocks is relaxed for
// fractional scales — cell boundaries pick up AA edges between cells —
// see SERVER_RESOLUTION_SCALING_AND_FONTS.md "Plane 1: Geometry".
//
// Algorithm is pure data in/out so it's testable without a display.

public struct DisplayConfig: Equatable, Sendable {
    /// X-protocol "screen size" in logical pixels. This is what clients see.
    public let logicalWidth: Int
    public let logicalHeight: Int
    /// Multiplier from logical pixels to device (physical) pixels. Integer
    /// is preferred (clean N×N blocks); fractional values like 2.5 are
    /// accepted for callers that want a non-preset scale.
    public let scale: Double
    /// Native pixel dimensions of the display we picked for. Stored so the
    /// caller can sanity-check. Not sent to clients.
    public let nativePixelWidth: Int
    public let nativePixelHeight: Int
    /// Reported physical size in millimetres, derived so reported DPI ≈ 90
    /// regardless of actual display physical size. Sun-era apps use this to
    /// auto-size fonts; reporting actual macOS DPI (218 / 264) would make
    /// every Xt/Motif app pick comically large fonts.
    public let widthMm: Int
    public let heightMm: Int

    /// Backing-store dimensions: how many device pixels we allocate. Round
    /// to integer because CGBitmapContext takes Int dimensions; at integer
    /// scale this is exact, at fractional scale we lose at most 0.5 device
    /// pixel of canvas, which is invisible.
    public var deviceWidth: Int { Int((Double(logicalWidth) * scale).rounded()) }
    public var deviceHeight: Int { Int((Double(logicalHeight) * scale).rounded()) }

    public init(
        logicalWidth: Int, logicalHeight: Int, scale: Double,
        nativePixelWidth: Int, nativePixelHeight: Int
    ) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.scale = scale
        self.nativePixelWidth = nativePixelWidth
        self.nativePixelHeight = nativePixelHeight
        // 90 DPI target: mm = pixels × 25.4 / 90.
        self.widthMm = Int((Double(logicalWidth) * 25.4 / 90.0).rounded())
        self.heightMm = Int((Double(logicalHeight) * 25.4 / 90.0).rounded())
    }

    // MARK: - Picker

    /// Candidate (logicalWidth, logicalHeight) pairs in preference order.
    /// Matches the preset table in `SERVER_RESOLUTION_SCALING_AND_FONTS.md`.
    /// 1280×900 is the "ideal" — Sun-authentic vertical, room for two 80-col
    /// terminals side by side; 1280×720 used when 16:9 height is what fits;
    /// progressively smaller for compact Retina laptops; 960×540 for 1080p.
    private static let logicalCandidates: [(width: Int, height: Int)] = [
        (1280, 900),
        (1280, 720),
        (1152, 720),
        (1008, 648),
        (960, 540),
    ]

    /// Try integer scales in this order. 3× is the sweet spot for current
    /// Retina displays; 2× is the fallback for 1080p externals; 4× isn't
    /// triggered by the algorithm because it never strictly fits where 3×
    /// doesn't (subset relationship), but Phase 2 may add explicit 4× as
    /// a user override on Pro Display XDR.
    private static let scaleCandidates: [Double] = [3, 2]

    /// Pick the best (logical, scale) for a display of `nativeWidth × nativeHeight`
    /// pixels. First (scale, logical) combination whose device dimensions
    /// don't exceed the native pixel dimensions wins. Falls back to scale=1
    /// at native dimensions if no preset fits (very small or unusual displays).
    ///
    /// `forcedScale` (if set) restricts the search to that scale only. See
    /// `SCALE_PICKER.md` for the design rationale. Used by `--scale 2`.
    public static func pick(nativeWidth: Int, nativeHeight: Int,
                            forcedScale: Double? = nil) -> DisplayConfig {
        let scales = forcedScale.map { [$0] } ?? scaleCandidates
        for scale in scales {
            for c in logicalCandidates {
                let dw = Int((Double(c.width) * scale).rounded())
                let dh = Int((Double(c.height) * scale).rounded())
                if dw <= nativeWidth && dh <= nativeHeight {
                    return DisplayConfig(
                        logicalWidth: c.width,
                        logicalHeight: c.height,
                        scale: scale,
                        nativePixelWidth: nativeWidth,
                        nativePixelHeight: nativeHeight
                    )
                }
            }
        }
        // Fallback for tiny / unusual displays: 1:1 with whatever's there.
        // (Also the path if `forcedScale` is set and no preset fits at that scale —
        // probably wrong but matches the existing "always return something" contract.)
        return DisplayConfig(
            logicalWidth: max(nativeWidth, 1),
            logicalHeight: max(nativeHeight, 1),
            scale: 1,
            nativePixelWidth: nativeWidth,
            nativePixelHeight: nativeHeight
        )
    }

    /// Inspect `NSScreen.main` and pick a config for the user's actual display.
    /// On a system with no main screen (very unusual on macOS), falls back
    /// to the Studio Display preset.
    @MainActor
    public static func forMainDisplay(forcedScale: Double? = nil) -> DisplayConfig {
        guard let screen = NSScreen.main else {
            return .studioDisplay
        }
        let backingScale = screen.backingScaleFactor
        let pointsFrame = screen.frame
        let pixelW = Int((pointsFrame.width * backingScale).rounded())
        let pixelH = Int((pointsFrame.height * backingScale).rounded())
        return pick(nativeWidth: pixelW, nativeHeight: pixelH, forcedScale: forcedScale)
    }

    // MARK: - Named presets

    /// Studio Display 27" 5K — the design-target display.
    public static let studioDisplay = DisplayConfig(
        logicalWidth: 1280, logicalHeight: 900, scale: 3,
        nativePixelWidth: 5120, nativePixelHeight: 2880
    )

    /// scale=1 preset for tests that assert on region values without
    /// caring about retina upscaling. Same logical dims as the studio
    /// display so screen-derived assertions stay valid.
    public static let scaleOne = DisplayConfig(
        logicalWidth: 1280, logicalHeight: 900, scale: 1,
        nativePixelWidth: 1280, nativePixelHeight: 900
    )
}
