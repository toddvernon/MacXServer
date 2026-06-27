#!/usr/bin/env python3
# Regenerates Sources/SwiftXServer/AcknowledgementsLicenseTexts.swift from the
# canonical license files that ship in this repo and in the sibling SPARCplug
# checkout (the QEMU/Solaris engine bundled into the app).
#
# The Acknowledgements screen embeds the FULL verbatim text of every license we
# have an obligation under (MIT, GPLv2, LGPL 2.1, BSD-3-Clause, Apache-2.0, and
# the X11 / X Consortium license that governs the X11R6 code we transcribed).
# Rather than hand-copy ~1500 lines of legal text into a Swift literal (and get
# a character wrong), we read the real files here and emit raw string constants.
#
# Assumes the SPARCplug repo is checked out as a sibling: ~/dev/X and
# ~/dev/SPARCplug. Run from anywhere; paths are resolved relative to this file.
#
#   python3 Tools/regen_licenses.py
#
# A couple of license bodies are not on disk in this tree (the X Consortium
# text lives inline in our ported file headers; libslirp is fetched at build
# time via a meson wrap, so its COPYRIGHT never lands in the tree). Those are
# kept as literals below, matching the upstream text.

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
X = os.path.normpath(os.path.join(HERE, ".."))
SPARC = os.path.normpath(os.path.join(X, "..", "SPARCplug"))

OUT = os.path.join(X, "Sources", "SwiftXServer", "AcknowledgementsLicenseTexts.swift")

# (Swift constant name, absolute path to the canonical file)
FROM_FILE = [
    ("apache2",          os.path.join(X, "LICENSE")),
    ("mitLibvterm",      os.path.join(X, "Sources", "CVTerm", "LICENSE")),
    ("gpl2",             os.path.join(SPARC, "qemu", "COPYING")),
    ("lgpl21",           os.path.join(SPARC, "qemu", "COPYING.LIB")),
    ("bsd3SoftFloat",    os.path.join(SPARC, "qemu", "subprojects", "berkeley-softfloat-3", "COPYING.txt")),
    ("bsd3KeycodeMapDB", os.path.join(SPARC, "qemu", "subprojects", "keycodemapdb", "LICENSE.BSD")),
]

# The X11 / X Consortium license, exactly as retained in our ported file
# headers (e.g. Sources/SwiftXServerCore/Region/Region.swift). This is the
# license that governs every file we transcribed from the X11R6 reference
# implementation.
X11_CONSORTIUM = """Copyright (c) 1987, 1988, 1989  X Consortium

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
X CONSORTIUM BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN
AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Except as contained in this notice, the name of the X Consortium shall not be
used in advertising or otherwise to promote the sale, use or other dealings
in this Software without prior written authorization from the X Consortium."""

# libslirp is fetched at build time via a meson wrap subproject, so its
# COPYRIGHT file never lands in the SPARCplug tree. This is the upstream
# BSD-3-Clause text (gitlab.freedesktop.org/slirp/libslirp, COPYRIGHT).
SLIRP_BSD3 = """libslirp is distributed under a BSD-3-Clause license.

Copyright (c) 1995 Danny Gasparovski, and subsequent libslirp contributors.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

This package is fetched verbatim from upstream at build time; the
authoritative per-file copyright notices live in the upstream repository
linked from this entry."""

LITERALS = [
    ("x11Consortium", X11_CONSORTIUM),
    ("bsd3Slirp", SLIRP_BSD3),
]


def sanitize(text):
    # GNU license files (GPL/LGPL) embed form-feed (0x0C) page breaks and the
    # odd other control char. Swift rejects unprintable ASCII in source, and
    # they carry no legal meaning, so drop every control char except tab and
    # newline. Pure text in, pure text out.
    return "".join(c for c in text if c in "\t\n" or ord(c) >= 0x20)


def read(path):
    if not os.path.exists(path):
        sys.exit("missing license file: %s\n(is the SPARCplug repo checked out as a sibling of X?)" % path)
    with open(path, "r", encoding="utf-8") as f:
        return sanitize(f.read()).rstrip("\n")


def emit_const(name, text):
    # Swift raw multiline string. The closing delimiter sits at column 0 so no
    # indentation is stripped from the body. License texts never contain the
    # `"""#` delimiter, so a single-hash raw string is safe.
    return '    static let %s = #"""\n%s\n"""#\n' % (name, text)


def main():
    parts = []
    parts.append("// GENERATED by Tools/regen_licenses.py -- do not edit by hand.")
    parts.append("//")
    parts.append("// Full verbatim license texts embedded in the Acknowledgements screen.")
    parts.append("// Sourced from the canonical license files in this repo and the sibling")
    parts.append("// SPARCplug checkout. Re-run the generator if any upstream license changes.")
    parts.append("")
    parts.append("enum LicenseText {")
    blocks = []
    for name, path in FROM_FILE:
        blocks.append(emit_const(name, read(path)))
    for name, text in LITERALS:
        blocks.append(emit_const(name, text))
    parts.append("\n".join(blocks))
    parts.append("}")
    out = "\n".join(parts) + "\n"
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(out)
    print("wrote %s (%d bytes)" % (OUT, len(out)))


if __name__ == "__main__":
    main()
