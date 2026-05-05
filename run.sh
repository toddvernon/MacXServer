#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# Pass-through mode: any args supplied (e.g. "./run.sh dump session.xtap")
if [ $# -gt 0 ]; then
    exec .build/release/swiftx-capture "$@"
fi

# No args: run capture with parameters from connection.json
CONFIG="connection.json"
if [ ! -f "$CONFIG" ]; then
    echo "missing $CONFIG. Create one like:" >&2
    echo '{' >&2
    echo '  "listen": ":6000",' >&2
    echo '  "forward": "u5.example.com:6000",' >&2
    echo '  "output": "session.xtap"' >&2
    echo '}' >&2
    exit 1
fi

read_json() {
    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"
}

LISTEN=$(read_json "$CONFIG" listen)
FORWARD=$(read_json "$CONFIG" forward)
OUTPUT=$(read_json "$CONFIG" output)

exec .build/release/swiftx-capture --listen "$LISTEN" --forward "$FORWARD" --output "$OUTPUT"
