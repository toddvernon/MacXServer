# Sunfreeware additions to the bundled Solaris 2.6 image

The Helios tool survey on the current image flagged four agent-
ergonomics gaps. None blocks the seed-daemon build, but they all make
the eventual agentic loop materially less frustrating. This doc
captures what to add, how to add it, and how to fold the install into
the SPARCplug image-prep flow so future bundled images ship with the
tools already present.

Run all install steps as root on the Sun.

## Before installing: sanity check what's already there

The survey only probed for explicitly-prefixed names (`gsed`, `ggrep`,
`gawk`). It's worth one quick look to confirm those tools aren't
already installed under un-prefixed names in `/usr/local/bin`:

```sh
ls /usr/local/bin/ | grep -E '^(sed|grep|awk)$'
for t in sed grep awk; do
    if [ -x /usr/local/bin/$t ]; then
        echo "== $t =="; /usr/local/bin/$t --version 2>&1 | head -1
    fi
done
```

If any of these print a `GNU` line, that tool is effectively present
and you can skip its install below — just add a symlink (e.g.
`ln -s /usr/local/bin/sed /usr/local/bin/gsed`) so PATH-aware tools
that look for the `g`-prefixed name find it.

## What to install

In order of value to the agentic loop:

| Tool   | Why this matters                                                          |
|--------|---------------------------------------------------------------------------|
| `gdb`  | Agent debugger fluency is gdb-shaped, not dbx-shaped. Single biggest win. |
| `gawk` | LLM training assumes GNU awk: gensub, `length(arr)`, `-i inplace`         |
| `gsed` | `-E` extended regex and `-i` in-place edit are GNU-only                   |
| `ggrep`| `-P` perl-regex, `-r` recursive, consistent `-A/-B/-C` context flags      |

## Where to get them

Sunfreeware (`sunfreeware.com`) is the canonical source for prebuilt
GNU on Solaris 2.6. Packages are gzipped `.pkg` archives named like
`gdb-7.5.1-sol26-sparc-local.gz`.

For SPARCplug shipping, mirror the packages locally so the install is
reproducible across machines and survives sunfreeware.com going down:

- Stash the four `.gz` packages in `~/Dropbox/dev/SPARCplug/pkg/`
- `sparcstation-baseline-config.sh` fetches from this local mirror,
  not from the live sunfreeware URL
- Record the exact filename + sha256 in a `pkg/MANIFEST.txt` alongside
  the packages, so we can detect bit-rot

Specific package versions to verify and record at mirror time (these
move over time and the latest-known-good for 2.6 is what we want):

```
gdb-?.?.?-sol26-sparc-local.gz       sha256: <fill in>
gawk-?.?.?-sol26-sparc-local.gz      sha256: <fill in>
sed-?.?.?-sol26-sparc-local.gz       sha256: <fill in>
grep-?.?.?-sol26-sparc-local.gz      sha256: <fill in>
```

## Install recipe (manual, on the Sun)

For each package (replace `<file>` with the actual filename minus
`.gz`):

```sh
gunzip <file>.gz
pkgadd -d <file>
# Answer 'y' to "install conflicting files" prompts. These are usually
# benign overlays of /usr/local/bin entries.
```

After all four installs, flush the shell's command cache so the new
binaries become visible without re-login:

```sh
hash -r          # in bash / sh
rehash           # in tcsh / csh
```

## Validate

Re-run `Tools/helios-tool-survey.sh`. The agent-ergonomics section
should now show all four as `[OK]`:

```
== Highly preferred for agent ergonomics ==
  [OK]   bash    /usr/local/bin/bash
  [OK]   gdb     /usr/local/bin/gdb
  [OK]   less    /usr/local/bin/less
  [OK]   gawk    /usr/local/bin/gawk
  [OK]   gsed    /usr/local/bin/gsed
  [OK]   ggrep   /usr/local/bin/ggrep
```

And the summary line should read:

```
Agent ergonomics:    GOOD (bash + gdb + less + gawk all present)
```

## Folding into the SPARCplug image-prep flow

The bundled disk image should ship with these tools by default — every
new user shouldn't have to repeat the install. Extend
`Tools/sparcstation-baseline-config.sh` with an `install_sunfreeware`
step that runs once at image-bake time:

```sh
install_sunfreeware() {
    pkgdir=/var/tmp/macxserver-sunfreeware
    mkdir -p $pkgdir

    # MIRROR_URL points at the local mirror set at image-prep time
    # (e.g. http://10.0.2.2:8000 for slirp, or a LAN HTTP server).
    for spec in \
        "gdb:gdb-?.?.?-sol26-sparc-local" \
        "gawk:gawk-?.?.?-sol26-sparc-local" \
        "sed:sed-?.?.?-sol26-sparc-local" \
        "grep:grep-?.?.?-sol26-sparc-local"
    do
        name=`echo $spec | cut -d: -f1`
        pkg=`echo $spec | cut -d: -f2`
        echo "Installing $name ($pkg)..."
        wget -q -O $pkgdir/$pkg.gz $MIRROR_URL/pkg/$pkg.gz || {
            echo "Failed to download $pkg" >&2; return 1; }
        gunzip $pkgdir/$pkg.gz
        # -n: non-interactive; <pkginst> is the package name pkgadd
        # asks for when run interactively; get the actual value via
        # 'pkginfo -d $pkgdir/$pkg' once during mirror prep.
        pkgadd -n -d $pkgdir/$pkg <pkginst>
    done
    rm -rf $pkgdir
}
```

Notes for the implementer:
- `-n` (non-interactive) requires the exact pkginst name as the last
  argument. Find it by running `pkginfo -d <file>` once during mirror
  prep and recording it next to the sha256 in `pkg/MANIFEST.txt`.
- The script should be idempotent: skip the install if the binary
  is already present and reports GNU.
- Hook the new function into the main flow at the same point the rest
  of the baseline edits run.

## What's deliberately NOT on the list

Came up in the survey but staying off the install set:

- **perl, python** — Useful, but the Mac has them. Sun-side scripting
  via Perl/Python isn't worth the install footprint until something
  specifically needs it.
- **gtar** — Sun `tar` works for our use case. GNU tar conflicting with
  `/usr/bin/tar` in PATH creates subtle "which tar did I get" bugs.
  Skip unless we hit a Sun-tar limit.
- **git, cvs, rcs** — Version control happens Mac-side. Files reach
  the Sun via the access server (post-Helios) or HTTP (pre-Helios),
  not via git.
- **ssh, sshd** — slirp telnet covers the bundled case; ssh adds key
  setup and sshd config for no win in the bundled-SS-5 case. Might
  come back for real-Sun-hardware Helios.
- **curl** — already installed but missing `libssh2.so.1`. Leave
  alone; `wget` covers downloads. If we ever need curl, install
  libssh2 first.
