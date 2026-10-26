#!/usr/bin/env bash
#
# run_vector_tests.sh - Run the riscv-vector-tests Zve32x CTest suite and write
# a PASS / TIMEOUT / FAIL report (with the failing test-case number).
#
# Each test ELF is self-verifying (Spike-derived reference): it exits 0 on
# success, or with the number of the first failing test case.
#
# Usage:
#   scripts/run_vector_tests.sh [build-dir] [timeout] [--record FILE] [--exclude FILE]
#
#   [build-dir]   CMake build directory                [default: <project>/programs/build]
#   [timeout]     Per-test timeout in seconds          [default: 20]
#   --record FILE Merge this run's PASSED tests into FILE (cumulative union).
#                 Default: <project>/programs/build/suites/riscv-vector-tests/report/passed.txt.
#                 Delete FILE to reset. Pass the same FILE to --exclude on a later run to skip
#                 everything that has already passed.
#   --exclude FILE  Run only the tests NOT listed in FILE (one test name per
#                 line, '#' starts a comment). This adds `ctest -E <regex>`.
#
# Environment:
#   RVVT_JOBS          Parallel CTest jobs            [default: $(nproc)]
#   RVVT_SPIKE_INSTALL Installed Spike prefix (auto-detected if omitted)
#   RVVT_TEST_TIMEOUT  Default timeout if [timeout] is omitted
#
# Note: the suite registers each test with a CTest TIMEOUT property (which
# overrides `ctest --timeout`), so this script reconfigures the build with
# -DRVVT_TEST_TIMEOUT=<t> whenever the requested timeout changes.

set -uo pipefail
# Intentionally no `set -e`: tests are expected to fail (nonzero exit), and a
# reporting script must always complete and write its report regardless.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OUT_DIR="$PROJECT_ROOT/programs/build/suites/riscv-vector-tests/report"
REPORT="$OUT_DIR/report.txt"
CTEST_LOG="$OUT_DIR/ctest.log"
mkdir -p "$OUT_DIR"

# --- defaults ----------------------------------------------------------------
BUILD_DIR="$PROJECT_ROOT/programs/build"
TIMEOUT="${RVVT_TEST_TIMEOUT:-20}"
JOBS="${RVVT_JOBS:-$(nproc)}"
SPIKE_INSTALL="${RVVT_SPIKE_INSTALL:-$PROJECT_ROOT/riscv-isa-sim/install}"
record_file="$OUT_DIR/passed.txt"
exclude_file=""

