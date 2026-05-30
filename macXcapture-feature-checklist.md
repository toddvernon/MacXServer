# macXcapture Feature Checklist

## Why This Document Exists

macXcapture is a transparent X11 proxy that captures the wire protocol to a binary `.xtap` file, with 
a viewer that decodes frames into a syntax-highlighted form. The thesis of the project is that X11 
has never had a real `pcap` equivalent: a capture format and tooling pair that makes protocol-level 
debugging routine, shareable, and archivable.

Wireshark's X dissector exists but is incomplete on the extension surface and isn't workflow-integrated 
for X work. `xtruss` is good for tracing a single client live but doesn't produce shareable 
artifacts. `xscope` and `xmon` are ancient and barely maintained. None of these cover the modern 
extension surface — RENDER, XKB, XInput2, RandR, DAMAGE, COMPOSITE, XFIXES, Present — well enough to be the standard tool.

The opportunity is to become that standard tool. If `.xtap` files become something X developers exchange 
the way network engineers exchange `.pcap` files — attached to bug reports, used in regression tests, 
archived against future debugging — then macXcapture stops being "a useful tool" and becomes 
infrastructure the community standardizes on. That's a substantially larger outcome 
than the obvious framing of "a debugging utility for macXserver."

This document is a scorecard. It's meant to give an honest inventory of where macXcapture 
is today against the full value chain of X11 protocol capture and analysis, and to surface where the 
highest-leverage gaps are. For each item below, mark **Yes / Partial / No / N/A**, and back each answer 
with a concrete code reference (file:line or symbol name) so a third party can verify. 
"Partial" answers should specify what's missing to reach Yes.

Items that score No today but rank high on potential audience impact — especially items in §8 (Replay), 
§6 (Analysis Aids), and §4 (Extension Coverage) — are the ones most likely to turn macXcapture 
from a useful tool into infrastructure.

---

## 1. Core Capture

- [ ] Transparent TCP proxy (listens on `:N`, forwards to real display)
- [ ] Transparent Unix socket proxy (`/tmp/.X11-unix/XN`)
- [ ] Handles X11 connection setup (byte order, auth, server reply)
- [ ] Supports MIT-MAGIC-COOKIE-1 authentication passthrough
- [ ] Supports XDM-AUTHORIZATION-1 passthrough
- [ ] Handles abrupt client/server disconnects without losing buffered frames
- [ ] Survives partial reads/writes on either side (proper framing recovery)
- [ ] Multi-client capture in a single session (multiple clients through one proxy)
- [ ] Concurrent independent capture sessions (multiple proxies, multiple files)
- [ ] Configurable listen address and forward target
- [ ] SSH-tunnel friendly (works behind `ssh -X` style forwarding)
- [ ] IPv4 and IPv6 support

## 2. Capture File Format (.xtap)

- [ ] Documented binary format with public spec
- [ ] Magic bytes for file type identification
- [ ] Major/minor version field with defined compatibility rules
- [ ] Endianness flag in header
- [ ] Capture metadata block (timestamp, hostnames, capture tool version, OS)
- [ ] Per-frame timestamps (microsecond or nanosecond resolution)
- [ ] Direction tag per frame (client→server, server→client)
- [ ] Captured QueryExtension exchanges stored or indexed for opcode resolution
- [ ] Extension opcode mapping embedded in file (not derived at view time)
- [ ] Frame length-prefixing for safe forward-skipping
- [ ] Optional compression (gzip, zstd, or none) declared in header
- [ ] Append-safe (can resume captures, or merge files)
- [ ] Checksum or integrity field per frame or file
- [ ] Indexable for fast seek (jump to frame N without scanning from frame 0)

## 3. Protocol Decoding — Core X11

- [ ] All core requests decoded with field names
- [ ] All core replies decoded
- [ ] All core events decoded
- [ ] All core errors decoded
- [ ] Atom values resolved to names (tracking InternAtom and GetAtomName)
- [ ] Resource IDs (windows, pixmaps, GCs, fonts, cursors, colormaps) tracked across the session
- [ ] Resource creation lineage shown (this Pixmap was created at frame N)
- [ ] Resource lifetime tracked (freed at frame M, used-after-free flagged)
- [ ] Keysym values decoded to symbolic names
- [ ] Modifier masks decoded symbolically
- [ ] Visual and depth references resolved against the server's setup reply
- [ ] Property values decoded with type awareness (STRING, UTF8_STRING, ATOM, CARDINAL, etc.)

## 4. Protocol Decoding — Extensions

For each: requests + replies + events + errors decoded.

