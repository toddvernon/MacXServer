#!/bin/bash
# gatekeeper-probe.sh
#
# Capture macOS Gatekeeper / quarantine state of a MacXServer.app, so we
# can disambiguate WHY Safari downloads launch cleanly while Chrome
# downloads trigger the "could not verify ... is free of malware" dialog
# on the same Mac.
#
# Hypotheses we want to settle (see GATEKEEPER_BROWSER_FINDINGS.md):
#   1. Quarantine xattr flag bits differ between browsers (0083 vs 0081).
#   2. LSQuarantineTypeNumber differs (Sandboxed vs WebDownload).
#   3. App Translocation happens on one path but not the other.
#   4. codesign / spctl / stapler all stay healthy on both paths.
#
# Usage:
#   ./gatekeeper-probe.sh <label> <path-to-MacXServer.app>
#
#   label: safari | chrome | edge | firefox | <whatever>
#   e.g.:  ./gatekeeper-probe.sh safari ~/Downloads/MacXServer.app
#
# Output: text file in the current dir named
#         gatekeeper-probe-<label>-<timestamp>.txt
# plus the same content echoed to the terminal.
#
# Recommended test flow on a Mac that has never run MacXServer:
#   1. Open Safari, download MacXServer.zip from macxserver.com (let
#      "Open safe files after downloading" do its thing, default ON).
#      Drag MacXServer.app to ~/Downloads or /Applications.
#   2. ./gatekeeper-probe.sh safari /path/to/MacXServer.app
#   3. Double-click MacXServer.app from Finder. Note the dialog (or
#      lack of one). If it launches, re-run the script to capture the
#      running-process path (translocation check).
#   4. Quit + Move to Trash. Empty Trash (so LaunchServices forgets).
#   5. Open Chrome, download MacXServer.zip from macxserver.com.
#      Double-click the .zip in Finder to extract via Archive Utility.
#      Drag MacXServer.app to ~/Downloads or /Applications.
#   6. ./gatekeeper-probe.sh chrome /path/to/MacXServer.app
#   7. Double-click. Note the dialog.
#   8. Compare the two output files.

set -u

if [ "$#" -lt 2 ]; then
  cat <<EOF >&2
Usage: $0 <label> <path-to-MacXServer.app>

  label: safari | chrome | edge | firefox | <whatever>
  e.g.:  $0 safari ~/Downloads/MacXServer.app

See header comment in $0 for full test flow.
EOF
  exit 64
fi

LABEL="$1"
APP="$2"

if [ ! -d "$APP" ]; then
  echo "Not found or not a directory: $APP" >&2
  exit 1
fi

# Normalize: absolute path, no trailing slash.
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

TS=$(date +%Y%m%d-%H%M%S)
OUT="gatekeeper-probe-${LABEL}-${TS}.txt"

QDB="$HOME/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"

# Run a probe section: prints a heading and the output of a command.
# Captures both stdout and stderr; never fails the script if the command
# errors (we want the report even on partial data).
section() {
  local title="$1"
  shift
  echo
  echo "=== $title ==="
  "$@" 2>&1 || echo "(command exited non-zero: $?)"
}

