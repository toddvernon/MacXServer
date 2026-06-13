# Gatekeeper browser-dependence: research findings

Companion to `GATEKEEPER_BROWSER_INVESTIGATION.md`. That file is the
dossier (raw observations + competing explanations). This file is the
fresh-eyes research report that came back after handing the dossier to an
analyst with no project context and asking them to reach their own
conclusions using web research (Apple docs, Howard Oakley at
eclecticlight.co, Apple Developer Forum DTS responses, Jamf, HackTricks,
rsms's distribution gist).

Important reader's-note: the analyst's framing of "Safari working is a
Sequoia-version-dependent accident" is too dismissive of Todd's direct
day-long observation that Safari downloads launch cleanly on his Mac
every single time today and Chrome downloads block every single time.
The agent's own mechanism — translocation + `LSQuarantineType` +
Sequoia's launch responsibility chain — actually PREDICTS a reproducible
Safari-vs-Chrome asymmetry on a given OS point release. So the
empirical difference is real, and it's not "luck"; the agent disputes
only the folk-LLM mechanism story ("Safari is on a Gatekeeper allowlist"
/ "Safari strips the quarantine flag"), not the difference itself.

---

## Short answer

The browser-dependent difference is not Gatekeeper treating Safari's
bytes as "user-approved" while it treats Chrome's bytes as
"not-yet-approved." After Sierra, Gatekeeper does **not** consult the
agent name in the quarantine xattr or treat Safari downloads specially.
The actual mechanism is more mundane: **Safari, with its default "Open
safe files after downloading" preference on, auto-extracts the .zip in
the same browser-owned process that wrote the original quarantine,
producing a single quarantine event. Chrome doesn't auto-extract, so
the user double-clicks the .zip in Finder, which causes Archive Utility
to run as a second download/extraction step. That can produce slightly
different quarantine attribution and, more importantly, makes the very
first thing the user double-clicks (the .app, fresh out of Archive
Utility) be the launch event Gatekeeper assesses.** The dialog you got
— "Apple could not verify ... free of malware" with only Move to Trash
/ Done — is, on Sequoia, the *standard* Gatekeeper first-launch dialog
for any quarantined notarized app. It is NOT a "notarization failed"
dialog (that one says "is damaged") and it is NOT an "unidentified
developer" dialog. It is what Sequoia now shows in place of the old
"Are you sure you want to open it?" Open/Cancel prompt.

In other words: the Safari path probably isn't bypassing Gatekeeper
because of anything Safari did to the xattr. It's bypassing the dialog
because Sequoia's behavior for that exact dialog depends on subtle path
differences (translocation status, whether LaunchServices has already
seen the binary because Safari "opened" the zip, possibly differences
in the recorded `LSQuarantineType`), and the simplest, most-reported
version of the Safari-vs-Chrome difference is that Safari users tend to
follow the path that *registers* the app with LaunchServices during
extraction whereas Chrome users hit Gatekeeper cold on the very first
double-click.

This story is still partially a hypothesis on Sequoia 15.x specifically.
The parts the analyst is confident about, the parts that are
likely-but-needs-test, and three diagnostic commands that will settle
it are at the end.

## Evidence

**The quarantine xattr format and what bits mean** (Howard Oakley,
eclecticlight.co; confirmed by Jamf and HackTricks):

The xattr is a UTF-8 string `flags;timestamp;AgentName;UUID`, e.g.
`0083;5991b778;Safari.app;BC4DFC58-...`. The flag bits documented are:

- `0x0001` — `QTN_FLAG_DOWNLOAD` (file came from network)
- `0x0002` — `QTN_FLAG_SANDBOX` (downloaded by a sandboxed agent)
- `0x0040` — `QTN_FLAG_USER_APPROVED` (first-run check passed / user
  approved)
- `0x0080` — set on every quarantined file (the "this is a quarantine
  record" sentinel; some writeups call it the "hard quarantine" /
  always-on bit)

So Safari's `0083 = 0x0080 | 0x0002 | 0x0001` means "quarantined,
downloaded by a sandboxed agent, from a network download." Chrome's
typical `0081 = 0x0080 | 0x0001` means "quarantined, network download,
not from a sandboxed agent." Crucially, **neither value has the `0x40`
user-approved bit set** on initial download. (eclecticlight 2017;
eclecticlight 2020.)

**The agent name is not consulted by Gatekeeper after Sierra.** Howard
Oakley, the most-cited public chronicler of macOS internals: "As of
Sierra, no checking is performed on the app named as the downloading
agent, and the UUID may not be checked either." (eclecticlight 2017.)
This directly refutes Explanation B's "Safari is registered with
LaunchServices as a trusted download agent." There is no such
trusted-agent table that Gatekeeper consults.

**The "could not verify ... free of malware" dialog is the new Sequoia
version of the first-launch quarantine prompt.** Sequoia (15.0) removed
the right-click → Open contextual bypass and reworded/restructured the
dialog. Apple itself describes the change in their developer news post;
multiple independent writeups (Michael Tsai, iDownloadBlog, Apple
Support 102445) confirm that on Sequoia 15.0+ the very first launch of
a quarantined notarized app goes to System Settings → Privacy &
Security → "Open Anyway" for approval rather than the in-line Open
button.

The "could not verify ... free of malware" wording is the deliberately
alarming text Sequoia uses for *all* quarantined notarized apps on
first launch, not a "notarization failed" signal. (Multiple developer
forum reports of notarized-and-stapled apps hitting this dialog: Apple
Developer Forum 788787, forum 706273.) The 706273 thread is
particularly damning: an Apple DTS engineer states explicitly, "There
aren't different lower-level runtime checks being performed between
curl vs. a web browser. When you use curl, there are no checks being
done at all. Gatekeeper works by having the web browser attach a
quarantine flag to the downloaded file."

**Safari and zip extraction.** Safari has `LSFileQuarantineEnabled =
true` in its Info.plist, so anything it writes gets a quarantine xattr.
With "Open safe files after downloading" enabled (the default), Safari
auto-invokes Archive Utility on the .zip. The extracted .app inherits
the quarantine xattr — it is *not* stripped. This is the same
propagation behavior Archive Utility uses in Finder. (eclecticlight
2020 on propagation: "the xattr is normally propagated to all items
which are saved from that"; on Safari's `LSFileQuarantineEnabled`:
HackTricks Gatekeeper page.)

So: **Safari-extracted bundles do have `com.apple.quarantine`. It is
not missing.** Explanation A's testable claim ("for the Safari version,
that line will either be entirely missing or contain fewer restrictive
parameters") is almost certainly false in the trivial sense. Whether
the *flag bits* differ between the Safari-extracted bundle and the
Chrome-extracted bundle is the open question, and the answer is
"probably 0083 vs 0081" — different in the sandbox bit, not in the
user-approved bit, and that difference is invisible to Gatekeeper in
the sense of "Gatekeeper does not have a 'sandbox bit means trust'
rule."

**The likely real cause of the dialog asymmetry on Sequoia.** Several
plausible interacting factors:

1. **App Translocation.** Sequoia is more aggressive about
   translocating quarantined apps that haven't been "moved" by the
   user. A Safari "open safe files" extraction is treated by
   LaunchServices as a sequence Safari initiated (Safari opened the zip
   → Archive Utility extracted → resulting .app is in `~/Downloads`).
   Chrome → Finder-double-click-zip → Archive Utility produces an
   extraction that LaunchServices sees as a separate launch chain.
   Translocation status may differ, and the "could not verify" dialog
   correlates with the translocated-on-first-launch path.
2. **Same-process responsibility chain.** Sequoia's
   `com.apple.syspolicy.exec` decides who is "responsible" for the
   launch. Howard Oakley's Sequoia launch walkthrough calls out that
   this responsibility decision drives whether a code-evaluation prompt
   is shown. Safari's auto-extract makes Safari the responsible
   launcher of Archive Utility, which is registered with
   LaunchServices; the Chrome path makes Finder responsible, and Finder
   is a different responsibility chain.
3. **Quarantine event coalescing.** Safari and Archive Utility share a
   download → extract pipeline, so the system records *one* quarantine
   event for the .app. The Chrome → Finder → Archive Utility path is
   two separate events (Chrome's download, then Finder's extraction).
   The xattr the .app ends up with may be the inner one from Archive
   Utility re-stamping, with a different `LSQuarantineType` value than
   Safari's path. (eclecticlight 2019 explains `LSQuarantineType`
   values — `LSQuarantineTypeWebDownload` vs `LSQuarantineTypeOther
   Download` vs `LSQuarantineTypeSandboxed`. Web downloads and
   sandboxed-source downloads can be policy-differentiated.)

