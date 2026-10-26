#!/usr/bin/env bash
#
# run_etiss.sh - Run ETISS on a single target binary and report the result.
#
# The riscv-vector-tests ELFs are self-verifying (Spike-derived reference):
#   exit 0                    -> all test cases passed
#   exit <N> (nonzero)        -> first failing test case is number <N>
#   exit 124                  -> hit the timeout
#
# Usage:
#   scripts/run_etiss.sh <binary> [options]
#
#   <binary>       Path to the target ELF (e.g. .../generated/bin/vadd_vv-1.elf)
#   --timeout SECS  Guard the run with `timeout SECS` (default: no timeout)
#   --stats FILE    Write the ETISS stats JSON to FILE (--vp.stats_file_path)
#   --stdout        Stream the guest/ETISS output to your stdout (visible live)
#                   Without this the output is captured and only shown via
#                   --show-log. --verbose is a synonym for --stdout.
#   --show-log      After running, print the captured ETISS log
#   -h, --help      Show this help
#
# Environment (all optional):
#   ETISS_BIN    bare_etiss_processor binary
#                [default: <project>/etiss/build/installed/bin/bare_etiss_processor]
#   ETISS_INI    ETISS configuration ini
#                [default: <project>/programs/runtime/ini/etiss.ini]
#   ETISS_ARCH   RISC-V arch string   [default: RV32IMACFDV_zvl128b]
#
# Exit status of this script:
#   0 on success (guest exit 0), otherwise the guest exit code.
#   If a timeout occurs, the script exits with 124.

set -uo pipefail
# Intentionally no `set -e`: nonzero guest exits are meaningful and reported.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# --- defaults -----------------------------------------------------------------
ETISS_BIN="${ETISS_BIN:-$PROJECT_ROOT/etiss/build/installed/bin/bare_etiss_processor}"
ETISS_INI="${ETISS_INI:-$PROJECT_ROOT/programs/runtime/ini/etiss.ini}"
ETISS_ARCH="${ETISS_ARCH:-RV32IMACFDV_zvl128b}"

BIN=""
TIMEOUT=""
STATS_FILE=""
STDOUT=0
SHOW_LOG=0

usage() {
    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- parse args ---------------------------------------------------------------
positional=()
while (( $# )); do
    case "$1" in
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        --stats)   STATS_FILE="${2:-}"; shift 2 ;;
        --stdout|--verbose) STDOUT=1; shift ;;
        --show-log) SHOW_LOG=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; positional+=("$@"); break ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) positional+=("$1"); shift ;;
    esac
done
[[ ${#positional[@]} -eq 1 ]] && BIN="${positional[0]}"

if [[ -z "$BIN" ]]; then
    echo "error: no binary given" >&2
    usage >&2
    exit 2
fi
if [[ ! -f "$BIN" ]]; then
    echo "error: binary not found: $BIN" >&2
    exit 2
fi
if [[ ! -x "$ETISS_BIN" ]]; then
    echo "error: ETISS binary not found/executable: $ETISS_BIN" >&2
    echo "       set ETISS_BIN, or build ETISS first." >&2
    exit 2
fi
if [[ ! -f "$ETISS_INI" ]]; then
    echo "error: ETISS ini not found: $ETISS_INI" >&2
    exit 2
fi

# --- build the ETISS command --------------------------------------------------
cmd=()
[[ -n "$TIMEOUT" ]] && cmd+=(timeout "$TIMEOUT")
cmd+=("$ETISS_BIN" -i "$ETISS_INI" --arch.cpu "$ETISS_ARCH" --vp.elf_file "$BIN" --vp.quiet false)
[[ -n "$STATS_FILE" ]] && cmd+=("--vp.stats_file_path" "$STATS_FILE")

LOG="$(mktemp /tmp/run_etiss.XXXXXX.log)"
trap 'rm -f "$LOG"' EXIT

echo ">> target : $BIN"
echo ">> arch   : $ETISS_ARCH"
echo ">> etiss  : $ETISS_BIN"
[[ -n "$TIMEOUT" ]] && echo ">> timeout: ${TIMEOUT}s"

if [[ "$STDOUT" -eq 1 ]]; then
    "${cmd[@]}"
else
    "${cmd[@]}" >"$LOG" 2>&1
fi
code=$?

# --- interpret the exit code --------------------------------------------------
echo
if [[ "$code" -eq 0 ]]; then
    echo "PASS  (exit 0)"
elif [[ "$code" -eq 124 ]]; then
    echo "TIMEOUT  (exceeded ${TIMEOUT:-the timeout})"
else
    echo "FAIL  at test case $code  (exit $code)"
fi

if [[ "$SHOW_LOG" -eq 1 ]]; then
    echo
    echo "--- ETISS log (${LOG}) ---"
    cat "$LOG"
fi

# --- pass through the guest exit code -----------------------------------------
exit "$code"
