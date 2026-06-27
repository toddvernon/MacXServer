#!/usr/bin/env bash
# Assembles the GPL/LGPL "complete corresponding source" bundle that
# GPL_SOURCE.md promises, ready to attach to a MacXServer GitHub release.
#
# What goes in (per GPLv2 section 3): the unmodified upstream QEMU source plus
# the scripts we use to control its compilation, so anyone can rebuild the
# qemu-system-sparc helper we ship. Build scripts come from the sibling
# SPARCplug checkout; the version + SHA are read from its qemu.lock so this
# script can never drift from the pinned baseline.
#
#   Tools/make-gpl-source-bundle.sh [output-dir]
#
# Output: macxserver-gpl-source-<qemuver>.tar.xz in output-dir (default: cwd).
# Downloads the upstream tarball (network) and fails hard if its SHA-256 does
# not match the pin. Re-runnable; caches the upstream tarball between runs.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X="$(cd "$HERE/.." && pwd)"
SPARC="$(cd "$X/.." && pwd)/SPARCplug"
OUTDIR="${1:-$PWD}"

LOCK="$SPARC/qemu.lock"
[ -f "$LOCK" ] || { echo "missing $LOCK (is the SPARCplug repo a sibling of X?)" >&2; exit 1; }

# Pull the pinned version, source URL and SHA-256 out of qemu.lock.
val() { grep -E "^$1[[:space:]]*=" "$LOCK" | head -1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//'; }
QEMU_VER="$(val version)"
QEMU_URL="$(val source)"
QEMU_SHA="$(val sha256)"
[ -n "$QEMU_VER" ] && [ -n "$QEMU_URL" ] && [ -n "$QEMU_SHA" ] || { echo "could not parse version/source/sha256 from $LOCK" >&2; exit 1; }

TARBALL="qemu-${QEMU_VER}.tar.xz"
CACHE="$X/.build/gpl-source-cache"
mkdir -p "$CACHE"

echo "==> QEMU $QEMU_VER  (sha256 $QEMU_SHA)"

# Download the upstream tarball if we don't already have a SHA-matching copy.
verify() { shasum -a 256 "$1" | awk '{print $1}'; }
if [ -f "$CACHE/$TARBALL" ] && [ "$(verify "$CACHE/$TARBALL")" = "$QEMU_SHA" ]; then
    echo "==> using cached $TARBALL"
else
    echo "==> downloading $QEMU_URL"
    curl -fSL "$QEMU_URL" -o "$CACHE/$TARBALL"
    got="$(verify "$CACHE/$TARBALL")"
    if [ "$got" != "$QEMU_SHA" ]; then
        echo "SHA-256 MISMATCH for $TARBALL" >&2
        echo "  expected $QEMU_SHA" >&2
        echo "  got      $got" >&2
        exit 1
    fi
    echo "==> SHA-256 verified"
fi

# Stage the bundle.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
BNAME="macxserver-gpl-source-${QEMU_VER}"
ROOT="$STAGE/$BNAME"
mkdir -p "$ROOT/build-scripts"

cp "$CACHE/$TARBALL" "$ROOT/"
cp "$SPARC/build-qemu.sh" "$ROOT/build-scripts/"
cp "$LOCK" "$ROOT/build-scripts/"
cp "$X/GPL_SOURCE.md" "$ROOT/"

cat > "$ROOT/README.txt" <<EOF
Complete corresponding source for the GPL/LGPL components MacXServer bundles.
See GPL_SOURCE.md for the full statement. This bundle contains:

  $TARBALL
      The QEMU $QEMU_VER source, byte-identical to the upstream release.
      Verify:  shasum -a 256 $TARBALL
      Expect:  $QEMU_SHA

  build-scripts/build-qemu.sh
      The script that configures and compiles the SPARC-only qemu-system-sparc
      helper we ship (all configure flags are inline in this script).

  build-scripts/qemu.lock
      The pin: upstream version, source URL, SHA-256, and the one pruning we
      apply (roms/, firmware source for non-SPARC targets we never build).

To rebuild: extract $TARBALL, rename the directory to qemu/, remove qemu/roms/,
then run build-qemu.sh from a checkout laid out as in qemu.lock.

OpenBIOS (GPLv2): the openbios-sparc32 firmware blob we ship is the prebuilt
one from QEMU's pc-bios set; we do not build it. Its source is the OpenBIOS
project, https://github.com/openbios/openbios .

GLib (LGPL-2.1): linked dynamically and relinked into the app bundle unmodified
at packaging time. The corresponding upstream version can be replaced; relink
is a standard install_name_tool re-point of the bundled dylib.

Questions: todd@toddvernon.com
EOF

# Produce the bundle.
mkdir -p "$OUTDIR"
OUT="$(cd "$OUTDIR" && pwd)/${BNAME}.tar.xz"
tar -C "$STAGE" -cJf "$OUT" "$BNAME"

echo "==> wrote $OUT"
echo "    $(du -h "$OUT" | awk '{print $1}')  --  attach this to the MacXServer release"
