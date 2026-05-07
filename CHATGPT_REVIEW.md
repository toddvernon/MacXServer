# Review and Architectural Feedback: macOS XServer Scaling + Font Strategy

Author: ChatGPT  
Audience: Claude Code + Todd  
Context: Modern Swift-based X11 server for macOS targeting classic X11R5/R6 clients, Retina displays, and workstation-authentic behavior.

---

# Executive Summary

This is fundamentally the correct architectural direction.

The design understands something XQuartz never fully solved:

> X11 protocol space and modern Retina rendering space are not the same thing.

The proposal correctly separates:
- protocol geometry
- device rendering
- font metrics
- stroke behavior
- compositing behavior

into independent scaling domains.

That separation is the key insight.

The overall product thesis is excellent:

> Old UNIX/X11 clients believe they are rendering to a classic ~90 DPI workstation display while the Mac secretly renders everything sharply using modern scalable typography and Retina rendering.

That is exactly the right illusion.

---

# The Strongest Decisions

## 1. Logical root independent from Retina device pixels

This is absolutely correct.

The X server should expose a stable logical coordinate system:
- 1280×900
- ~90 DPI
- integer protocol coordinates
- classic X11 expectations

while macOS rendering happens independently at device resolution.

This preserves:
- Xt assumptions
- Motif layout behavior
- xterm geometry logic
- old toolkit font heuristics

without exposing Retina complexity to the client.

This is the correct abstraction boundary.

---

## 2. Three-plane scaling model

This is the most sophisticated part of the design.

Separating:
- geometry
- stroke
- font

is exactly how modern rendering engines avoid blur.

The critical insight is:

```text
Geometry can tolerate fractional values.
Text and strokes cannot.
