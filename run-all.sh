#!/usr/bin/env bash
# Build + run capture proxy AND macxserver together, with the
# proxy forwarding into the server. Used for "capture what swiftx
# itself does against a Sun client" — the resulting .xtap is a
# parallel-universe copy of the same client session run against
# our server, for diffing against gold captures from a real Xsun.
#
# Reads connection.json. The proxy forwards to whatever "forward"
# names; if that's a localhost address, we start macxserver on
# that port automatically (because something has to be listening
# there). For gold captures aimed at a real Sun, leave forward
# pointing at the Sun and this script just runs the proxy.
#
# Workflow:
#   1. Edit connection.json (output filename + forward target).
#   2. ./run-all.sh
#   3. Point your Sun client at the Mac's en0 IP + the listen port
#      (typically :0 → 6000).
#   4. Use the X client. When it closes, the .xtap finalises.
#
# If you want server-side capture INSTEAD of a proxy capture, see
# run-server.sh and pass --capture. That writes a .xtap from
# inside the server (no second TCP hop). The two paths are useful
# in different contexts:
#
#   proxy capture (this script)
#     ↳ man-in-the-middle, byte-faithful, includes setup + auth
#     ↳ useful when comparing "swiftx wire" vs "Xsun wire" for
#       the same client
#
#   server-side capture (--capture on macxserver)
#     ↳ per-client file, no second hop, auto-named after WM_CLASS
#     ↳ useful for bug reports from end users running swiftx
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="connection.json"
if [ ! -f "$CONFIG" ]; then
    echo "missing $CONFIG. Create one like:" >&2
    echo '{' >&2
    echo '  "listen":  ":6000",' >&2
    echo '  "forward": "127.0.0.1:6001",' >&2
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

swift build -c release

# Start macxserver only when the capture's forward target is
# local. Convention: capture forwards to 127.0.0.1:<port>; we run
# macxserver on that port. For gold reference captures
# (forward = sun:6000) we skip — the Sun is the X server.
SERVER_PID=""
case "$FORWARD" in
    127.0.0.1:*|localhost:*)
        SERVER_PORT="${FORWARD##*:}"
        echo "starting macxserver on 127.0.0.1:$SERVER_PORT"
        .build/release/macxserver --host 127.0.0.1 --port "$SERVER_PORT" &
        SERVER_PID=$!
        # Give the server a moment to bind before capture starts forwarding.
        sleep 1
        ;;
    *)
        echo "forward target is $FORWARD — not starting macxserver"
        ;;
esac

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        echo "shutting down macxserver (pid $SERVER_PID)"
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "capture: listen=$LISTEN forward=$FORWARD output=$OUTPUT"
.build/release/macxcapture \
    --listen  "$LISTEN" \
    --forward "$FORWARD" \
    --output  "$OUTPUT"
