#!/bin/bash
# check-opcode-coverage-drift.sh
#
# Flags rows where OPCODES_PUBLIC.yaml's coverage column has drifted
# from OPCODE_STATUS.md's actual implementation status. Run during
# milestone audits and any time you've shipped or stubbed an opcode.
#
# Coverage prefix expected per status keyword (in OPCODE_STATUS.md):
#   impl                              -> "Fully implemented" OR "Implemented"
#   impl (stub|no-op|synthetic|empty) -> "Stub" OR "Implemented" (both honest)
#   stub                              -> "Stub"
#   partial                           -> "Implemented"
#   Not                               -> "Not implemented"
#   (missing from OPCODE_STATUS.md)   -> "Not implemented"
#
# Works on macOS bash 3.2 (no associative arrays).
# Only cross-checks core opcodes; SHAPE extension rows are not algorithmically
# diffed against OPCODE_STATUS.md (the SHAPE table is small enough to eyeball;
# extension-level summaries have no per-row counterpart in the ledger).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS_FILE="${REPO_ROOT}/OPCODE_STATUS.md"
YAML_FILE="${REPO_ROOT}/OPCODES_PUBLIC.yaml"

if [ ! -f "$STATUS_FILE" ]; then
  echo "drift-check: OPCODE_STATUS.md not found at $STATUS_FILE" >&2
  exit 2
fi
if [ ! -f "$YAML_FILE" ]; then
  echo "drift-check: OPCODES_PUBLIC.yaml not found at $YAML_FILE" >&2
  exit 2
fi

# Extract (opcode-number, full-status-cell) from the main core opcode table.
# Full-status preserves the parenthetical (e.g. "impl (stub)") so we can tell
# stub-flavored handlers apart from real impls.
extract_status() {
  awk '
    /^## Status/                     { in_section = 1; next }
    in_section && /^## /             { in_section = 0 }
    in_section && /^\| *[0-9]+ *\|/ {
      n = $0; sub(/^\|/, "", n)
      split(n, a, "|")
      gsub(/^ +| +$/, "", a[1])
      gsub(/^ +| +$/, "", a[3])
      if (a[1] ~ /^[0-9]+$/) {
        print a[1] "\t" a[3]
      }
    }
  ' "$STATUS_FILE"
}

# Extract (opcode-number, first-line-of-coverage) from OPCODES_PUBLIC.yaml.
# Handles YAML literal block scalars (`coverage: |` then indented content).
extract_coverage() {
  awk '
    /^core_opcodes:/                          { in_core = 1; next }
    in_core && /^[a-zA-Z]/                    { in_core = 0 }
    in_core && /^  - number:/ {
      sub(/^.*number:[ \t]*/, "")
      cur = $0; in_lit = 0; next
    }
    in_core && /^    coverage: *\|/ {
      in_lit = 1; next
    }
    in_core && in_lit && /^      [^ ]/ {
      sub(/^ +/, "")
      if (cur != "") { print cur "\t" $0; cur = "" }
      in_lit = 0; next
    }
    in_core && /^    coverage:/ && cur != "" {
      sub(/^[ \t]*coverage:[ \t]*/, "")
      gsub(/^"|"$/, "")
      print cur "\t" $0
      cur = ""
    }
  ' "$YAML_FILE"
}

STATUS_TMP=$(mktemp)
YAML_TMP=$(mktemp)
trap "rm -f $STATUS_TMP $YAML_TMP" EXIT

extract_status   | sort -n > "$STATUS_TMP"
extract_coverage | sort -n > "$YAML_TMP"

STATUS_COUNT=$(wc -l < "$STATUS_TMP" | tr -d ' ')
YAML_COUNT=$(wc -l < "$YAML_TMP" | tr -d ' ')

echo "OPCODE_STATUS.md core rows: $STATUS_COUNT"
echo "OPCODES_PUBLIC.yaml core_opcodes: $YAML_COUNT"
echo ""

