# Themes: user-editable resources with theme switching

The Tier 2 of `MOTIF_TEXT_QUALITY.md`'s staged delivery, plus a real UX for editing. Lets me tweak the X resources from a Mac-native preferences window, switch between themes (quickplot, dark, cde-classic, mwm-default), and reload on save without restarting the server.

## Goal

One concrete win: I can iterate on the dt-app look without rebuilding the project. Open Preferences, change a color, save, relaunch quickplot, see the change.

Stretch: themes-as-a-feature so someone else picking up the project can flip the whole palette in one line.

## User experience

Two new menu items in the swift-x app menu (the Mac menu bar at the top of the screen, not anything inside X windows):

- **`Preferences…`** (Cmd-,) opens the editor window.
- **`Reload Resources`** (no shortcut) reparses the file and republishes RESOURCE_MANAGER without opening the editor. For when I edit the file in vim and want to apply.

Editor window:

```
+-------------------------------------------------------------+
| swift-x Resources                          [Theme: dropdown]|
|                                                             |
| 1   [swiftx-config]                                         |
| 2   theme: quickplot                                        |
| 3                                                           |
| 4   [global]                                                |
| 5   *cursorForeground: cyan                                 |
| 6   *menubar*background: SlateBlue1                         |
| 7                                                           |
| 8   [theme:quickplot]                                       |
| 9   *background: Gray                                       |
| 10  *XmText.background: DarkSeaGreen                        |
|                                                             |
| [Save]  [Reload]  [Revert to Defaults]    ⚠ Changes since.. |
+-------------------------------------------------------------+
```

- Monaco 12pt, line numbers down the left.
- Theme dropdown at top-right is a shortcut for editing `[swiftx-config].theme` (writes back to the file on selection).
- Save flushes to disk and triggers reload.
- Reload re-reads the file from disk (in case I edited externally).
- Revert to Defaults blows away the file and re-seeds it from the built-in content. Confirmation dialog first.
- "Changes since…" banner appears when there are unsaved edits.

On save, a banner near the bottom: "Resources reloaded. Restart Motif apps to see changes" since toolkits cache resources at connect time and existing windows don't re-query.

## File location

Going with **`~/.swiftx-resources`** (own file, dotfile in home).

Reasoning:
- Real `~/.Xresources` is consumed by `xrdb` and any other X server I might run; if we add non-standard section syntax we corrupt that file for the rest of the X ecosystem.
- Owning the file means we can extend the format freely (themes today, conditional blocks tomorrow, whatever).
- Simple path that's easy to find with `ls ~/.s<tab>`.

Optional fallback (Phase 2): if `~/.swiftx-resources` doesn't exist but `~/.Xresources` does, load the latter as the active theme content (no sections). Lets people start from their existing Xrm setup. Phase 1 just uses our own file.

**First-startup behavior:** if `~/.swiftx-resources` doesn't exist, the server writes a fresh copy seeded from the current `DefaultMotifResources.swift` content (with section headers added wrapping it as `[theme:quickplot]` + the `[global]` parts split out). User has an editable starting point that matches what they've been seeing.

## File format

INI-style sections. Three section types:

```
[swiftx-config]
theme: quickplot

[global]
! Rules that apply regardless of active theme. Mostly cursor color,
! menu accent, things that survive theme switches.
*cursorForeground: cyan
*menubar*background: SlateBlue1

[theme:quickplot]
! Everything else for this theme.
*background: Gray
*foreground: Black
*XmText.background: DarkSeaGreen
Dtpad*XmText.background: White
... (the rest of current DefaultMotifResources content)

[theme:dark]
*background: #2a2a2a
*foreground: #cccccc
*XmText.background: #1a1a1a
*XmTextField.background: #1a1a1a
*XmList.background: #2a2a2a
...

[theme:cde-classic]
*background: #b8b8b8
*foreground: Black
*XmText.background: White
*XmTextField.background: White
*XmList.background: White
...

[theme:mwm-default]
! The bare Motif compile-in look. Useful for debugging when I want to
! see what an app does WITHOUT our resources affecting it.
! (Mostly empty; lets Motif's hard-coded blue take over.)
```

