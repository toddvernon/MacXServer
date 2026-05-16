# swift-x shortcut-mentality audit

A focused pass across opcode categories asking one question: did we ship
a formulaic shortcut that's right for the test corpus but wrong for inputs
we haven't exercised?

## The trigger

QueryTextExtents shipped twice this week. The first cut computed width as
`nChars × cellWidth` — perfectly right for monospace fonts (Monaco), so
all tests passed. Todd then mentioned quickplot's menu font is
`-adobe-helvetica-medium-o-*-12-...` (proportional + italic), and the
formula collapsed: width('M') ≠ width('i'). The fix used real Core Text
per-glyph advances. Same pattern as QueryFont, which still uses
cellWidth-as-uniform-width even for proportional fonts.

The class of bug: handler returns a value computed under a simplifying
assumption that the test corpus shares, so tests don't catch the
divergence from spec. This audit hunts for the rest of that class.

## The audit question

For each opcode: does our handler return the spec-correct answer for
**all** inputs the opcode's spec defines, or is it a shortcut that
happens to fit the corpus?

## Pattern signatures

1. **Formulaic reply.** Handler computes a value via simplifying assumption
   (monospace, single visual, US-ASCII layout, single screen, default
   colormap). Correct under the assumption, wrong outside it.
2. **Hardcoded constants that match the corpus.** Returns the same value
   every time because the only clients we hosted expected it.
3. **Drops a flag/bit silently.** Reads the bits the corpus sets, ignores
   bits it doesn't.
4. **"Always succeeds" without doing the work.** Pre-XError-honesty
   M1-era forgiving-stub residue.
5. **Captured-from-Sun verbatim** where the right answer is "compute from
   local state."
6. **Stored but inert.** Value persists across round-trip (passes tests)
   but never feeds rendering or behavior.

## Forks

| # | File | Scope |
|---|---|---|
| 1 | `audit_replies.md` | Reply-generating opcodes — what's in the reply, where does the value come from, what would a real client outside the corpus get? |
| 2 | `audit_state_mutation.md` | State-mutation opcodes — which CW/value-list bits get acted on, which are stored-but-inert, which are silently dropped? |
| 3 | `audit_drawing.md` | Drawing opcodes — which GC components actually flow through the bridge call and which the bridge ignores? |
| 4 | `audit_constants.md` | Cross-cutting hardcoded-constants sweep — classify every literal return value. |

## Anchoring rules

- Do NOT read `OPCODE_STATUS.md`, `SHORTCUTS.md`, `DECISIONS.md`. The point
  is to find UN-ledgered shortcuts. Known-ledgered items will appear
  redundantly in audit output — that's fine; synthesis filters at the end.
- Read swift-x source (`Sources/`), the X11 spec
  (`reference/x11-protocol-spec/x11protocol.html`), the X11R6 reference
  implementation (`reference/X11R6/xc/programs/Xserver/dix/*.c` and
  neighbors), and the test corpus (`Tests/`) — tests sometimes reveal
  the shortcut by what they DON'T cover.
- Read-only on swift-x. Only write into `audit/`.

## Output format

Per fork: one markdown file with a findings table —

| Opcode | Shortcut found | What real would look like | Severity | Fix-shape |

Severity:
- **load-bearing**: a real client outside our test corpus would visibly
  break. Name the class of client.
- **latent**: would break if X happens (specific client behavior, second
  screen, color mode change). Name the trigger.
- **cosmetic**: spec-violating but no realistic client cares.

End each file with 1-3 sentences of "the pattern I noticed across this
category" — sometimes the meta-observation matters more than the
individual findings.

## Concreteness requirement

Every finding cites `file:line:function`. Vague "the handler is
incomplete" is useless; `ServerSession.swift:3439 queryFont returns
cellWidth for all chars regardless of isMonospace` is what we want.

## Length cap

~400 lines per output file. If you'd exceed it, you've gone too narrow
on minor findings.

## What happens after

Synthesis pass — read all four audit files, dedupe against the existing
SHORTCUTS ledger (which forks don't see), produce a prioritized list of
the UN-ledgered shortcuts ranked by severity.
