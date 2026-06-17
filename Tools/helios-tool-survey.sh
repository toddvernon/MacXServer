#!/bin/sh
# helios-tool-survey.sh -- inventory the Solaris guest for Helios bring-up.
#
# Run on the Sun side (inside the SS-5 emulator or on real hardware):
#   sh helios-tool-survey.sh
#   sh helios-tool-survey.sh > survey.txt  (capture to file)
#
# Reports what's present, what's missing, and what the gaps mean for:
#   - building the cx-based seed access server (the boot-server step)
#   - the day-to-day agentic loop on the Sun once the seed is up
#
# Pure read-only. No sudo, no installs, no edits. Safe to run repeatedly.
# Written for Solaris 2.6 /bin/sh (Bourne, no $(...), no [[ ]], no local).

# Cover the common 2.6-era locations: sunfreeware in /usr/local,
# Solaris Companion CD in /opt/sfw, Blastwave in /opt/csw, Sun's own
# in /usr/sfw + /usr/ccs + /usr/openwin + /usr/dt + /usr/ucb.
PATH=/usr/local/bin:/usr/local/sbin:/opt/sfw/bin:/opt/sfw/sbin:/opt/csw/bin:/usr/sfw/bin:/usr/openwin/bin:/usr/dt/bin:/usr/ccs/bin:/usr/ucb:/usr/bin:/usr/sbin:/sbin
export PATH

# ------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------

# find_cmd <name> -> echoes absolute path if found, returns 0/1
find_cmd() {
    for d in `echo $PATH | tr ':' ' '`; do
        if [ -x "$d/$1" ]; then
            echo "$d/$1"
            return 0
        fi
    done
    return 1
}

# version_of <cmd> -> echoes one-line version blurb
# tries --version, then -V, then -v; gives up cleanly
version_of() {
    v=`$1 --version 2>&1 | head -1`
    case "$v" in
        *"illegal option"*|*"invalid option"*|*"unknown option"*|*"not found"*|*usage*|*Usage*)
            v=`$1 -V 2>&1 | head -1`
            case "$v" in
                *"illegal option"*|*"invalid option"*|*"unknown option"*|*usage*|*Usage*)
                    v=`$1 -v 2>&1 | head -1`
                    case "$v" in
                        *"illegal option"*|*"invalid option"*|*"unknown option"*|*usage*|*Usage*)
                            v="(present; version probe failed)"
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac
    echo "$v"
}

# probe <name> <category-label> <why-it-matters>
# Prints OK + path + version, or MISS + reason
probe() {
    name=$1; why=$2
    p=`find_cmd $name`
    if [ -n "$p" ]; then
        ver=`version_of $name`
        printf "  [OK]   %-12s  %s\n" "$name" "$p"
        printf "                       %s\n" "$ver"
    else
        printf "  [MISS] %-12s  %s\n" "$name" "$why"
    fi
}

section() {
    echo ""
    echo "== $1 =="
}

# ------------------------------------------------------------------------
# system info
# ------------------------------------------------------------------------

section "System info"
echo "  Date:    `date 2>/dev/null`"
echo "  Host:    `uname -n 2>/dev/null` (`uname -srm 2>/dev/null`)"
echo "  Hardware:`uname -i 2>/dev/null` / `uname -p 2>/dev/null`"
echo "  User:    `id 2>/dev/null`"
echo "  Shell:   $SHELL"
if [ -f /etc/release ]; then
    echo "  Release:"
    sed 's/^/    /' /etc/release
fi
echo "  PATH:    $PATH"

# ------------------------------------------------------------------------
# required for seed server build (cx C++ + daemon)
# ------------------------------------------------------------------------

section "Required for seed server build (cx C++ + daemon)"
probe g++       "need a C++ compiler to build cx + the seed daemon"
probe gcc       "C compiler (helpful even if you're using g++)"
probe cc        "any cc -- check whether it's g++-wrapped or the Sun K&R stub"
probe gmake     "cx makefiles assume GNU make features"
probe make      "Sun make is acceptable fallback but rejects \$(...) and GNU pattern rules"
probe ar        "static-library archiver"
probe ranlib    "archive index builder (some GNU setups don't need it; harmless to have)"
probe ld        "linker"
probe as        "assembler (gcc invokes it; if missing, gcc compiles fail)"

