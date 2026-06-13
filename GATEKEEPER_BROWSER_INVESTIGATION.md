# Gatekeeper browser-dependence: dossier for fresh-eyes analysis

This document compiles everything we know about a reproducible difference
between Safari and Chrome downloads of MacXServer triggering different
macOS Gatekeeper behavior on first launch. It is written to be handed to
an analyst with NO prior context on the project, who should read only this
file plus any references they want to look up themselves, and reach their
own conclusions.

You are encouraged to disagree with everything below. None of the three
explanations in the "Competing explanations" section have been verified;
they are pasted in for you to weigh. Your job is to figure out what is
actually happening on the OS, not to ratify any of them.

---

## The observation (what we actually measured)

On the SAME macOS machine (Mac, Sequoia/26 era), with the SAME
MacXServer.app binary published from macxserver.com:

- **Safari**: download the .zip, Safari auto-extracts it, double-click
  `MacXServer.app`. App launches. No Gatekeeper dialog. (Possibly a
  one-time "downloaded from the internet, are you sure?" prompt with an
  Open button, but no blocking dialog.)

- **Chrome**: download the .zip, double-click the .zip in Finder to
  extract via Archive Utility, double-click `MacXServer.app`. macOS shows:

  > **"MacXServer" Not Opened**
  >
  > Apple could not verify "MacXServer" is free of malware that may harm
  > your Mac or compromise your privacy.
  >
  > [ Move to Trash ]   [ Done ]

  No Open button. To launch the app the user must click Done, open System
  Settings > Privacy & Security, scroll to Security, click "Open Anyway",
  authenticate, then double-click the app again and confirm one more
  dialog.

A separate reporter on a different Mac (also Sequoia/26 era) hit the same
"could not verify" dialog. Their download path wasn't fully captured but
was likely a non-Safari browser; they preserved the scene without running
any diagnostics.

---

## What's verified good (don't re-question this)

On 2026-06-11 the published v0.9.0 zip from macxserver.com / the GitHub
release was downloaded onto a known-good Mac and tested:

- `spctl -a -vvv` -> "accepted, source=Notarized Developer ID"
- `stapler validate` -> passes
- `codesign --verify --deep --strict -vvv` -> passes

So the published bytes are signed with a Developer ID, notarized by
Apple, and have a notarization ticket stapled to the .app bundle. The
release pipeline produces a healthy artifact. Whatever causes the
browser-dependent dialog difference is downstream of the build.

---

## Relevant macOS context

- macOS Sequoia (15.x) / macOS 26 changed the Gatekeeper UX. The old
  "right-click > Open" bypass for unverified-but-quarantined apps was
  removed. The "Open Anyway" override now lives only in System Settings
  > Privacy & Security, and only appears there AFTER the user has
  attempted to launch the app once and clicked Done on the block dialog.

- The "could not verify ... is free of malware" wording is the standard
  Sequoia-era quarantine block for ANY downloaded app that has not yet
  been user-approved on this machine, including properly notarized +
  stapled apps. The wording is deliberately alarming; the dialog by
  itself does not tell you whether notarization succeeded or failed.

- A distinct dialog exists: "... is damaged and can't be opened." That
  one indicates an actually-broken signature. We are NOT seeing that one
  here.

- A distinct dialog also exists: "... cannot be opened because the
  developer cannot be verified." That's the unsigned / non-notarized
  variant. We are NOT seeing that one either. The dialog we see is
  specifically "Apple could not verify ... is free of malware."

- The `com.apple.quarantine` extended attribute is not a boolean. Its
  value is a semicolon-separated string of the form
  `flags;timestamp;AgentName;UUID`. The `flags` hex value encodes things
  like whether the file has been opened, whether the user has approved
  the source, and which kind of agent downloaded it. Different browsers
  set different `flags` values and different `AgentName`s.

- LaunchServices maintains an internal database (LSQuarantine) that
  records additional metadata about downloads, including referrer/origin
  URLs. Safari, being Apple-integrated, may populate this differently
  from third-party browsers.

---

## Competing explanations (none verified; weigh them yourself)

### Explanation A: from a neighbor (likely from an LLM)

> Safari takes advantage of its Apple-native privileges to automatically
> extract the file in a way that often strips or satisfies Gatekeeper's
> strict verification requirements for the resulting app. Chrome strictly
> follows third-party security protocols, ensuring the quarantine flag is
> aggressively passed down to the application, triggering the macOS
> Gatekeeper prompt.
>
> [...]
>
> Crucially, when Safari or the built-in macOS Archive Utility extracts
> that zip file, it doesn't always propagate the quarantine flag to the
> executable binary inside correctly under certain conditions, or macOS
> recognizes that it was safely extracted locally by a trusted system
> process. Because the extracted app bundle loses or bypasses the strict
> quarantine restrictions, Gatekeeper treats it as a locally handled file
> and lets it run without triggering the blocked app warning.
>
> If you navigate to your downloads folder and type:
> `xattr MacXServer.app`
>
> For the Chrome version, you will see output like:
> `com.apple.quarantine`
>
> For the Safari version, that line will either be entirely missing or
> contain fewer restrictive parameters.

Testable claim: that the Safari-extracted bundle has either no
`com.apple.quarantine` xattr or a less restrictive value than the
Chrome-extracted bundle. Has not been tested.

### Explanation B: first response from a Claude session