{
  echo "================================================================"
  echo "gatekeeper-probe"
  echo "label:      $LABEL"
  echo "timestamp:  $TS"
  echo "app path:   $APP"
  echo "host:       $(hostname)"
  echo "user:       $(whoami)"
  echo "================================================================"

  section "sw_vers (exact macOS version)" \
    sw_vers

  section "app file metadata" \
    stat -f 'mode=%Sp size=%z mtime=%Sm uid=%u gid=%g name=%N' "$APP"

  section "realpath" \
    /usr/bin/python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$APP"

  section "xattr -l (all extended attributes)" \
    xattr -l "$APP"

  section "xattr -p com.apple.quarantine" \
    xattr -p com.apple.quarantine "$APP"
  cat <<'EOF'
  Format: flags;timestamp;AgentName;UUID
  Flag bits (per Howard Oakley, eclecticlight.co 2017/2020):
    0x0001 QTN_FLAG_DOWNLOAD     — file came from network
    0x0002 QTN_FLAG_SANDBOX      — downloaded by a sandboxed agent
    0x0040 QTN_FLAG_USER_APPROVED — first-run check passed / user approved
    0x0080                       — quarantine sentinel (always set)
  Expected: Safari path 0083 (sandbox+download+sentinel),
            Chrome path 0081 (download+sentinel, no sandbox bit).
  Either way, 0x40 (user-approved) is NOT set at download time.
EOF

  section "xattr -p com.apple.provenance (if present)" \
    xattr -p com.apple.provenance "$APP"

  section "codesign --verify --deep --strict -vvv" \
    codesign --verify --deep --strict -vvv "$APP"

  section "codesign -dvvv (identity + designated requirement)" \
    codesign -dvvv "$APP"

  section "spctl -a -vvv -t exec" \
    spctl -a -vvv -t exec "$APP"

  section "stapler validate" \
    xcrun stapler validate "$APP"

  section "last 10 LSQuarantine events (whole machine)"
  if [ -r "$QDB" ]; then
    sqlite3 "$QDB" <<SQL 2>&1
.headers on
.mode column
SELECT
  LSQuarantineEventIdentifier,
  datetime(LSQuarantineTimeStamp + 978307200, 'unixepoch', 'localtime') AS ts_local,
  LSQuarantineAgentName,
  LSQuarantineTypeNumber,
  substr(LSQuarantineDataURLString, 1, 60) AS data_url_60,
  substr(LSQuarantineOriginURLString, 1, 60) AS origin_url_60
FROM LSQuarantineEvent
ORDER BY LSQuarantineTimeStamp DESC
LIMIT 10;
SQL
  else
    echo "(cannot read $QDB)"
  fi
  cat <<'EOF'
  LSQuarantineTypeNumber meanings (from LaunchServices.h enum):
    0 LSQuarantineTypeWebDownload      — browser download
    1 LSQuarantineTypeOtherDownload    — other download
    2 LSQuarantineTypeEmailAttachment
    3 LSQuarantineTypeInstantMessageAttachment
    4 LSQuarantineTypeCalendarEventAttachment
    5 LSQuarantineTypeOtherAttachment
    6 LSQuarantineTypeSandboxed        — written by a sandboxed agent
  Expected: Safari path -> 6 (Sandboxed) or 0 (WebDownload),
            Chrome path -> 0 (WebDownload).
EOF

  section "currently running MacXServer processes (translocation check)" \
    bash -c "ps auxww | grep -i MacXServer | grep -v grep"
  cat <<'EOF'
  If a launch path above starts with /private/var/folders/, the app
  was translocated. Translocation typically fires on the first launch
  of a quarantined app from a non-user-moved location.
EOF

  echo
  echo "================================================================"
  echo "Manual observations to record (write below this line):"
  echo "================================================================"
  echo "Browser used:       $LABEL"
  echo "Download URL:       (paste)"
  echo "Did Safari auto-extract the .zip? (Safari only): "
  echo "Did the app launch on double-click?     yes / no"
  echo "If no, what dialog appeared (verbatim):"
  echo "   "
  echo "Buttons in the dialog (verbatim):"
  echo "   "
  echo "Did System Settings > Privacy & Security show an Open Anyway"
  echo "button for MacXServer after clicking Done?   yes / no"
  echo
} | tee "$OUT"

echo
echo "Wrote: $OUT"
echo
echo "Next:"
echo "  1. Double-click $APP from Finder. Record what happens in $OUT."
echo "  2. If it launched, re-run this script to capture the running"
echo "     process path (the 'currently running' section will show it)."
echo "  3. When done with this browser, Move to Trash, empty Trash,"
echo "     and repeat with the other browser."