Parser rules:
- Lines starting with `[` and ending with `]` are section headers.
- Inside a section, `key: value` is a resource line (must contain a `:` after the first whitespace-free token).
- Lines starting with `!` are comments.
- Blank lines ignored.
- Whitespace around `:` is flexible.
- Unknown sections (typo, new in a future version) are read but not used. Warning logged.
- Duplicate keys within a section: last wins. Matches Xrm precedent.
- `[swiftx-config].theme` value selects which `[theme:NAME]` block to apply alongside `[global]`.

**Published RESOURCE_MANAGER content:** the concatenation of `[global]` + `[theme:<active>]`. Anything in those two sections only. The `[swiftx-config]` section is internal, never published.

## Built-in themes (ship with the seed file)

**Phase 1 ships just one theme**: `quickplot`, populated from the current `DefaultMotifResources.swift` content (split into `[global]` for the universal bits and `[theme:quickplot]` for everything else). Reasoning: the file format pays for itself with one theme too because Phase 2 themes can be added without migrating the file structure. And Todd wants to hand-tweak the quickplot block to perfection before forking it into derivatives.

Additional themes (`cde-classic`, `dark`, `mwm-default`) get added later by extracting from the perfected quickplot block. The plan to seed those themes alongside is deferred.

## Hot reload semantics

On save (or Reload menu):
1. Re-parse `~/.swiftx-resources`.
2. If parse fails, show errors inline (line numbers + messages), keep the previous resources active.
3. If parse succeeds:
   - Replace `DefaultMotifResources.bytes` with the new content (it stops being "default" and becomes "current").
   - Republish RESOURCE_MANAGER on the root window for every active session. Existing clients won't re-read it (Motif caches at connect time), but newly-launched clients will.
   - Banner: "Resources reloaded. Restart Motif apps to see changes."

**Not in scope** (and worth being explicit about):
- Live re-styling of already-connected widgets. That would require sending property-change events on every widget's XmNbackground/foreground/etc. and the toolkit doesn't watch for that. Real solution is "quit and relaunch the app."

## Implementation breakdown

| Component | Where | Approx lines |
|---|---|---|
| File parser (INI sections, key:value, one-way text→model) | `Sources/SwiftXServerCore/ResourceFile.swift` (new) | ~100 |
| Theme selector + RESOURCE_MANAGER content builder | same file | ~50 |
| First-run seed (write `~/.swiftx-resources` from `DefaultThemes`) | same file | ~30 |
| Resource publish hook (used by ServerSession init) | wire into existing `publishResourceManager` | ~20 |
| Editor window: NSWindowController + NSTextView | `Sources/SwiftXServer/ResourcesWindowController.swift` (new) | ~200 |
| Dirty tracking + Save / Reload / Revert button wiring | same | ~70 |
| Theme dropdown (writes one line back via text-replace) | same | ~40 |
| Banner UI ("Restart Motif apps..." / parse errors) | same | ~30 |
| Menu items (Preferences…, Reload Resources) | `Sources/SwiftXServer/main.swift` AppDelegate | ~30 |
| Seed file content (current resources wrapped as [global] + [theme:quickplot]) | `Sources/SwiftXServerCore/DefaultThemes.swift` (new) | ~150 |
| Tests for parser | `Tests/SwiftXServerCoreTests/ResourceFileTests.swift` (new) | ~80 |

**Total**: ~800 lines after dropping the additional-theme seed content. Editor UI is the biggest single piece but it's straightforward Cocoa. Parser is shorter than initial estimate since we never re-serialize.

## Phasing

**Phase 1 (this round):**
- File parser + theme selector
- Seed file with 4 themes
- Menu items + Cocoa editor window
- Save/Reload/Revert
- Banner
- Tests for parser

