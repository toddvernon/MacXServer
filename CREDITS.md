# Credits

swift-x leans on a lot of prior X11 work. This file lists the references that mattered when something was hard to figure out, so the open-source release credits them properly.

Everything below is open source under MIT/X11 (or near-equivalent permissive licenses).

## Major references

- **X11 Protocol Specification** (Scheifler, Gettys, et al., X Consortium). The wire format. Modern render: `https://www.x.org/releases/X11R7.7/doc/xproto/x11protocol.html`. Local copy in `reference/x11-protocol-spec/`.
- **ICCCM** (Rosenthal, Marks, et al.). Window manager properties and protocols, including WM_DELETE_WINDOW. Local copy in `reference/icccm/`.
- **X11R6 source tree** (X Consortium, 1994). The era-correct reference. Especially `xc/programs/Xserver/` for server architecture, `xc/programs/Xserver/hw/sun/` for Sun-specific behavior, and `xc/programs/xclock/Clock.c` for analog rendering.
- **XQuartz** (`github.com/XQuartz`). Most relevant prior art for an X server on macOS. Especially `hw/xquartz/` for NSEvent / NSWindow / NSPasteboard integration patterns.
- **Modern X.org sources** at `gitlab.freedesktop.org/xorg/`: xproto headers, libX11, modern xclock. Used for cross-checks against R6.

## Adaptations

If any specific algorithm or struct layout from these references gets directly ported into a Swift file, the file's header will name the upstream source. List of such files (added as they happen):

(none yet)