Pushed back on Explanation A's claim that Archive Utility "doesn't
propagate the quarantine flag." Asserted instead that:

> Both browsers DO put `com.apple.quarantine` on the extracted .app. The
> flag isn't missing in either case. But the quarantine xattr isn't a
> boolean. It's `flags;timestamp;AgentName;UUID`, and the `flags` field
> is what Gatekeeper actually reads.
>
> Safari sets the flags to a value that means "user already approved this
> download from a known agent" (Safari is registered with LaunchServices
> as a trusted download agent). Gatekeeper treats that as user-initiated.
>
> Chrome sets the flags to a value that means "downloaded, not yet
> approved," with Chrome's bundle ID as the agent. Gatekeeper treats that
> as stricter, and on Sequoia 26 (where the right-click bypass is gone)
> it surfaces the "could not verify" dialog with only Move to Trash /
> Done.

This explanation also initially raised the possibility that the
notarization ticket wasn't stapled to the .app, then walked it back on
the grounds that if the staple were missing, Safari downloads would also
break (the ticket fetch would fail or be slow); since Safari works,
stapling must be present, so it's not the issue. (Stapling was later
independently confirmed by `stapler validate` on the known-good Mac. So
the walkback was right but for that reason, not by elimination.)

Testable claim: that the difference is in the `flags` field of the
quarantine xattr, not in whether the xattr exists. Specifically, that
the Safari-extracted bundle has a flags value Gatekeeper treats as
user-approved, while the Chrome-extracted bundle has a flags value that
keeps the dialog up.

### Explanation C: Gemini's user-facing version

> If you use Safari: Safari will automatically download and unzip the
> file. You can usually double-click and run MacXServer immediately
> without any security prompts. This happens because Safari handles the
> extraction natively, which sometimes bypasses the system's "Quarantine"
> flag.
>
> If you use Google Chrome, Firefox, or Edge: Your browser will download
> a .zip file. You will need to double-click it to unzip it manually.
> When you try to run the extracted MacXServer app, macOS will likely
> block it and show a warning saying it "cannot be opened because it is
> from an unidentified developer."

Gemini's mechanism story is essentially the same as Explanation A
("Safari bypasses the quarantine flag"). Note: Gemini also misnames the
dialog as the "unidentified developer" one, but we know the actual
dialog is the "could not verify ... free of malware" one. That's a
mistake in Gemini's writeup but irrelevant to the underlying mechanism
question.

---

## Other plausible mechanisms not yet listed above

Be open to mechanisms none of the three explanations raised, including
but not limited to:

- **App Translocation.** macOS sometimes copies a quarantined app to a
  randomized read-only path before launch, depending on whether the user
  has "moved" the app via Finder. Translocation can interact with
  notarization checks in non-obvious ways.
- **Notarization ticket lookup behavior.** Even with a stapled ticket,
  Gatekeeper may still consult Apple online under some conditions, and
  the result of that consultation may depend on the quarantine `flags`
  or `AgentName`.
- **Archive Utility extension handling.** Whether the extracted bundle
  inherits quarantine identically when extracted by Safari (which calls
  Archive Utility from a Safari-owned process) vs. when extracted by
  Finder double-clicking the .zip (which calls Archive Utility from a
  different launch context) may differ.
- **LSQuarantineAgentBundleIdentifier behavior.** Apple may have a
  table of "trusted download agents" baked in, with Safari on it and
  third-party browsers off it.
- **Gatekeeper assessment caching.** Once a binary has been assessed and
  approved on a machine, subsequent launches may not re-check. The
  Safari path may be triggering an approval-on-download that the Chrome
  path doesn't.
- **None of the above.** Maybe it's something else entirely.

---

## What we want to know

1. **What is actually causing the Safari-vs-Chrome difference?** Cite
   evidence. If the conclusion is "we can't know without running these
   specific commands on a fresh Mac," say so and list the commands.

2. **Is there a one-time fix on the publisher's side (us) that makes
   Chrome downloads launch as cleanly as Safari downloads?** Examples
   would be: ship a notarized .pkg (apps installed by signed+notarized
   pkg are not quarantined), ship a notarized .dmg, change the zip
   tooling, set HTTP headers on the download, etc. For each candidate
   fix, say whether it would actually solve the problem and what the
   trade-offs are.

3. **What should we tell users on the download page?** Currently we
   plan to recommend Safari and document the System Settings > Privacy
   & Security > Open Anyway escape hatch for users on other browsers.
   Is that the right copy? Is there anything wrong with it factually?
   Is there a better framing?

---

## What's open for you to look up

You can:

- Read Apple's documentation (Gatekeeper, notarization, quarantine
  xattr, LSQuarantine, App Translocation).
- Read source for known archive utilities (BSD `ditto`, Archive Utility
  is closed-source but behaves like `ditto` in many cases).
- Read public reverse-engineered notes from security researchers (Howard
  Oakley's eclecticlight.co posts, Patrick Wardle's writeups, Apple's
  WWDC sessions on Gatekeeper changes).
- Propose a test on a fresh Mac (we have a test machine available; we
  can run any commands you specify) and tell us what results would
  distinguish the hypotheses.

You can NOT:

- Assume any of Explanations A/B/C is correct. Treat them as input to
  weigh, not premises.

When you report back, be willing to say "I don't know" for parts you
can't resolve without on-machine testing, and list the specific
commands that would resolve them.