These mechanisms TOGETHER predict a reproducible Safari-vs-Chrome
asymmetry on a given Sequoia point release, which is exactly what Todd
observes.

## Verdict on each of the three pasted explanations

**Explanation A (neighbor, probably LLM):** Wrong on the load-bearing
claim. The xattr IS present on Safari-extracted bundles; Archive
Utility does propagate it; Safari's status as a "trusted system
process" is not how Gatekeeper makes its decision. The conclusion is
right (Safari path is smoother) for accidental reasons; the mechanism
explanation is folk knowledge.

**Explanation B (Claude session):** Half right and half wrong. The
right half: the xattr is present on both, the format is
`flags;timestamp;AgentName;UUID`, and the difference is not "xattr
missing." The wrong half: the assertion that Gatekeeper reads the flag
field and treats Safari's flags as "user already approved this download
from a known agent" is not supported by the documented bit semantics.
The `0x40` user-approved bit is NOT set by either browser at download
time — it's set after Gatekeeper's first-run check passes. The
agent-name part of the xattr is record-keeping only since Sierra.
Explanation B is closer to right than A — it correctly killed the
"xattr missing" story and correctly walked back the stapling-failure
suspicion — but its substitute mechanism ("Safari's flags say
user-approved, Chrome's don't") is itself folk knowledge dressed up in
more accurate jargon.

**Explanation C (Gemini):** Same mechanism story as A. Adds two factual
errors: it says the dialog is "cannot be opened because it is from an
unidentified developer," which is wrong (that's a separate, unrelated
dialog for unsigned apps; the dialog you're seeing is the "could not
verify ... free of malware" Sequoia first-launch quarantine prompt for
notarized apps), and it implies a notarized app launched from Safari
should produce zero prompts, which is true today *only* if the user
has configured it to (and isn't necessarily reliable across Sequoia
point releases).

