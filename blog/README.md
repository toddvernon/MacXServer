# Blog post stubs for swift-x

Ten post stubs covering the project from inception through the MATCH_SELECT unlock. Stub format: salient facts and pivotal moments, file/commit anchors, what Todd should add in his voice, working title alternatives.

The process:
1. I (Claude) wrote these stubs from project docs + git log + memory + this week's conversation context.
2. Todd fills in his writing voice, motivation, personal color, and any details I missed.
3. Claude comes back, fact-checks Todd's writing, fills out the rest, polishes.

## The arc

| # | File | Date range | Subject |
|---|---|---|---|
| 1 | `0001-the-inception.md` | May 5 | Why I'm writing an X server, two design drivers, five paths to one choice |
| 2 | `0002-capture-first.md` | May 5-6 | Capture tool + framer before any server code |
| 3 | `0003-m1-first-bytes-on-the-wire.md` | May 6-7 | xclock connects and stays connected (M1) |
| 4 | `0004-m2-first-nswindow.md` | May 7 | Real NSWindow on MapWindow (M2) |
| 5 | `0005-m3-first-pixels.md` | May 7 | Clock face renders, live resize (M3) |
| 6 | `0006-the-scaling-battle.md` | May 7-9 | The first foundational design driver: xterm pixel-perfect at modern resolution. The rendering doc, the 2x/3x/integer-only debate, scalable-fonts-only, cell-fits-font in two passes |
| 7 | `0007-live-xterm.md` | May 7-8 | Live xterm implementation: keyboard, scrollback, ANSI color, copy/paste, focus, live resize |
| 8 | `0008-live-xcalc-athena-widgets.md` | May 8 | xcalc, Athena widgets, multi-client, app shell |
| 9 | `0009-the-motif-gauntlet.md` | May 9 | quickplot init, opcode sweep, the parked dead-end |
| 10 | `0010-the-match-select-unlock.md` | May 10 | The Xt time-field bug, dt-apps boot, quickplot turns out to work, reflection |

Total project arc: five days, May 5 to May 10, 2026. Ten posts.

## Voice calibration (from oldsilicon.com/technologies/ samples)

Distilled from Todd's existing published prose, especially the X11 wire-protocol article and the SunOS 4.1.4 mbufs piece.

- **Length and rhythm.** Short punchy sentences alternate with longer technical ones. Rhythmic repetition for cadence ("Function call, function call, function call, done"). Single-word sentences are fine.
- **Register.** Conversational-technical hybrid. "Brutally efficient" and "oddballs" land right next to opcode tables. Precise numbers carry rhetorical weight: "1.3 MB on its own, roughly 90× larger than the entire conversation that drew it."
- **First person, hard.** Memoir framing throughout. "I have a basement full of Sun workstations." Career references land casually: QuickPlot is introduced as "a 2D time-history plotting application that ended up being used at NASA for at least two decades after I left." Personal anchors in almost every paragraph.
- **Humor.** Dry, self-aware. Never jokey. "You know you're dealing with old software when you can so easily do this." "Which is honestly outside what an IPX was sized for anyway."
- **Passionate, not dramatic.** Todd's voice is passionate fact-based, not dramatic. Specificity is the vehicle for passion. "A single 1280×1024×8-bit screenshot of the resulting window would be 1.3 MB on its own, roughly 90× larger than the entire conversation that drew it" carries the feeling that "incredible" or "stunning" would aim at, but better and more honestly. Avoid "the moment the project went from X to Y" framings. Avoid superlatives without quantification. Lead with the concrete fact and let the reader feel the weight; don't tell the reader the weight.
- **Openings.** Concrete observation with a possession or a number. "I have." "A single 1280×1024×8-bit screenshot." Then pivot to mechanics.
- **No em-dashes.** AI tell. Stub authoring sed-stripped them and any fact-check pass keeps them out.
- **No triplicates.** "Not X, not Y, not Z" rhetorical structures are an AI tic. Same for ", and X. and Y. and Z." parallel-clause triples used for emphasis. Literal three-item factual lists are fine ("PolySegment, FillPoly, PolyLine") but rhetorical triples for rhythm get cut.
- **Fact-led.** Body prose leads with facts. Todd adds the humor and the personal beats on his pass; Claude doesn't try to be funny on the fact-check pass.

The thing the stubs are missing: personal context. The "what made you start this," the "QuickPlot ran at NASA," the "I've been thinking about this for years." Those make Todd's prose feel like Todd's. Stubs have the bones; voice goes in those gaps.

## Narrative thread: protocol vs implementation

The intellectual spine of the series. Established in Post 1 as a standalone section, then woven back in as a "thread anchor" callout at the start of Posts 2, 3, 6, 7, 9, and 10.

The core framing: X11 has two lives. As a protocol, it's one of the top technical successes of the Unix era (stable since 1987, network-transparent, the substrate of the workstation era). As an implementation, X.org is the half-million-line tar pit Wayland is trying to throw out. swift-x targets the protocol and writes a modern implementation under it. The successful part of X11 is the part we get to take advantage of, and that's why a five-day X server in Swift on macOS is tractable rather than insane.

This thread answers "isn't writing an X server insane?" and "isn't X11 obsolete?" in one move. It also gives the series a recurring intellectual hook so each post connects to something larger than its immediate technical content.

## Narrative thread: AI collaboration

The partnership is a main element of the series, not a footnote. Five days for a working X server isn't a solo-human pace. The X11 wire-protocol article that's already published opens with "Claude and I wrote." The blog series should keep that frame directly.

How the thread weaves through:

- Post 1 (the why): mostly Todd alone. The architectural decisions predate the code, predate the collaboration.
- Post 2 (capture tool): "Claude and I wrote." Match the existing article's framing.
- Posts 3-8 (implementation, M1 through xcalc): the partnership's normal pace. Five days of work feels like five months under the old model.
- Post 6 (the scaling battle) is one of the two foundational design-driver posts. The 2x/3x/integer debate, cell-fits-font iteration, getting xterm pixel-perfect. Worth being explicit about the partnership here because design iteration of this depth is one of the things AI collaboration accelerates the most.
- Post 9 (Motif gauntlet): both sides hit a dead end. Honest. The "parked it" framing is also honest about partnership limits.
- Post 10 (MATCH_SELECT unlock): the deepest detective work in the series, took both sides. The bug had been latent since M1. Reading the X11R6 source was what found it. Neither side would have found it alone in five days. That's the partnership's real value, and it's the right place to reflect on what AI-assisted systems work actually feels like at this scale.

The frame to avoid: "AI did everything" (cheap, wrong) or "AI was a sidekick" (cheap, dishonest). The actual structure of the partnership is that Todd's the architect with thirty years of context and judgment, Claude's the fast hands and the reader of source files Todd doesn't have time to read. Both sides have failure modes. The interesting story is the integration.

## Process

Todd:
1. Pick a stub, write the body in his voice. Anchors (file paths, commit hashes, dates) and pivotal moments are in the stub. Those round-trip into the final.
2. Tell Claude on handback: audience (retro-Unix enthusiasts vs systems programmers vs AI-collab readers, affects which detours stay), length target.
3. Hand back to Claude for fact-check + fill-in + polish.

## Fact-check pass plan

When Todd hands back a draft:
1. Verify dates against git log
2. Verify commit hashes and file/line refs match current source
3. Verify technical claims are still true (the project has been moving fast)
4. Verify any quotes from docs are accurate
5. Fill in any remaining stub points Todd didn't address
6. Polish for voice consistency

Expected output: a publishable blog post in Todd's voice with Claude as silent collaborator on accuracy and structure.
