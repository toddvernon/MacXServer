#!/bin/sh
#
# Run every x11perf test once against $DISPLAY, record which BadRequest opcode
# (if any) each one trips on, and tally the offenders. Designed to be portable
# to SunOS 4 /bin/sh — no arrays, no $(...), no [[ ]], no GNU-isms.
#
# Usage:
#   ./x11perf-survey.sh                 # uses $DISPLAY
#   ./x11perf-survey.sh -d host:0       # override display
#   ./x11perf-survey.sh -o /tmp/survey  # output dir (default: ./x11perf-results)
#   ./x11perf-survey.sh -q              # quiet, only print summary
#
# Strategy: drive each -test with `-repeat 1 -time 1` so a happy test takes
# ~1 second and a failing test exits at startup. The X11 client lib bails on
# the first BadRequest with a "Major opcode of failed request" line on stderr.
# We grep that line out of each test's log and tally.
#
# Re-runnable: if a per-test log already exists in the output dir, we skip
# that test. Wipe the dir to start fresh.

DISPLAY_ARG=""
OUTDIR="./x11perf-results"
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        -d) DISPLAY_ARG="-display $2"; shift 2 ;;
        -o) OUTDIR="$2"; shift 2 ;;
        -q) QUIET=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)  echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$OUTDIR" || exit 1

# Test list, lifted verbatim from `x11perf -help`. Kept here so we don't have
# to scrape the binary's help output every run (and so adding a build with
# extra tests is a one-line edit).
TESTS="
dot
rect1 rect10 rect100 rect500
srect1 srect10 srect100 srect500
osrect1 osrect10 osrect100 osrect500
tilerect1 tilerect10 tilerect100 tilerect500
oddsrect1 oddsrect10 oddsrect100 oddsrect500
oddosrect1 oddosrect10 oddosrect100 oddosrect500
oddtilerect1 oddtilerect10 oddtilerect100 oddtilerect500
bigsrect1 bigsrect10 bigsrect100 bigsrect500
bigosrect1 bigosrect10 bigosrect100 bigosrect500
bigtilerect1 bigtilerect10 bigtilerect100 bigtilerect500
eschertilerect1 eschertilerect10 eschertilerect100 eschertilerect500
seg1 seg10 seg100 seg500
seg100c1 seg100c2 seg100c3
dseg10 dseg100 ddseg100
hseg10 hseg100 hseg500
vseg10 vseg100 vseg500
whseg10 whseg100 whseg500
wvseg10 wvseg100 wvseg500
line1 line10 line100 line500
dline10 dline100 ddline100
wline10 wline100 wline500
wdline100 wddline100
orect10 orect100 orect500
worect10 worect100 worect500
circle1 circle10 circle100 circle500
dcircle100 ddcircle100
wcircle10 wcircle100 wcircle500
wdcircle100 wddcircle100
pcircle10 pcircle100
wpcircle10 wpcircle100
fcircle1 fcircle10 fcircle100 fcircle500
fcpcircle10 fcpcircle100
fspcircle10 fspcircle100
ellipse10 ellipse100 ellipse500
dellipse100 ddellipse100
wellipse10 wellipse100 wellipse500
wdellipse100 wddellipse100
pellipse10 pellipse100
wpellipse10 wpellipse100
fellipse10 fellipse100 fellipse500
fcpellipse10 fcpellipse100
fspellipse10 fspellipse100
triangle1 triangle10 triangle100
trap1 trap10 trap100 trap300
strap1 strap10 strap100 strap300
ostrap1 ostrap10 ostrap100 ostrap300
tiletrap1 tiletrap10 tiletrap100 tiletrap300
oddstrap1 oddstrap10 oddstrap100 oddstrap300
oddostrap1 oddostrap10 oddostrap100 oddostrap300
oddtiletrap1 oddtiletrap10 oddtiletrap100 oddtiletrap300
bigstrap1 bigstrap10 bigstrap100 bigstrap300
bigostrap1 bigostrap10 bigostrap100 bigostrap300
bigtiletrap1 bigtiletrap10 bigtiletrap100 bigtiletrap300
eschertiletrap1 eschertiletrap10 eschertiletrap100 eschertiletrap300
complex10 complex100
64poly10convex 64poly100convex
64poly10complex 64poly100complex
ftext f8text f9text
f14text16 f24text16
tr10text tr24text
polytext polytext16
fitext f8itext f9itext
f14itext16 f24itext16
tr10itext tr24itext
scroll10 scroll100 scroll500
copywinwin10 copywinwin100 copywinwin500
copypixwin10 copypixwin100 copypixwin500
copywinpix10 copywinpix100 copywinpix500
copypixpix10 copypixpix100 copypixpix500
copyplane10 copyplane100 copyplane500
deepcopyplane10 deepcopyplane100 deepcopyplane500
putimage10 putimage100 putimage500
putimagexy10 putimagexy100 putimagexy500
shmput10 shmput100 shmput500
shmputxy10 shmputxy100 shmputxy500
getimage10 getimage100 getimage500
getimagexy10 getimagexy100 getimagexy500
noop pointer prop gc
create ucreate map unmap destroy popup
move umove movetree
resize uresize
circulate ucirculate
"

TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

trap 'echo ""; echo "interrupted — partial results below"; printsummary; exit 130' 2 15

# Pull "Major opcode of failed request:  73 (X_GetImage)" out of a log,
# return e.g. "73 X_GetImage". Empty string if no failure.
extract_fail() {
    grep "Major opcode of failed request" "$1" 2>/dev/null \
      | sed 's/^.*request: *//; s/[()]//g' \
      | head -1
}

printsummary() {
    echo ""
    echo "=========================================="
    echo "x11perf survey summary"
    echo "=========================================="
    echo "total tests:   $TOTAL"
    echo "passed:        $PASSED"
    echo "failed:        $FAILED"
    echo "skipped:       $SKIPPED  (already had logs)"
    echo ""
    echo "BadRequest opcodes by frequency:"
    cat "$OUTDIR"/failures.txt 2>/dev/null \
      | sort | uniq -c | sort -rn \
      | awk '{ printf "  %4d  %s\n", $1, substr($0, index($0,$2)) }'
    echo ""
    echo "Per-test logs in $OUTDIR/<test>.log"
    echo "Combined failure list: $OUTDIR/failures.txt"
}

# Reset the aggregated failure list at the start of each run (per-test logs
# are preserved so re-runs are cheap).
> "$OUTDIR/failures.txt"

for t in $TESTS; do
    TOTAL=`expr $TOTAL + 1`
    LOG="$OUTDIR/$t.log"

    if [ -s "$LOG" ]; then
        SKIPPED=`expr $SKIPPED + 1`
    else
        # -repeat 1 -time 1 makes each happy test cost ~1s. A test that bombs
        # at setup exits immediately, so this loop is bounded by the number of
        # tests that actually run, not by 1s × #tests.
        x11perf $DISPLAY_ARG -repeat 1 -time 1 -$t > "$LOG" 2>&1
    fi

    FAIL=`extract_fail "$LOG"`
    if [ -n "$FAIL" ]; then
        FAILED=`expr $FAILED + 1`
        echo "$FAIL" >> "$OUTDIR/failures.txt"
        [ $QUIET -eq 0 ] && echo "FAIL  -$t  ($FAIL)"
    else
        PASSED=`expr $PASSED + 1`
        [ $QUIET -eq 0 ] && echo "pass  -$t"
    fi
done

printsummary