The honest version: the xattr is present on both; the actual
differentiator is what launches the .app for the first time after
extraction (and via what responsibility chain), not the agent-name
field.

## Publisher-side fix recommendations, ranked

The trade-off frame: the dialog you're hitting is not a notarization
bug; it's the cost of "user downloaded a .zip from the web and
double-clicked the resulting .app." Anything that puts the .app on disk
via a non-zip path or that makes the first launch happen from a path
Gatekeeper has already assessed will avoid it. Ranked:

**1. Ship a signed + notarized .pkg installer (RECOMMENDED).** This is
the most reliable fix. The `installer` command and Installer.app launch
the installed app via a path LaunchServices treats as user-initiated
install, and the resulting .app in `/Applications` does not carry a
quarantine xattr that triggers a first-launch Gatekeeper prompt for the
*app* (the user has already approved the install via the installer's
own auth prompt, which constitutes the user-approval gesture).
Trade-offs: you need a Developer ID Installer cert (you don't have one
yet; it's free to add at developer.apple.com), the pkg has to be signed
with that cert and notarized separately, the user sees an installer
flow instead of "drag to Applications," and the installer can't be a
"pure drag-install" anymore. Many serious Mac apps ship pkg precisely
for this reason. The pkg first-launch is the cleanest possible
experience for the broadest set of users. (Sources: Apple Developer
Forum 706273; Apple Notarization docs; scriptingosx 2019; rsms
distribution gist.)

**2. Ship a signed + notarized .dmg.** The rsms distribution gist
explicitly says: "Disk images can be code-signed and avoid quarantine
in the common case, as a result from the user having to copy the app;
the first time the app launches outside the disk image it is not
quarantined." (Modulo notarization-staple behavior, which has changed
across releases.) Trade-offs: you have to notarize and staple BOTH the
.dmg AND the .app inside it (the dmg gets its own notarization), and
Sequoia is reportedly less generous about the "drag out of dmg = no
quarantine" behavior than older releases were. The rsms claim is from
2019; this needs to be tested on Sequoia before committing.

**3. Keep .zip, fix the messaging.** Zip is "unconditionally subject to
quarantine" per the rsms gist. There is no header or zip-tool change
that fixes this — `LSFileQuarantineEnabled` is on the downloading app,
not anything you can influence from the server side. HTTP headers don't
matter; the quarantine xattr is set by the browser based on whether the
response came over the network, not based on Content-Type or
Content-Disposition. So if you keep zip, the fix is documentation, not
packaging.

**4. Things that look like fixes but aren't.**

- "Change the zip tooling" — no. Whether you use `ditto -c -k --sequester
  Rsrc --keepParent` (the Apple-blessed way) or `zip -r`, the
  quarantine xattr is applied by the browser to the file it downloads,
  not encoded inside the zip. Tool choice does affect whether code
  signatures survive extraction; both `ditto` and the Archive Utility
  used by Finder preserve them correctly for notarized apps. No
  advantage to one over the other on this dialog.
