# Shortcuts and stubs

Running list of places we hardcoded, stubbed, or otherwise corner-cut to make something work. Each entry should die eventually; the point of the file is to make sure none of them is forgotten.

## Convention

- **When you hardcode** something to make a bigger thing work, add an entry here in the same change.
- **When you replace** a hardcode with a real implementation, delete the entry (or move it to the Closed section at the bottom).
- Periodically review the open list. If it's growing and not shrinking, that's a signal to stop adding features and clean up.
- Each entry: file or component, what's stubbed, why, what "real" would look like.

## Open

(Nothing yet. Entries land here as Product 2 starts and we deliberately stub things to keep M1 small.)

### Planned for M1 (will be entered when the code lands)

- **SetupAccepted is hardcoded.** One screen, one PseudoColor 8-bit visual, one pixmap format, vendor "swift-x", a fabricated resource-id-base. Real version: derive from actual macOS display geometry, expose both PseudoColor 8-bit and TrueColor 24-bit (per `DECISIONS.md`).
- **GetProperty returns empty for everything except properties we set ourselves.** xclock's `GetProperty(RESOURCE_MANAGER)` returns no value. Real version: maintain a server-side X resource database (loaded from `xrdb`-equivalent or `~/.Xdefaults`).
- **AllocColor returns synthetic monotonic pixel values.** Server caches `pixel → RGB` for later draw. Real version: a proper PseudoColor colormap implementation with shared cells, freelist, etc.
- **QueryFont returns a stub.** Non-zero ascent/descent, no real character metrics. Works because xclock doesn't actually render text. Real version: open the requested font via Core Text, fabricate a believable QueryFont reply consistent with what we'll actually render.
- **OpenFont accepts any font name and returns success.** Same reason. Real version: name → Core Text font matching.
- **CreatePixmap with depth=1 (the WM icon pixmap and mask) is stored and ignored.** Real version: rootless mode should bridge to NSWindow icon, but only when we care about iconified state.
- **ChangeWindowAttributes BackingStore bit accepted and ignored.** Real version: probably stays ignored permanently; backing store is implemented transparently by the renderer.
- **EnterNotify / LeaveNotify events not emitted.** xclock ignores them anyway. Real version: emit on pointer crossings once we have any real input handling.
- **Stipple / tile GC attributes accepted but unused at draw time.** Most R-era apps don't use them. Real version: implement when an app actually draws with one (probably xterm or Motif scrollbars).

## Closed

(Empty. Items move here from Open when fixed.)
