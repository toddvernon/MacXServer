#!/usr/bin/env bash
# Build + run macxcapture. Behavior depends on arguments:
#
#   ./run-capture.sh                        # CLI proxy mode using connection.json
#   ./run-capture.sh dump <path.xtap>       # decoded chronological dump
#   ./run-capture.sh summary <path.xtap>    # aggregate per-opcode summary
#   ./run-capture.sh diff <a.xtap> <b.xtap> # compare two captures
#   ./run-capture.sh replay <path.xtap> --target <host:port>
#   ./run-capture.sh --no-gui               # force CLI usage print
#
# No-args runs proxy capture from connection.json (this script's
# convenience behaviour). To launch the GUI instead, run the binary
# directly: `.build/release/macxcapture` with no args — the GUI
# is the binary's default when launched bare.
#
# connection.json shape:
#   {
#     "listen":  ":6000",
#     "forward": "u5.example.com:6000",
#     "output":  "captures/session.xtap"
#   }
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# Pass-through: any args land directly on macxcapture, which
# dispatches to the right subcommand (dump / replay / etc.) or to
# the GUI (--gui).
if [ $# -gt 0 ]; then
    exec .build/release/macxcapture "$@"
fi

# No args: proxy capture from connection.json.
CONFIG="connection.json"
if [ ! -f "$CONFIG" ]; then
    echo "missing $CONFIG. Create one like:" >&2
    echo '{' >&2
    echo '  "listen":  ":6000",' >&2
    echo '  "forward": "u5.example.com:6000",' >&2
    echo '  "output":  "captures/session.xtap"' >&2
    echo '}' >&2
    exit 1
fi

read_json() {
    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"
}

LISTEN=$(read_json "$CONFIG" listen)
FORWARD=$(read_json "$CONFIG" forward)
OUTPUT=$(read_json "$CONFIG" output)

exec .build/release/macxcapture \
    --listen  "$LISTEN" \
    --forward "$FORWARD" \
    --output  "$OUTPUT"
