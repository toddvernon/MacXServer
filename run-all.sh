#!/usr/bin/env bash
# Build + run the whole capture stack: swift-x server + capture proxy.
# Reads connection.json. If 'forward' is local (127.0.0.1 / localhost) we
# start the swift-x server on that port so capture has something to forward
# to. Otherwise (e.g., forward = u5.example.com:6000 for a gold reference
# capture) we just run the capture proxy standalone.
#
# Workflow: edit connection.json — change "output" filename and "forward"
# target — then ./run-all.sh. Point your Sun client at the Mac's en0 IP +
# the capture's listen port (typically :0 for port 6000).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="connection.json"
if [ ! -f "$CONFIG" ]; then
    echo "missing $CONFIG. Create one like:" >&2
    echo '{' >&2
    echo '  "listen": ":6000",' >&2
    echo '  "forward": "127.0.0.1:6001",' >&2
    echo '  "output": "captures/session.xtap"' >&2
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

# Start swift-x only when capture's forward target is local. Convention:
# capture forwards to 127.0.0.1:<port>; we run swift-x on that port. For
# gold reference captures (forward = sun:6000) we skip — the Sun is the
# X server in that case.
SERVER_PID=""
case "$FORWARD" in
    127.0.0.1:*|localhost:*)
        SERVER_PORT="${FORWARD##*:}"
        echo "starting swift-x server on 127.0.0.1:$SERVER_PORT"
        .build/release/swiftx-server --host 127.0.0.1 --port "$SERVER_PORT" &
        SERVER_PID=$!
        # Give the server a moment to bind before capture starts forwarding.
        sleep 1
        ;;
    *)
        echo "forward target is $FORWARD — not starting swift-x"
        ;;
esac

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        echo "shutting down swift-x server (pid $SERVER_PID)"
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "capture: listen=$LISTEN forward=$FORWARD output=$OUTPUT"
.build/release/swiftx-capture --listen "$LISTEN" --forward "$FORWARD" --output "$OUTPUT"