Ships as one PR, one weekend of work.

**Phase 2 (later):**
- `~/.Xresources` fallback when `~/.swiftx-resources` doesn't exist (one-time import option)
- Theme catalog UI (cards with preview swatches instead of dropdown)
- Per-app theme overrides (`[theme:quickplot][dtpad]` style nested)
- Re-style already-connected widgets (low-confidence, may not be feasible)

## Decisions (locked in 2026-05-23)

1. **File path.** `~/.swiftx-resources`. Confirmed.
2. **Theme switching shortcut.** No menu-bar keyboard shortcut for cycling. Switch themes via the editor dropdown (or by editing the `[swiftx-config].theme` line directly).
3. **Seed file is one-time.** Written by the swift-x app at first run when `~/.swiftx-resources` doesn't exist; never overwritten afterward. The file is the user's after that — they may have customized it. New built-in themes ship as snippets in this doc (or in CHANGELOG-equivalent material) and the user copies them in by hand if they want. **Caveat during development:** I (Todd) may have Claude edit either side — the seed content in `DefaultThemes.swift` to refine what new installs get, OR my own `~/.swiftx-resources` to dial in my preferences. Both are fine; they're distinct artifacts after first run.
4. **Per-session theme overrides.** Deferred to Phase 2. Phase 1 ships with one active theme server-wide.
5. **Save model: dirty tracking.** The editor holds the file as raw text in an NSTextView. Any change to the buffer (even a single space) sets a `dirty` flag. On Save:
   - If dirty: write the buffer contents to `~/.swiftx-resources` verbatim, clear dirty, then trigger a reparse for the running server's resource state.
   - If not dirty: no-op (don't touch the file on disk).
   This means the parser is one-way (text → structured representation, used only for active-theme lookup + RESOURCE_MANAGER content). We never serialize back. User's formatting, comments, key ordering, blank lines are preserved exactly because we never rewrite the file unless they actually edited it.

## Things I'm still uncertain about (low-stakes, can decide during implementation)

- **Color value handling.** Both X named colors (`Gray`, `SlateBlue1`) and hex (`#1a1a1a`, `#abc`) need to work. They already do in our current resources. No special handling required for themes.
- **Show parse errors where?** Inline in the editor (highlight bad line, tooltip) or in the banner area at the bottom? Probably the banner for now — inline highlighting needs an NSTextStorage attribute pass which is more Cocoa wiring than it's worth in Phase 1.

## What's NOT in scope

- A GUI theme editor (color pickers, font dropdowns, per-widget controls). Text editor is enough; X resources are text.
- Importing iTerm2 / VSCode / GNOME themes. Wrong abstraction layer.
- A "theme store" with downloadable themes. Way over-engineered for what this is.
- Replacing the hardcoded `DefaultMotifResources.swift` immediately. We'll keep it as the fallback when the user file is missing/broken AND as the seed content for first run. Two sources of truth long term but Phase 1 ships with both intact.

## Risks

- **Editor window thread/state coupling.** Cocoa UI on the main thread, X server work on protocolQueue per session. The reload-on-save path crosses threads — needs to dispatch the RESOURCE_MANAGER republish onto each session's queue. Same shape as the existing bridge callbacks.
- **Parse failures hiding under the UI.** If the user saves a malformed file, we keep the previous content. The error display has to be clear or they'll think their edits worked when they didn't.
- **First-run seed conflicts with multiple Macs.** Dropbox syncs `~/.swiftx-resources` across my machines. Mac A's seed write races with Mac B reading it for the first time. Solution: write the seed atomically (write to `.swiftx-resources.tmp` then rename), or just live with one Mac winning on first run.

## Bottom line

This is small enough to ship in a focused round (~1000 lines including tests and seed content), gives real iteration speed for design work, and sets up Phase 2 nicely. Recommend going.