usage() {
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- parse args (positional [build-dir] [timeout] + flags) -------------------
positional=()
while (( $# )); do
    case "$1" in
        --record|-p) record_file="${2:-$record_file}"; shift 2 ;;
        --exclude|-x) exclude_file="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; positional+=("$@"); break ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) positional+=("$1"); shift ;;
    esac
done
[[ ${#positional[@]} -ge 1 ]] && BUILD_DIR="${positional[0]}"
[[ ${#positional[@]} -ge 2 ]] && TIMEOUT="${positional[1]}"

# ETISS runtime used to obtain the fail number (the ELF's exit code).
ETISS_BIN="$PROJECT_ROOT/etiss/build/installed/bin/bare_etiss_processor"
ETISS_INI="$PROJECT_ROOT/programs/runtime/ini/etiss.ini"
ETISS_ARCH="RV32IMACFDV_zvl128b"
ELFS_DIR="$BUILD_DIR/suites/riscv-vector-tests/generated/bin"

# ---------------------------------------------------------------------------
# Configure + build. Generation happens at configure time. Reconfigure only
# when needed (missing cache, or a different test-timeout was requested) so we
# don't regenerate the suite on every run.
# ---------------------------------------------------------------------------
cached_timeout=""
if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
    cached_timeout="$(sed -n 's/^RVVT_TEST_TIMEOUT:.*=//p' "$BUILD_DIR/CMakeCache.txt" | tail -1)"
fi
need_configure=0
if [[ ! -f "$BUILD_DIR/CMakeCache.txt" ]]; then
    need_configure=1
    echo ">> Configuring ($BUILD_DIR) [fresh] ..." >&2
elif [[ "$cached_timeout" != "$TIMEOUT" ]]; then
    need_configure=1
    echo ">> Configuring ($BUILD_DIR) [test-timeout ${cached_timeout:-none} -> ${TIMEOUT}s] ..." >&2
fi
if [[ "$need_configure" -eq 1 ]]; then
    cmake -S "$PROJECT_ROOT/programs" -B "$BUILD_DIR" \
        -DRVVT_SPIKE_INSTALL="$SPIKE_INSTALL" \
        -DRVVT_TEST_TIMEOUT="$TIMEOUT" >&2
fi

echo ">> Building ..." >&2
cmake --build "$BUILD_DIR" >&2

# ---------------------------------------------------------------------------
# Build the ctest exclude regex: only run tests NOT in the exclude file.
# ---------------------------------------------------------------------------
exclude_regex=""
excluded_count=0
if [[ -n "$exclude_file" ]]; then
    if [[ ! -f "$exclude_file" ]]; then
        echo ">> WARNING: exclude file not found: $exclude_file (running all tests)" >&2
    else
        excluded_count=$(grep -vcE '^[[:space:]]*(#|$)' "$exclude_file")
        if (( excluded_count > 0 )); then
            # Test names are rvvt_<basename>, i.e. only [A-Za-z0-9_-]. Anchor
            # each with ^...$ so a short name (e.g. rvvt_vadd_vx-1) cannot also
            # exclude a longer one (rvvt_vadd_vx-10) as a substring.
            exclude_regex="$(awk '!/^[[:space:]]*(#|$)/{printf "%s^%s$", sep, $0; sep="|"}' "$exclude_file")"
            echo ">> Excluding $excluded_count previously-passed tests ..." >&2
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Run CTest on all (non-excluded) tests, with the requested per-test timeout
# ---------------------------------------------------------------------------
echo ">> Running CTest (timeout=${TIMEOUT}s, jobs=${JOBS}, exclude=${excluded_count}) ..." >&2
ctest_args=(--test-dir "$BUILD_DIR" --timeout "$TIMEOUT" --output-on-failure -j "$JOBS")
[[ -n "$exclude_regex" ]] && ctest_args+=(-E "$exclude_regex")
ctest "${ctest_args[@]}" >"$CTEST_LOG" 2>&1
CTEST_RC=$?

# ---------------------------------------------------------------------------
# Parse per-test status from the CTest summary lines:
#   "N/T Test #k: <name> ............... Passed    x.xx sec"
#   "N/T Test #k: <name> ...............***Failed  x.xx sec"
#   "N/T Test #k: <name> ...............***Timeout x.xx sec"
# ("Test" and "#" are right-justified, hence the variable spaces.)
# ---------------------------------------------------------------------------
TMP_STATUS="$OUT_DIR/.status.tsv"
: > "$TMP_STATUS"
awk '
    /Test +#[0-9]+: / {
        sub(/.*Test +#[0-9]+: /, "")   # drop the "N/T Test #k: " prefix
        name = $1
        status = "PASS"
        if ($0 ~ /\*\*\*Timeout/) status = "TIMEOUT"
        else if ($0 ~ /\*\*\*Failed/) status = "FAIL"
        print name "\t" status
    }' "$CTEST_LOG" | sort -u > "$TMP_STATUS"

# ---------------------------------------------------------------------------
# Record PASSED tests (cumulative union into the record file) and collect the
# FAIL tests for fail-number extraction.
# ---------------------------------------------------------------------------
fail_names=""
while IFS=$'\t' read -r name stat; do
    [[ -z "$name" ]] && continue
    [[ "$stat" == "FAIL" ]] && fail_names="$fail_names $name"
done < "$TMP_STATUS"

if [[ -n "$record_file" ]]; then
    : > "$record_file.tmp"
    grep -vE '^[[:space:]]*(#|$)' "$record_file" 2>/dev/null >> "$record_file.tmp"
    awk -F'\t' '$2=="PASS"{print $1}' "$TMP_STATUS" >> "$record_file.tmp"
    sort -u "$record_file.tmp" > "$record_file"
    rm -f "$record_file.tmp"
    echo ">> Recorded passes -> $record_file ($(grep -vcE '^[[:space:]]*(#|$)' "$record_file") total)" >&2
fi

# ---------------------------------------------------------------------------
# For FAIL tests, capture the failing test-case number (the ELF exit code)
# ---------------------------------------------------------------------------
: > "$OUT_DIR/.failnum.tsv"
for name in $fail_names; do
    base="${name#rvvt_}"
    elf="$ELFS_DIR/$base.elf"
    if [[ -f "$elf" ]]; then
        timeout "$TIMEOUT" "$ETISS_BIN" -i "$ETISS_INI" --arch.cpu "$ETISS_ARCH" \
            --vp.elf_file "$elf" --vp.quiet true >/dev/null 2>&1
        code=$?
        if [[ "$code" -eq 124 ]]; then
            echo -e "$name\tTIMEOUT" >> "$OUT_DIR/.failnum.tsv"
        else
            echo -e "$name\t$code" >> "$OUT_DIR/.failnum.tsv"
        fi
    else
        echo -e "$name\tn/a" >> "$OUT_DIR/.failnum.tsv"
    fi
done

# ---------------------------------------------------------------------------
# Write the report
# ---------------------------------------------------------------------------
{
    total=0; pass=0; fail=0; timeout=0
    while IFS=$'\t' read -r name stat; do
        [[ -z "$name" ]] && continue
        total=$((total+1))
        case "$stat" in
            PASS)   pass=$((pass+1)) ;;
            FAIL)   fail=$((fail+1)) ;;
            TIMEOUT) timeout=$((timeout+1)) ;;
        esac
    done < "$TMP_STATUS"

    echo "=== riscv-vector-tests Zve32x (ETISS) ==="
    echo "  run     : $(date)"
    echo "  timeout : ${TIMEOUT}s   jobs: ${JOBS}"
    echo "  excluded: ${excluded_count} (skipped via --exclude)"
    echo
    printf "  RUN    : %d\n" "$total"
    printf "  PASS   : %d\n" "$pass"
    printf "  FAIL   : %d\n" "$fail"
    printf "  TIMEOUT: %d\n" "$timeout"
    echo
    if (( fail > 0 )); then
        echo "  FAILURES (exit code = first failing test-case number):"
        while IFS=$'\t' read -r name num; do
            [[ -z "$name" ]] && continue
            printf "    %-28s  fail at case %s\n" "$name" "$num"
        done < "$OUT_DIR/.failnum.tsv"
        echo
    fi
    if (( timeout > 0 )); then
        echo "  TIMED OUT (>${TIMEOUT}s):"
        while IFS=$'\t' read -r name stat; do
            [[ "$stat" == "TIMEOUT" ]] && printf "    %s\n" "$name"
        done < "$TMP_STATUS"
    fi
} > "$REPORT"

cat "$REPORT"
echo
echo "Report written to: $REPORT"
echo "Full CTest log  : $CTEST_LOG"
[[ -n "$record_file" ]] && echo "Passed list      : $record_file"