- [ ] BIG-REQUESTS
- [ ] XC-MISC
- [ ] SHAPE
- [ ] MIT-SHM
- [ ] XInput / XInput2
- [ ] XKEYBOARD (XKB)
- [ ] RENDER
- [ ] RANDR
- [ ] COMPOSITE
- [ ] DAMAGE
- [ ] XFIXES
- [ ] Present
- [ ] DRI3
- [ ] SYNC
- [ ] GLX (at least request/reply structure; opaque GL bytecode acknowledged)
- [ ] DPMS
- [ ] XTEST
- [ ] RECORD
- [ ] SECURITY
- [ ] XINERAMA
- [ ] XF86VidMode
- [ ] DBE (Double Buffer Extension)
- [ ] XKB virtual modifiers and group state shown symbolically
- [ ] RENDER Picture/GlyphSet objects tracked across requests
- [ ] RENDER glyph uploads previewable (visual glyph display, not just bytes)

## 5. Viewer — Display and Navigation

- [ ] Syntax-highlighted decoded frame view
- [ ] Hex dump pane synchronized with decoded view
- [ ] Frame list with timestamps, direction, opcode summary
- [ ] Jump to frame by number
- [ ] Jump to next/previous frame matching filter
- [ ] Filter by opcode / extension / direction / resource ID
- [ ] Search by atom name, resource ID, or arbitrary byte pattern
- [ ] Per-frame "follow this resource" navigation (show all frames touching window 0x4000003)
- [ ] Timeline view (frames over time, optionally grouped by client)
- [ ] Side-by-side request/reply pairing for round-trip requests
- [ ] Latency annotations between request and matching reply
- [ ] Bookmark frames within a capture
- [ ] Export selected frames as a new `.xtap` file

## 6. Viewer — Analysis Aids

- [ ] Resource leak detection (resources created but never freed)
- [ ] Use-after-free detection (resource referenced after FreeX)
- [ ] Unknown opcode flagging (extension used without QueryExtension first)
- [ ] Protocol error highlighting (error replies linked to causing request)
- [ ] Round-trip latency histogram
- [ ] Frame size statistics
- [ ] Most-used opcodes / extensions report
- [ ] Glyph cache hit/miss inference for RENDER traffic
- [ ] Damage region overlay visualization (if COMPOSITE/DAMAGE in capture)
- [ ] Pixmap content preview (where image data is captured)

## 7. Live Mode and Streaming

- [ ] Live view while proxy is capturing (tail mode)
- [ ] Live filtering (drop frames matching filter from on-disk capture)
- [ ] Configurable capture truncation (max bytes per frame)
- [ ] Configurable file rotation (size-based or time-based)
- [ ] Ring buffer mode (keep last N MB only)

## 8. Replay and Test

- [ ] Replay capture as a synthetic client against a real X server
- [ ] Replay capture as a synthetic server against a real client
- [ ] Diff two captures (frame-level structural diff)
- [ ] Generate conformance test from capture (golden-file style)
- [ ] Inject latency / packet loss / reordering during replay (chaos test)
- [ ] Fuzz mode: mutate frames during proxy forward for robustness testing

## 9. Integration and Interop

- [ ] Command-line invocation suitable for scripting
- [ ] Exit codes meaningful for CI use
- [ ] Export to Wireshark `.pcap` (with X dissector compatibility) for cross-tool workflows
- [ ] Import from existing `xtruss` / `xscope` output (if feasible)
- [ ] JSON export of decoded frames for downstream analysis tools
- [ ] Library form of the decoder usable independently of the viewer
- [ ] Bindings or FFI for Python / Swift / C++ for custom analysis scripts
- [ ] Stable on-disk format suitable for archival (multi-year `.xtap` files still readable)

## 10. Platform and Distribution

- [ ] macOS native build (code-signed, notarized binary)
- [ ] Apple Silicon and Intel binaries
- [ ] Runs against macXserver
- [ ] Runs against XQuartz
- [ ] Runs against remote Linux Xorg over TCP
- [ ] Runs against Xwayland over Unix socket forwarded via SSH
- [ ] Linux build (so capture tooling isn't macOS-locked)
- [ ] Homebrew formula or cask
- [ ] Standalone `.app` for the viewer
- [ ] CLI-only mode for headless capture (server-side recording)

## 11. Documentation

- [ ] `.xtap` format specification document
- [ ] User guide for the viewer
- [ ] Cookbook of common debugging recipes
- [ ] Worked examples (real bugs, captured and diagnosed via macXcapture)
- [ ] API documentation for the decoder library
- [ ] Comparison page against `xtruss`, `xscope`, Wireshark X dissector
- [ ] Tutorial: "Your first capture in five minutes"

## 12. Security and Privacy

- [ ] Captures clearly marked as potentially containing sensitive content (keystrokes, clipboard, screen content)
- [ ] Redaction mode (strip property values, keystroke contents, image data) for sharing captures
- [ ] Cookie / auth data redaction by default in saved files
- [ ] Documentation calling out the dual-use nature of capture tools