# Identify whether /usr/ucb/cc is the bundled-K&R-stub-or-not.
# The stub says "language optional software package not installed" when invoked.
ucb_cc=/usr/ucb/cc
if [ -x "$ucb_cc" ]; then
    stub_test=`$ucb_cc 2>&1 | head -1`
    case "$stub_test" in
        *"optional software"*|*"not installed"*)
            echo ""
            echo "  Note: /usr/ucb/cc is the bundled Sun K&R stub (no real compiler)."
            echo "        Anything that just says 'cc' picks this up by default; rely on g++."
            ;;
    esac
fi

# ------------------------------------------------------------------------
# compile sanity -- prove g++ actually works end-to-end
# ------------------------------------------------------------------------

section "Compile sanity (small C++ build + run)"
gpp=`find_cmd g++`
if [ -z "$gpp" ]; then
    echo "  [SKIP] g++ not found; can't probe"
else
    tmp=/tmp/heliossurv_$$
    cppfile=$tmp.cpp
    binfile=$tmp.bin
    logfile=$tmp.log
    cat > $cppfile <<'CPPEOF'
#include <iostream>
#include <string>
int main(int argc, char** argv) {
    std::string s = "ok";
    std::cout << s << std::endl;
    return 0;
}
CPPEOF
    if $gpp -o $binfile $cppfile > $logfile 2>&1; then
        out=`$binfile 2>&1`
        if [ "$out" = "ok" ]; then
            echo "  [OK]   g++ compiles + links + runs C++ (stdlib + iostream)."
        else
            echo "  [FAIL] g++ built a binary but it printed: $out"
        fi
    else
        echo "  [FAIL] g++ failed to build a trivial C++ program:"
        sed 's/^/         /' $logfile
    fi
    rm -f $cppfile $binfile $logfile
fi

# Same for a tiny socket test (uses POSIX sockets only; if this builds, the
# seed daemon's TCP listener will too).
section "Socket headers + libsocket linkable"
if [ -z "$gpp" ]; then
    echo "  [SKIP] g++ not found"
else
    tmp=/tmp/heliossurv2_$$
    cppfile=$tmp.cpp
    binfile=$tmp.bin
    logfile=$tmp.log
    cat > $cppfile <<'CPPEOF'
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <iostream>
int main() {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { std::cout << "fail"; return 1; }
    close(s);
    std::cout << "ok" << std::endl;
    return 0;
}
CPPEOF
    # Solaris needs -lsocket -lnsl explicitly on the link line.
    if $gpp -o $binfile $cppfile -lsocket -lnsl > $logfile 2>&1; then
        out=`$binfile 2>&1`
        if [ "$out" = "ok" ]; then
            echo "  [OK]   Sockets compile + link (-lsocket -lnsl) and socket() returns a fd."
        else
            echo "  [FAIL] Built but socket() returned an error: $out"
        fi
    else
        echo "  [FAIL] Couldn't link with -lsocket -lnsl:"
        sed 's/^/         /' $logfile
    fi
    rm -f $cppfile $binfile $logfile
fi

# ------------------------------------------------------------------------
# highly preferred for agent ergonomics
# ------------------------------------------------------------------------

section "Highly preferred for agent ergonomics (Helios v0/v1 quality of life)"
probe bash      "LLM training is bash-shaped; removes whole class of sh-vs-bash mistakes"
probe gdb       "agent debugger fluency is gdb-shaped, not dbx"
probe less      "paging long output sensibly (Sun's 'more' is annoying)"
probe gawk      "GNU awk -- AI's awk training assumes GNU features"
probe gsed      "GNU sed -- in-place edit and -E are GNU-only"
probe ggrep     "GNU grep -- agent expects -P and -r everywhere"
probe nawk      "Sun's newer awk -- fallback if gawk missing"
probe vim       "useful for one-off Sun-side edits"

