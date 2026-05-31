#!/usr/bin/env bash
# Regenerate Sources/SwiftXCaptureCore/Keysyms.generated.swift from the X11R6
# keysymdef.h header in reference/. Run from the repo root.
#
# Dedupe rule: first name wins. keysymdef.h orders names canonical-first
# (e.g. XK_BackSpace before any alias), so first-wins gives us the right name.
set -euo pipefail
cd "$(dirname "$0")/.."

src="reference/X11R6/xc/include/keysymdef.h"
out="Sources/SwiftXCaptureCore/Keysyms.generated.swift"

[ -r "$src" ] || { echo "missing $src — make sure the reference symlink is in place" >&2; exit 1; }

today=$(date +%Y-%m-%d)

awk -v today="$today" 'BEGIN {
    print "// Generated from reference/X11R6/xc/include/keysymdef.h on " today "."
    print "// Do not edit by hand; regenerate with:"
    print "//   Tools/regen_keysyms.sh"
    print "//"
    n = 0
}
/^#define[[:space:]]+XK_[A-Za-z0-9_]+[[:space:]]+0x[0-9A-Fa-f]+/ {
    match($0, /XK_[A-Za-z0-9_]+/)
    name = substr($0, RSTART+3, RLENGTH-3)
    match($0, /0x[0-9A-Fa-f]+/)
    val = substr($0, RSTART, RLENGTH)
    if (!(val in seen)) {
        seen[val] = name
        order[n++] = val
    }
}
END {
    print "// " n " unique keysym values, first-name-wins on aliases."
    print ""
    print "/// Canonical X11 keysym names, indexed by keysym value (CARD32)."
    print "/// Decode-side only; the protocol carries the integer, this table"
    print "/// lifts it to a readable name for dumper output."
    print "public let xKeysymNames: [UInt32: String] = ["
    for (i = 0; i < n; i++) {
        v = order[i]
        printf("    %s: \"%s\",\n", v, seen[v])
    }
    print "]"
}' "$src" > "$out"

echo "wrote $out ($(grep -c '^    0x' "$out") entries)"