# Flag duplicate opcodes in OPCODE_STATUS.md (real data bug — same number
# defined twice in the Status section).
DUPES=$(awk -F'\t' '{ print $1 }' "$STATUS_TMP" | sort | uniq -d)
if [ -n "$DUPES" ]; then
  echo "DUPLICATE rows in OPCODE_STATUS.md (each opcode should appear once):"
  for d in $DUPES; do
    grep -E "^${d}	" "$STATUS_TMP" | sed "s/^/  /"
  done
  echo ""
fi

MISMATCHES=0

# Helper: does the YAML coverage start with one of the accepted prefixes?
matches_prefix() {
  local cov="$1"
  shift
  for prefix in "$@"; do
    case "$cov" in
      "${prefix}"*) return 0 ;;
    esac
  done
  return 1
}

# Walk YAML entries.
while IFS=$'\t' read -r num coverage; do
  status_line=$(awk -v n="$num" -F'\t' '$1 == n { print $2; exit }' "$STATUS_TMP")
  status="${status_line:-MISSING}"

  # Distinguish bare "impl" from "impl (stub|no-op|synthetic|empty reply|...)".
  status_kw=$(printf "%s" "$status" | awk '{print $1}')
  status_qualifier=$(printf "%s" "$status" | grep -oE '\([^)]+\)' | tr -d '()' )

  result=0
  case "$status_kw" in
    impl)
      # If the parenthetical implies the handler is hollow, accept Stub OR Implemented.
      if echo "$status_qualifier" | grep -qE 'stub|no-op|synthetic|empty'; then
        if matches_prefix "$coverage" "Stub" "Implemented" "Fully implemented"; then
          result=0
        else
          result=1
        fi
      else
        if matches_prefix "$coverage" "Implemented" "Fully implemented"; then
          result=0
        else
          result=1
        fi
      fi
      ;;
    partial)
      if matches_prefix "$coverage" "Implemented"; then result=0; else result=1; fi
      ;;
    stub)
      if matches_prefix "$coverage" "Stub"; then result=0; else result=1; fi
      ;;
    Not)
      if matches_prefix "$coverage" "Not implemented"; then result=0; else result=1; fi
      ;;
    MISSING)
      if matches_prefix "$coverage" "Not implemented"; then result=0; else result=1; fi
      ;;
    *)
      echo "  ?  opcode $num: unrecognized status keyword '$status_kw' in OPCODE_STATUS.md"
      result=1
      ;;
  esac

  if [ "$result" -ne 0 ]; then
    MISMATCHES=$((MISMATCHES + 1))
    printf "  !  opcode %-4s STATUS=%-30s YAML=%s\n" "$num" "$status" "$coverage"
  fi
done < "$YAML_TMP"

# Flag STATUS rows that are MISSING from YAML.
# Dedupe STATUS_TMP first so duplicate ledger rows (a real data bug we already
# reported above) don't trigger this loop twice.
SEEN=""
while IFS=$'\t' read -r num kw; do
  case " $SEEN " in *" $num "*) continue ;; esac
  SEEN="$SEEN $num"
  found=$(awk -v n="$num" -F'\t' 'BEGIN { f=0 } $1 == n { f=1 } END { print f }' "$YAML_TMP")
  if [ "$found" = "0" ]; then
    MISMATCHES=$((MISMATCHES + 1))
    printf "  !  opcode %-4s in OPCODE_STATUS.md (%s) but missing from OPCODES_PUBLIC.yaml\n" "$num" "$kw"
  fi
done < "$STATUS_TMP"

echo ""
if [ "$MISMATCHES" -eq 0 ]; then
  echo "OK: no coverage drift detected."
  exit 0
else
  echo "DRIFT: $MISMATCHES mismatch(es). Update OPCODES_PUBLIC.yaml coverage fields to match OPCODE_STATUS.md, or vice versa."
  exit 1
fi
