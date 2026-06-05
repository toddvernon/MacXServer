import Foundation

// Seed content for ~/.macxserver-fonts on first launch. Mirrors the
// substitution table in SERVER_RESOLUTION_SCALING_AND_FONTS.md so the
// default behavior is identical to the previous hardcoded
// FontResolver.resolveFamily switch.
//
// Edited byte-for-byte once the file lives in the user's home; this
// constant is only re-consulted on first run and when the user clicks
// Revert to Defaults in the editor.

public enum DefaultFontMappings {

    public static let seedContent: String = """
    # macXserver font mappings — controls FontResolver's XLFD family substitution.
    #
    # Format per line:
    #   <xlfd-family>  ->  <mac-font-name>  mono|prop
    #
    # - The `->` separates the X family name from the Mac font; the trailing
    #   `mono`/`prop` token separates the Mac font from its spacing kind.
    #   This supports multi-word X family names ("new century schoolbook")
    #   and multi-word Mac fonts ("Helvetica Neue") without ambiguity.
    # - Family names are case-insensitive; aliases share a Mac font by
    #   listing each one on its own line.
    # - Monospace vs proportional is derived from the Mac font itself
    #   (CTFontGetSymbolicTraits); the trailing `mono`/`prop` is
    #   informational. Monaco / Courier New / Andale Mono report
    #   monospace; Helvetica Neue / Times New Roman / Charter / Symbol
    #   don't.
    # - Two special keys hold the wildcard fallbacks:
    #     *fallback-mono  ->  used for clients requesting spacing=c (charcell)
    #                         or spacing=m (monospace) with an unknown family
    #     *fallback-prop  ->  used for everything else (unknown spacing,
    #                         wildcards)
    #
    # Lines starting with # or ! are comments. Blank lines ignored.
    #
    # Changes apply to newly-launched X clients only; existing clients cache
    # font metrics at QueryFont time. Restart Motif/dt apps to see edits.

    # ── Monospaced families ──────────────────────────────────────────────────
    fixed                          ->  Monaco             mono
    misc-fixed                     ->  Monaco             mono
    courier                        ->  Courier New        mono
    adobe-courier                  ->  Courier New        mono
    lucidatypewriter               ->  Andale Mono        mono
    b&h-lucidatypewriter           ->  Andale Mono        mono
    terminal                       ->  Monaco             mono
    vt100                          ->  Monaco             mono
    screen                         ->  Monaco             mono
    clean                          ->  Monaco             mono
    schumacher-clean               ->  Monaco             mono

    # ── Proportional families ────────────────────────────────────────────────
    helvetica                      ->  Helvetica Neue     prop
    adobe-helvetica                ->  Helvetica Neue     prop
    times                          ->  Times New Roman    prop
    adobe-times                    ->  Times New Roman    prop
    new century schoolbook         ->  Charter            prop
    adobe-new century schoolbook   ->  Charter            prop
    symbol                         ->  Symbol             prop
    adobe-symbol                   ->  Symbol             prop

    # ── Wildcard fallbacks ───────────────────────────────────────────────────
    *fallback-mono                 ->  Monaco             mono
    *fallback-prop                 ->  Helvetica Neue     prop
    """
}
