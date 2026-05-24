#!/usr/bin/env bash
# Build + run swiftx-server. Listens on the default X display port
# (6000 = display :0) and lets X clients connect.
#
# Args pass through to the server. Common ones:
#
#   ./run-server.sh                      # 0.0.0.0:6000 (display :0)
#   ./run-server.sh --host 127.0.0.1     # localhost only
#   ./run-server.sh --port 6001          # X display :1
#   ./run-server.sh --capture            # tee each session to /tmp/swift-x-captures/
#
# Preferences (⌘, in the status menu) also has a Capture tab if you
# prefer a persistent toggle to a CLI flag.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

exec .build/release/swiftx-server "$@"