# ------------------------------------------------------------------------
# nice to have
# ------------------------------------------------------------------------

section "Nice to have (helpful for v1+, not blocking)"
probe perl      "small scripting and Sun-side utilities"
probe python    "rare on 2.6 but very useful if present"
probe tar       "Sun tar lacks -z; gnu tar handles compressed archives"
probe gtar      "GNU tar explicitly"
probe gzip      "decompressing downloaded source"
probe bzip2     "ditto for .bz2"
probe unzip     "for .zip archives"
probe rsync     "fast file transfer (useful even though we'll have access server)"
probe wget      "downloading source tarballs"
probe curl      "ditto"
probe ssh       "client (for ssh-out, e.g. to a Mac-side service)"
probe sshd      "server (if you want a backup channel besides telnet)"
probe git       "very unlikely on 2.6, but check"
probe cvs       "still relevant for vintage code"
probe rcs       "Solaris 2.6 may have it bundled"
probe patch     "applying diffs"
probe diff      "Sun's diff is fine but worth confirming present"
probe gdiff     "GNU diff if installed"

# ------------------------------------------------------------------------
# workspace / filesystem
# ------------------------------------------------------------------------

section "Workspace / filesystem"
for d in /tmp /var/tmp /export/home /export/dev /home /opt /usr/local; do
    if [ -d "$d" ]; then
        # writable for current user?
        touchtest=$d/.heliossurv_w_$$
        if ( : > $touchtest ) 2>/dev/null; then
            rm -f $touchtest
            w="writable"
        else
            w="not writable by `id -un 2>/dev/null || echo current user`"
        fi
        # free space, KB
        free=`df -k $d 2>/dev/null | tail -1 | awk '{print $4}'`
        echo "  [DIR] $d -- $w, free: ${free} KB"
    else
        echo "  [---] $d -- does not exist"
    fi
done

# ------------------------------------------------------------------------
# what's already in /usr/local/bin (first glance)
# ------------------------------------------------------------------------

section "Already installed in /usr/local/bin (first 60 entries)"
if [ -d /usr/local/bin ]; then
    ls /usr/local/bin 2>/dev/null | head -60 | awk '{printf "  %s\n", $0}'
    total=`ls /usr/local/bin 2>/dev/null | wc -l | awk '{print $1}'`
    echo "  ... (total $total entries)"
else
    echo "  /usr/local/bin not present"
fi

# ------------------------------------------------------------------------
# rolled-up summary
# ------------------------------------------------------------------------

section "Summary"

ready_seed=yes
need_seed=""
for tool in g++ ar ld; do
    if find_cmd $tool > /dev/null; then :; else
        ready_seed=no
        need_seed="$need_seed $tool"
    fi
done
# make: either gmake or system make is ok
if find_cmd gmake > /dev/null || find_cmd make > /dev/null; then :; else
    ready_seed=no
    need_seed="$need_seed make-or-gmake"
fi

if [ "$ready_seed" = "yes" ]; then
    echo "  Seed-server build:   READY (have C++ compiler + make + ar/ld)"
else
    echo "  Seed-server build:   NOT READY -- missing:$need_seed"
fi

ergo_missing=""
for tool in bash gdb less gawk; do
    if find_cmd $tool > /dev/null; then :; else
        ergo_missing="$ergo_missing $tool"
    fi
done
if [ -z "$ergo_missing" ]; then
    echo "  Agent ergonomics:    GOOD (bash + gdb + less + gawk all present)"
else
    echo "  Agent ergonomics:    PARTIAL -- missing:$ergo_missing"
fi

echo ""
echo "  (Specific gap interpretation in the sections above. This script does"
echo "   not install anything; copy the output back to the Mac and we can"
echo "   decide what to pkgadd / build from source / curate in"
echo "   /export/dev/tools later.)"

echo ""
echo "Done."
