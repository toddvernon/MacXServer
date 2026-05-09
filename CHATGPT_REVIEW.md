# Review and Architectural Feedback: macOS XServer Scaling + Font Strategy

Author: ChatGPT
Audience: Claude Code + Todd
Date: 2026-05-07
Context: Independent review of the swift-x server design.

This is the executive summary preserved for the historical record. The "we should believe Mac font metrics" recommendation was the impetus for the report-vs-render-contract work that landed in `FontResolver.swift`. The final shape of that work is captured in `DECISIONS.md` (2026-05-09) and `XTERM_FONT_QUALITY.md`.

---

## Executive Summary

This is fundamentally the correct architectural direction.

The design understands something XQuartz never fully solved:

> X11 protocol space and modern Retina rendering space are not the same thing.

The proposal correctly separates protocol geometry, device rendering, font metrics, stroke behavior, and compositing into independent scaling domains. That separation is the key insight.

The overall product thesis is excellent:

> Old UNIX/X11 clients believe they are rendering to a classic ~90 DPI workstation display while the Mac secretly renders everything sharply using modern scalable typography and Retina rendering.

That is exactly the right illusion.

## The Strongest Decisions

**Logical root independent from Retina device pixels.** The X server exposes 1280×900 at ~90 DPI with integer protocol coordinates while macOS renders independently at device resolution. Preserves Xt assumptions, Motif layout, xterm geometry logic, and old toolkit font heuristics without exposing Retina to the client. This is the correct abstraction boundary.

**Three-plane scaling model.** Geometry / stroke / font as independent scaling domains is exactly how modern rendering engines avoid blur. Geometry tolerates fractional values; text and strokes cannot. (The original ChatGPT export was truncated here.)

## The principle that drove the metrics work

The font plane's job is to never lie — to expose to the client metrics that exactly describe what the renderer is going to put on screen. Core Text's metrics for the chosen substitute ARE ground truth; any heuristic is a polite fiction the renderer politely ignores. Polite fictions accumulate.

This drove the cell-fits-font decision in `DECISIONS.md` 2026-05-09: integer pointSize, CTFont-derived cell metrics, same CTFont for both QueryFont reply and render. No fictions left.
