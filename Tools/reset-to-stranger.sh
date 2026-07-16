#!/usr/bin/env bash
# reset-to-stranger.sh -- wipe every piece of macXserver per-user state so the
# next launch is a true first run (BETA_PLAN.md phase 3a). Flow testing runs
# dozens of resets; this makes each one a single command.
#
#   Tools/reset-to-stranger.sh [--dry-run]
#
# HARD GUARD: refuses to run unless the current macOS account is the
# dedicated tester account (default name "tester"; override with
# MACXSERVER_TESTER_USER=<name> if the account is called something else).
# There is deliberately NO force flag: the dev account's machines.json,
# images, and Keychain logins are real state, and the entire reason this
# script exists is that it can never be pointed at them. App install
# location is irrelevant -- macOS state is per-user, which is exactly why
# testing happens in a separate account.
#
# What a "stranger" means, concretely: no machine registry (bundled fixtures
# reseed imageless + user-less on next launch), no downloaded images or
# locks, no resources/launchers/fonts dotfiles, no preferences, no saved
# window state, no Keychain logins, no dev-secret files.

set -euo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

TESTER="${MACXSERVER_TESTER_USER:-tester}"
ME="$(whoami)"
if [ "$ME" != "$TESTER" ]; then
    echo "REFUSED: this wipes all macXserver state for user '$ME'." >&2
    echo "It only runs in the dedicated tester account ('$TESTER')." >&2
    echo "Log into that account (Fast User Switching) and run it there," >&2
    echo "or set MACXSERVER_TESTER_USER if the account has another name." >&2
    exit 1
fi

# Never delete disks out from under a live VM or a running app.
if pgrep -u "$ME" -x MacXServer >/dev/null 2>&1; then
    echo "REFUSED: MacXServer is running in this account. Quit it first." >&2
    exit 1
fi
if pgrep -u "$ME" -f qemu-system-sparc >/dev/null 2>&1; then
    echo "REFUSED: a qemu-system-sparc guest is running in this account." >&2
    echo "Stop the VM (or quit the app) first." >&2
    exit 1
fi

BUNDLE_ID="com.toddvernon.swiftx.server"

# Everything the app reads or writes per user, gathered by sweeping the
# sources (2026-07-16): dotfiles in $HOME, the Application Support tree
# (downloaded images + their .macxserver-lock sidecars live there), macOS
# plumbing keyed by bundle id, and the /tmp dev-secret file the app writes
# when Claude-development mode is on.
PATHS=(
    "$HOME/.macxserver-machines.json"
    "$HOME/.macxserver-resources"
    "$HOME/.macxserver-launchers"
    "$HOME/.macxserver-fonts"
    "$HOME/.macxserver-dev-secrets.json"
    "$HOME/.macxserver-dev-catalog.json"
    "$HOME/Library/Application Support/macXserver"
    "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
    "$HOME/Library/Caches/$BUNDLE_ID"
    "/tmp/sparkplug"
)

echo "reset-to-stranger for account '$ME'$( [ $DRY = 1 ] && echo ' (DRY RUN)')"
echo

for p in "${PATHS[@]}"; do
    if [ -e "$p" ]; then
        if [ $DRY = 1 ]; then
            echo "  would remove  $p"
        else
            rm -rf "$p"
            echo "  removed       $p"
        fi
    else
        echo "  (absent)      $p"
    fi
done

# Preferences: defaults delete errors when the domain doesn't exist; that's
# the already-clean case, not a failure.
if [ $DRY = 1 ]; then
    defaults read "$BUNDLE_ID" >/dev/null 2>&1 \
        && echo "  would delete  defaults domain $BUNDLE_ID" \
        || echo "  (absent)      defaults domain $BUNDLE_ID"
else
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 \
        && echo "  removed       defaults domain $BUNDLE_ID" \
        || echo "  (absent)      defaults domain $BUNDLE_ID"
fi

# Keychain: every generic-password item with the launcher service (accounts
# are user@host:port; delete by service until none remain).
KC_SERVICE="macxserver-launcher"
n=0
while security find-generic-password -s "$KC_SERVICE" >/dev/null 2>&1; do
    if [ $DRY = 1 ]; then
        echo "  would delete  Keychain item(s), service $KC_SERVICE"
        break
    fi
    security delete-generic-password -s "$KC_SERVICE" >/dev/null 2>&1 || break
    n=$((n+1))
done
[ $DRY = 0 ] && [ $n -gt 0 ] && echo "  removed       $n Keychain item(s), service $KC_SERVICE"
[ $DRY = 0 ] && [ $n -eq 0 ] && echo "  (absent)      Keychain items, service $KC_SERVICE"

echo
if [ $DRY = 1 ]; then
    echo "Dry run only; nothing was touched."
else
    echo "Done. The next MacXServer launch is a first run: three imageless,"
    echo "user-less bundled machines and the getting-started bubble."
fi