- "Set HTTP headers" — no. `Content-Disposition: attachment` does not
  affect quarantine. `MDLSearchableItemContentType`-style hints don't
  either. The only header-influenced behavior is whether Safari treats
  the file as "safe" for auto-extract (zip is on Safari's safe list by
  default).
- "Strip quarantine on download via a download script" — possible (a
  `curl` link with a wrapper) but it has terrible UX and worse, it
  bypasses Gatekeeper checks the user actually wants. Don't do this.

**Concrete recommendation: get the Developer ID Installer cert and ship
signed + notarized .pkg as the primary download, with a .zip alongside
for users who explicitly want a drag-install.** This costs you a
Developer ID Installer cert request, the `pkgbuild` + `productsign` +
notarize + staple pipeline (well-documented, ~30 lines of shell), and a
"MacXServer Installer.pkg" landing page UI. It eliminates the dialog
for everyone, not just Safari users.

## Recommended download-page copy

The current plan — "use Safari for smoothest first launch, here's the
System Settings → Privacy & Security → Open Anyway escape hatch for
Chrome/Firefox/Edge" — is *factually defensible* but has two issues:

1. It frames Chrome/Firefox/Edge users as the problem when the
   publisher could change packaging and fix it for everyone. If you can
   ship the pkg, do that instead.
2. The "smoothest" qualifier overstates the Safari advantage. Sequoia is
   increasingly aggressive about showing the dialog even on the Safari
   path, depending on point release and translocation behavior. You may
   end up with a "Safari was smoothest, but it still showed the dialog
   this time" embarrassment.

**Reader's note: the "may end up embarrassed" claim is the analyst's
inference from developer-forum reports, not from on-machine testing of
the current v0.9.0 build on current Sequoia. Todd's direct observation
is that the Safari path is reliably clean today. Don't drop the Safari
recommendation purely on this hypothesis; weigh it against the
day-long empirical evidence.**

If you're not yet shipping the pkg, suggested copy that's honest:

> **Installation**
>
> Download MacXServer.zip. Double-click to extract, then drag
> MacXServer.app to your Applications folder.
>
> **First launch (one-time):** Because MacXServer is downloaded from
> the web, macOS will show a Gatekeeper prompt the first time you
> launch it, even though MacXServer is signed and notarized by Apple.
> To allow it:
>
> 1. Double-click MacXServer.app. macOS will show a dialog saying
>    "MacXServer Not Opened" and "Apple could not verify ... is free of
>    malware." Click **Done**.
> 2. Open **System Settings → Privacy & Security**, scroll to the
>    **Security** section near the bottom.
> 3. Click **Open Anyway** next to the MacXServer entry, authenticate,
>    then confirm.
> 4. Double-click MacXServer.app again. From here on, it launches
>    normally.
>
> This is macOS Sequoia's standard one-time approval for any notarized
> app downloaded from outside the App Store. It is not a malware
> warning specific to MacXServer.

If you switch to .pkg, the copy becomes: "Download
MacXServer-Installer.pkg, double-click, follow the installer.
MacXServer.app is installed to /Applications." Three lines, no
Gatekeeper prose, no browser warning.

## Open questions / commands to run on the test Mac

Settled by research:

- The agent name in the xattr does not affect Gatekeeper. (eclecticlight,
  2017)
- Both Safari- and Chrome-extracted bundles have `com.apple.quarantine`.
  (HackTricks; Safari has `LSFileQuarantineEnabled = true`; Archive
  Utility propagates xattr)
- The "could not verify ... free of malware" dialog is the standard
  Sequoia first-launch dialog for any quarantined notarized app, not a
  notarization failure signal.

Not settled by research alone; need on-Mac data:

**Q1. What is the exact flag value the Chrome-extracted bundle ends up
with vs the Safari-extracted bundle?** Likely `0081` vs `0083`, but
worth checking. Commands, run after downloading once via each browser
into a known location and extracting via the user's natural path:

```sh
# After Safari download + auto-extract:
xattr -p com.apple.quarantine ~/Downloads/MacXServer.app

# After Chrome download + Finder-double-click of the .zip:
xattr -p com.apple.quarantine ~/Downloads/MacXServer.app

# Compare the leading hex field. Also dump full xattr list:
xattr -l ~/Downloads/MacXServer.app
```

