# Contributing to MacXServer

Thanks for looking at this. It's a personal project that got far enough
along to be worth opening up. The most useful things you can do are file
good bug reports (ideally with a capture attached) and send me captures
from X clients I don't have access to. Code contributions are welcome too,
with a few conventions noted below.

## Building and testing

```
swift build -c release
swift test
```

macOS 14 or later, a recent Swift toolchain (Xcode 15+). No other
dependencies, no package manager beyond SwiftPM, no build system to learn.

`swift build` and `swift test` are the dev loop. To run the actual apps
(with their icons and menu-bar presence), open `MacXServer.xcodeproj` and
run the `MacXServer` or `MacXCapture` scheme. `swift build` produces bare
command-line binaries without the `.app` bundle.

## Filing a bug (the good way: attach a capture)

The single most useful thing you can include in a bug report is an `.xtap`
capture of the session that misbehaved. It records the actual X11 wire
traffic, so I can replay your exact session locally instead of guessing.

1. Run the server with capture on:
   ```
   .build/release/macxserver --capture
   ```
   (or flip Preferences → Capture).
2. Reproduce the bug.
3. Grab the freshest file from `/tmp/macxcapture/` (named after the
   client's `WM_CLASS`).
4. Open a bug report and attach it.

`/tmp` wipes on reboot, so grab the file before then. If you can't share a
capture (the traffic is sensitive, etc.), a clear description of the client,
the X toolkit, and what you saw versus expected still helps.

## Sending a corpus capture

If you have an X client I haven't tested against, especially anything from a
real vintage Unix workstation, a capture of it running is genuinely
valuable. Record it with the capture tool or the server's `--capture`, and
open an issue or PR adding it under `captures/` with a one-line note on what
it is and where it came from. Scrub anything you consider sensitive first
(hostnames, usernames) since captures contain real connection-setup data.

## Code contributions

The project keeps a few ledgers honest. If your change touches them, update
them in the same commit:

- **`OPCODE_STATUS.md`** — when you implement, change, or stub a protocol
  opcode, record its status and an honest confidence rating. Low confidence
  stated plainly is fine; hidden low confidence is not.
- **`SHORTCUTS.md`** — when you hardcode or stub something to make a bigger
  thing work, log it with a "what real looks like" exit plan. This is the
  active ledger of currently-justified shortcuts, not a wishlist.
- **`DECISIONS.md`** — append-only. If you make a real architectural call,
  record it with a date and the reasoning (and the alternatives you
  rejected). If you want to revisit a settled decision, flag it rather than
  quietly reversing it.

A few hard rules from how the server treats the protocol:

- **XErrors are real output, not panics.** When a request can't be served,
  emit the correct XError on the wire per the X11 spec. Don't silently fake
  a success to dodge an error. In tests, an emitted XError on a path we
  claim to support is a failure.
- **Don't lie on the wire by default.** If a deliberate fake-success is the
  only way to keep a real client working, it has to be ledgered in
  `SHORTCUTS.md` with an exit plan and annotated at the call site. A lie
  without that contract is a bug.

PRs should keep `swift test` green and add tests for new behavior. The
suite is extensive on purpose; new graphics ops in particular need an
orientation test (see `GRAPHICS_Y_FLIP.md` before touching anything that
draws).

## Extending it with Claude Code

A lot of this was built with Claude Code, and the repo is set up to keep
working that way. `CLAUDE.md` at the root is the agent's brief: the
conventions above, which docs to read before which kind of work, and the
review-gate protocol (planning agent before tricky opcodes, milestone
review at boundaries, periodic ledger audits). If you use an AI coding
agent, point it at `CLAUDE.md` first. The required-reading-by-task-type
section there will save you from the traps that already ate real debugging
time (the y-flip convention, the font/scaling rules, the Motif text
playbook).

## Style

Documentation and comments: casual, first-person, direct, technical. No
marketing language, no em-dashes. Match the style of what's already there.
Swift for the Mac-side code. Boring, obvious code over clever code.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be
decent. Report problems to todd@toddvernon.com.

## License

By contributing, you agree your contributions are licensed under the
project's [Apache-2.0 license](LICENSE).
