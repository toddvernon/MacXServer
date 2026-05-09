#!/usr/bin/env bash
# Build + run swiftx-server. Mirrors run.sh's shape (release build, exec).
# Args pass through to the server (e.g. --host / --port overrides).
#
#   ./run-server.sh                       # default: 0.0.0.0:6000 = X display :0
#   ./run-server.sh --host 127.0.0.1      # localhost only
#   ./run-server.sh --port 6001           # X display :1
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

exec .build/release/swiftx-server "$@"
