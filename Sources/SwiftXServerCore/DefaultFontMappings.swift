import Foundation

// Seed content for ~/.swiftx-fonts on first launch. Mirrors the
// substitution table in SERVER_RESOLUTION_SCALING_AND_FONTS.md so the
// default behavior is identical to the previous hardcoded
// FontResolver.resolveFamily switch.
//
// Edited byte-for-byte once the file lives in the user's home; this
// constant is only re-consulted on first run and when the user clicks
// Revert to Defaults in the editor.

public enum DefaultFontMappings {

    public static let seedContent: String = """
    # swift-x font mappings — controls FontResolver's XLFD family substitution.
    #
    # Format per line:
    #   <xlfd-family>  ->  <mac-font-name>
    #
    # - The `->` separates the X family name from the Mac font. This supports
    #   multi-word X family names ("new century schoolbook") and multi-word
    #   Mac fonts ("Helvetica Neue") without ambiguity.
    # - Family names are case-insensitive; aliases share a Mac font by
    #   listing each one on its own line.
    # - Monospace vs proportional is derived from the Mac font itself
    #   (CTFontGetSymbolicTraits), not declared here. Monaco / Courier
    #   New / Andale Mono report monospace; Helvetica Neue / Times New
    #   Roman / Charter / Symbol don't.
    # - Two special keys hold the wildcard fallbacks for unknown families:
    #     *fallback-mono  ->  used for clients requesting spacing=c (charcell)
    #                         or spacing=m (monospace)
    #     *fallback-prop  ->  used for everything else (unknown spacing,
    #                         wildcards)
    #
    # Lines starting with # or ! are comments. Blank lines ignored.
    #
    # Changes apply to newly-launched X clients only; existing clients cache
    # font metrics at QueryFont time. Restart Motif/dt apps to see edits.

    # ── Monospaced families ──────────────────────────────────────────────────
    fixed                          ->  Monaco
    misc-fixed                     ->  Monaco
    courier                        ->  Courier New
    adobe-courier                  ->  Courier New
    lucidatypewriter               ->  Andale Mono
    b&h-lucidatypewriter           ->  Andale Mono
    terminal                       ->  Monaco
    vt100                          ->  Monaco
    screen                         ->  Monaco
    clean                          ->  Monaco
    schumacher-clean               ->  Monaco

    # ── Proportional families ────────────────────────────────────────────────
    helvetica                      ->  Helvetica Neue
    adobe-helvetica                ->  Helvetica Neue
    times                          ->  Times New Roman
    adobe-times                    ->  Times New Roman
    new century schoolbook         ->  Charter
    adobe-new century schoolbook   ->  Charter
    symbol                         ->  Symbol
    adobe-symbol                   ->  Symbol

    # ── Wildcard fallbacks ───────────────────────────────────────────────────
    *fallback-mono                 ->  Monaco
    *fallback-prop                 ->  Helvetica Neue
    """
}