**Q2. Does Sequoia actually show the same dialog when Safari is the
path, or did the Safari path get lucky/different?** Reproduce both
paths cleanly. From a Mac that has *never* run MacXServer before (the
test machine), run:

```sh
# Confirm clean state — should be empty:
sqlite3 ~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2 \
  "SELECT LSQuarantineAgentName, LSQuarantineDataURLString, LSQuarantineTypeNumber \
   FROM LSQuarantineEvent ORDER BY LSQuarantineTimeStamp DESC LIMIT 5;"

# Then do the Safari path (download .zip with "Open safe files" ON,
# drag app to Applications):
spctl -a -vvv /Applications/MacXServer.app
sqlite3 ~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2 \
  "SELECT LSQuarantineAgentName, LSQuarantineDataURLString, LSQuarantineTypeNumber \
   FROM LSQuarantineEvent ORDER BY LSQuarantineTimeStamp DESC LIMIT 5;"

# Launch /Applications/MacXServer.app — record which dialog appears.
# Move to Trash, repeat with Chrome path, compare.
```

The `LSQuarantineTypeNumber` will be one of the `LSQuarantineType*`
enum values (web download = 0, other download = 2, sandboxed = 6, etc.,
from `LaunchServices.h`). If Safari produces
`LSQuarantineTypeSandboxed` and Chrome produces
`LSQuarantineTypeWebDownload`, that's a policy-differentiable signal
Gatekeeper could read; that's the most plausible "real" mechanism if
the dialogs really do differ.

**Q3. Is App Translocation involved?** On the test Mac, after each
browser path, before launching, run:

```sh
xattr -l /Applications/MacXServer.app
# Then attempt a launch, and check translocated path:
ps auxww | grep -i MacXServer
lsof -p <pid> | head -20  # to see if running from /private/var/folders/
```

If the Chrome-path launch is translocated and the Safari-path launch is
not, that's the dialog asymmetry's mechanism. Translocation is the most
likely single explanation for "same xattr, different dialog."

**Q4. Does shipping a signed+notarized .pkg actually fix it on Sequoia
15.x as currently shipping?** Build the pkg, sign with Developer ID
Installer, notarize the pkg, staple it. Then on the test Mac, run:

```sh
spctl -a -vvv --type install MacXServer-Installer.pkg
# Double-click the pkg, complete the installer flow, then:
xattr -l /Applications/MacXServer.app
# Expectation: no com.apple.quarantine xattr at all.
# Launch the app and confirm no Gatekeeper dialog.
```

If that path is clean, it's the answer; ship the pkg.

## Sources

- Howard Oakley — xattr: com.apple.quarantine, the quarantine flag (2017)
  https://eclecticlight.co/2017/12/11/xattr-com-apple-quarantine-the-quarantine-flag/
- Howard Oakley — Quarantine and the quarantine flag (2020)
  https://eclecticlight.co/2020/10/29/quarantine-and-the-quarantine-flag/
- Howard Oakley — Quarantine: Apps (2019)
  https://eclecticlight.co/2019/04/25/%F0%9F%8E%97-quarantine-apps/
- Howard Oakley — Gatekeeper and notarization in Sequoia (2024)
  https://eclecticlight.co/2024/08/10/gatekeeper-and-notarization-in-sequoia/
- Howard Oakley — How macOS Sequoia launches an app (2025)
  https://eclecticlight.co/2025/03/26/how-macos-sequoia-launches-an-app/
- Apple Developer News — Updates to runtime protection in macOS Sequoia
  https://developer.apple.com/news/?id=saqachfa
- Apple Support 102445 — Safely open apps on your Mac
  https://support.apple.com/en-us/102445
- Apple Developer Forum 706273 — Notarized app starts if downloaded via
  curl, hangs from Safari
  https://developer.apple.com/forums/thread/706273
- Apple Developer Forum 788787 — "could not verify is free of malware" on
  notarized app from cloud download
  https://developer.apple.com/forums/thread/788787
- Michael Tsai — Sequoia Removes Gatekeeper Contextual Menu Override
  (2024)
  https://mjtsai.com/blog/2024/07/05/sequoia-removes-gatekeeper-contextual-menu-override/
- Jamf — Bypassing the Gate: Gatekeeper flaws
  https://www.jamf.com/blog/gatekeeper-flaws-on-macos/
- HackTricks — macOS Gatekeeper / Quarantine / XProtect
  https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-gatekeeper.html
- rsms — macOS distribution: code signing, notarization, quarantine,
  distribution vehicles (gist)
  https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5
- scriptingosx — Notarization for MacAdmins (2019)
