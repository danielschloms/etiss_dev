#!/usr/bin/env bash
#
# gen_vector_tests.sh - Generate, verify and compile riscv-vector-tests (Zve32x)
# as self-verifying, ETISS-runnable programs.
#
# Unlike the co-sim "single" generator, this script runs the official
# riscv-vector-tests reference-generation pipeline and produces tests that
# compare the DUT result against a Spike-derived reference:
#
#   stage1 (generator)  ->  compiled  ->  pspike (Spike) captures reference
#   ->  merger produces self-verifying stage2 .S  ->  compiled for ETISS
#
# Each resulting ELF, when run under ETISS, exits 0 on success or with the
# number of the first failing test case (via the ETISS semihosting _exit stub).
# A test that ETISS cannot complete (a simulator-side RVV hang) is reported as
# a timeout.
#
# Defaults target the integer vector subset (Zve32x) at XLEN=32, VLEN=128.
#
# Usage:
#   scripts/gen_vector_tests.sh [options]
#
# Options:
#   -o, --output <dir>      Output directory for generated files
#                           [default: <project>/programs/build/suites/riscv-vector-tests/generated]
#   -r, --root <dir>        riscv-vector-tests checkout
#                           [default: <project>/programs/src/riscv-vector-tests/riscv-vector-tests]
#       --vlen <n>          Vector length [default: 128]
#       --xlen <n>          XLEN [default: 32]
#   -p, --pattern <regex>   Filter configs by basename regex [default: '.*']
#   -j, --jobs <n>          Parallel jobs [default: $(nproc)]
#       --prefix <prefix>   RISC-V toolchain prefix [default: riscv32-unknown-elf-]
#       --march <isa>       RISC-V target ISA [default: rv32im_zve32x_zvl128b]
#       --mabi <abi>        RISC-V target ABI [default: ilp32]
#       --spike-prefix <d>  Installed Spike prefix (bin/spike, lib/libfesvr.a,
#                           lib/libriscv.a, include/riscv). Required for the
#                           reference (pspike) step.
#                           [default: <project>/riscv-isa-sim/install if present]
#       --spike <path>      Path to the 'spike' binary [default: $SPIKE_PREFIX/bin/spike]
#       --run               Also run each ELF under ETISS and write a results file.
#       --etiss <path>      bare_etiss_processor binary [default: detected]
#       --only-generate     Generate stage1/stage2 ".S" only; do not compile.
#       --recompile         Recompile the existing stage2 ".S" into ETISS ELFs
#                           only (skip generator/merger/Spike; reuse the current
#                           stage2 output). Use after editing e.g. riscv_test.h.
#       --objdump <path>    objdump binary for disassembly [default: <prefix>objdump]
#       --no-dump           Do not produce .dump disassembly of the ELFs
#   -h, --help              Show this help
#
# Note: only integer (Zve32x) configs are generated; floating-point configs
# (names beginning with "vf") are always skipped, and ELEN is derived from XLEN
# so SEW=64 cases are dropped automatically by the generator.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RVVT_ROOT="$PROJECT_ROOT/programs/src/riscv-vector-tests/riscv-vector-tests"
PROGRAMS_DIR="$PROJECT_ROOT/programs"
ETISS_ENV="$PROGRAMS_DIR/env/etiss"
ETISS_RUNTIME="$PROGRAMS_DIR/runtime"

OUT_DIR="$PROGRAMS_DIR/build/suites/riscv-vector-tests/generated"
VLEN=128
XLEN=32
PATTERN='.*'
JOBS="$(nproc)"
PREFIX="riscv32-unknown-elf-"
MARCH="rv32im_zve32x_zvl128b"
MABI="ilp32"
SPIKE_PREFIX=""
SPIKE=""
RUN=0
ETISS=""
ONLY_GENERATE=0
RECOMPILE=0
DUMP=1
OBJDUMP="${RVVT_OBJDUMP:-}"

usage() {
    cat <<'EOF'
gen_vector_tests.sh - Generate, verify and compile riscv-vector-tests (Zve32x)
as self-verifying, ETISS-runnable programs.

Usage:
  scripts/gen_vector_tests.sh [options]

Options:
  -o, --output <dir>      Output directory [default: <project>/programs/build/suites/riscv-vector-tests/generated]
  -r, --root <dir>        riscv-vector-tests checkout
                           [default: <project>/programs/src/riscv-vector-tests/riscv-vector-tests]
      --vlen <n>          Vector length [default: 128]
      --xlen <n>          XLEN [default: 32]
  -p, --pattern <regex>   Filter configs by basename regex [default: '.*']
  -j, --jobs <n>          Parallel jobs [default: $(nproc)]
      --prefix <prefix>   RISC-V toolchain prefix [default: riscv32-unknown-elf-]
      --march <isa>       RISC-V target ISA [default: rv32im_zve32x_zvl128b]
      --mabi <abi>        RISC-V target ABI [default: ilp32]
      --spike-prefix <d>  Installed Spike prefix (bin/spike, lib/*.a, include/riscv).
                           [default: <project>/riscv-isa-sim/install if present]
      --spike <path>      Path to the 'spike' binary.
      --run               Run each ELF under ETISS and write a results file.
      --etiss <path>      bare_etiss_processor binary [default: detected].
      --only-generate     Generate stage1/stage2 ".S" only; do not compile.
      --recompile         Recompile existing stage2 ".S" into ETISS ELFs only
                           (skip generate/merge/Spike).
      --objdump <path>    objdump binary for disassembly [default: <prefix>objdump]
      --no-dump           Do not produce .dump disassembly of the ELFs.
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)        OUT_DIR="$2";        shift 2 ;;
        -r|--root)          RVVT_ROOT="$2";      shift 2 ;;
        --vlen)             VLEN="$2";           shift 2 ;;
        --xlen)             XLEN="$2";           shift 2 ;;
        -p|--pattern)       PATTERN="$2";        shift 2 ;;
        -j|--jobs)          JOBS="$2";           shift 2 ;;
        --prefix)           PREFIX="$2";         shift 2 ;;
        --march)            MARCH="$2";          shift 2 ;;
        --mabi)             MABI="$2";           shift 2 ;;
        --spike-prefix)     SPIKE_PREFIX="$2";   shift 2 ;;
        --spike)            SPIKE="$2";          shift 2 ;;
        --run)              RUN=1;               shift ;;
        --etiss)            ETISS="$2";          shift 2 ;;
        --only-generate)    ONLY_GENERATE=1;     shift ;;
        --recompile)        RECOMPILE=1;         shift ;;
        --objdump)          OBJDUMP="$2";        shift 2 ;;
        --no-dump)          DUMP=0;              shift ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# Default to an installed riscv-isa-sim tree, if present, so Spike is
# auto-detected exactly like the CMake suite (CMakeLists.txt) and the run
# script do. When neither --spike-prefix nor --spike is given and the tree is
# absent, SPIKE_PREFIX stays empty so the requirement check below fires.
if [[ -z "$SPIKE_PREFIX" && -z "$SPIKE" ]]; then
    _default_spike="$PROJECT_ROOT/riscv-isa-sim/install"
    if [[ -x "$_default_spike/bin/spike" ]]; then
        SPIKE_PREFIX="$_default_spike"
        echo "Using Spike from '$SPIKE_PREFIX'." >&2
    fi
fi

if [[ -z "$SPIKE_PREFIX" && -z "$SPIKE" && "$ONLY_GENERATE" -eq 0 && "$RECOMPILE" -eq 0 ]]; then
    echo "Error: the reference step (pspike) requires Spike." >&2
    echo "Pass --spike-prefix <dir> (an installed Spike) or --spike <binary>." >&2
    echo "(Only stage1 generation is possible without Spike; use --only-generate.)" >&2
    exit 1
fi
if [[ -z "$SPIKE" ]]; then
    SPIKE="$SPIKE_PREFIX/bin/spike"
fi
# pspike is linked against the shared libriscv/libfesvr, so it needs LD_LIBRARY_PATH.
if [[ -n "$SPIKE_PREFIX" ]]; then
    export SPIKE_LIBDIR="$SPIKE_PREFIX/lib"
elif [[ -n "$SPIKE" ]]; then
    export SPIKE_LIBDIR="$(dirname "$SPIKE")/../lib"
fi

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if (( ! RECOMPILE )); then
    [[ -d "$RVVT_ROOT" ]] || { echo "Error: riscv-vector-tests checkout not found at '$RVVT_ROOT'." >&2; exit 1; }
    command -v go >/dev/null 2>&1 || { echo "Error: 'go' is required." >&2; exit 1; }
    CFG_DIR="$RVVT_ROOT/configs/v"
    [[ -d "$CFG_DIR" ]] || { echo "Error: no configs directory at '$CFG_DIR'." >&2; exit 1; }

    if [[ ! -f "$RVVT_ROOT/env/riscv-test-env/encoding.h" ]]; then
        echo "Initializing riscv-vector-tests 'env/riscv-test-env' submodule..." >&2
        git -C "$RVVT_ROOT" submodule update --init env/riscv-test-env
    fi
fi

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
STAGE1="$OUT_DIR/stage1"
STAGE1_BIN="$OUT_DIR/stage1bin"
PATCH="$OUT_DIR/patch"
STAGE2="$OUT_DIR/stage2"
ELF_DIR="$OUT_DIR/bin"
DUMP_DIR="$OUT_DIR/dump"
TOOLS="$OUT_DIR/.tools"
mkdir -p "$STAGE1" "$STAGE1_BIN" "$PATCH" "$STAGE2" "$ELF_DIR" "$DUMP_DIR" "$TOOLS"

GENERATOR="$TOOLS/generator"
MERCER="$TOOLS/merger"
PSPIKE="$TOOLS/pspike"
SH_EXIT_OBJ="$TOOLS/sh_exit.o"

SPIKE_TEST_ENV="$RVVT_ROOT/env/riscv-test-env/p"
LINKD="$SPIKE_TEST_ENV/link.ld"
MACROS="$RVVT_ROOT/macros/general"

# ---------------------------------------------------------------------------
# Steps 1-4 (generation/merge/Spike) are skipped in --recompile mode, where we
# reuse the stage2 .S that exist from a previous run and only recompile them.
# ---------------------------------------------------------------------------
if (( ! RECOMPILE )); then

# ---------------------------------------------------------------------------
# 1) Build tools: generator, merger, pspike
# ---------------------------------------------------------------------------
echo "Building 'generator' and 'merger'..." >&2
( cd "$RVVT_ROOT" && go build -o "$GENERATOR" && go build -o "$MERCER" merger/merger.go )

if [[ -n "$SPIKE_PREFIX" ]]; then
    echo "Building 'pspike' against $SPIKE_PREFIX..." >&2
    g++ -std=c++17 -I"$SPIKE_PREFIX/include" -L"$SPIKE_PREFIX/lib" \
        "$RVVT_ROOT/pspike/pspike.cc" -lriscv -lfesvr -o "$PSPIKE"
fi

# ---------------------------------------------------------------------------
# 2) Generate stage1 assembly (integer/Zve32x configs only)
# ---------------------------------------------------------------------------
echo "Generating stage1 tests (VLEN=${VLEN}, XLEN=${XLEN})..." >&2
"$GENERATOR" -VLEN "$VLEN" -XLEN "$XLEN" -split=10000 -integer=1 \
    -pattern="$PATTERN" -testfloat3level=2 -repeat=1 \
    -stage1output "$STAGE1" -configs "$RVVT_ROOT/configs" -march "$MARCH"

mapfile -t stage1_files < <(ls "$STAGE1"/*.S 2>/dev/null || true)
if (( ${#stage1_files[@]} == 0 )); then
    echo "No tests generated for pattern '$PATTERN'." >&2
    exit 0
fi
echo "Generated ${#stage1_files[@]} stage1 tests." >&2

if (( ONLY_GENERATE )); then
    echo "Done. Stage1 assemblies in $STAGE1" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# 3) Compile stage1 and run pspike to capture Spike reference values
# ---------------------------------------------------------------------------
RISCV_GCC="${PREFIX}gcc"
command -v "$RISCV_GCC" >/dev/null 2>&1 || { echo "Error: cross compiler '$RISCV_GCC' not found." >&2; exit 1; }

S1_FLAGS=(-march="$MARCH" -mabi="$MABI" -static -mcmodel=medany -fvisibility=hidden
          -nostdlib -nostartfiles -DENTROPY=0xdeadbeef -DLFSR_BITS=9
          -fno-tree-loop-distribute-patterns)
S1_INC=(-I "$SPIKE_TEST_ENV" -I "$MACROS")

export RISCV_GCC SPIKE PSPIKE STAGE1 STAGE1_BIN PATCH LINKD MARCH
export S1_FLAGS_str="${S1_FLAGS[*]}" S1_INC_str="${S1_INC[*]}"
run_s1() {
    local s="$1" b
    b="$(basename "$s" .S)"
    local -a flags incs
    read -r -a flags <<< "$S1_FLAGS_str"
    read -r -a incs <<< "$S1_INC_str"
    "$RISCV_GCC" "${flags[@]}" "${incs[@]}" -T "$LINKD" "$s" \
        -o "$STAGE1_BIN/$b" >/dev/null 2>"$STAGE1_BIN/$b.log"
    [[ $? -eq 0 ]] || { echo "stage1-compile FAIL $b" >&2; return; }
    LD_LIBRARY_PATH="$SPIKE_LIBDIR:${LD_LIBRARY_PATH:-}" \
        "$PSPIKE" --isa="${MARCH}" "$STAGE1_BIN/$b" >"$PATCH/$b.patch" 2>"$PATCH/$b.log"
    [[ $? -eq 0 ]] || echo "pspike FAIL $b" >&2
}
export -f run_s1
echo "Compiling stage1 and capturing Spike references..." >&2
printf '%s\n' "${stage1_files[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_s1 "$@"' _ {}

# ---------------------------------------------------------------------------
# 4) Merge stage1 + reference into self-verifying stage2
# ---------------------------------------------------------------------------
echo "Merging stage2 (self-verifying) tests..." >&2
"$MERCER" -stage1output "$STAGE1" -stage2output "$STAGE2" -stage2patch "$PATCH"

fi # (end of the non-recompile generation block)

# ---------------------------------------------------------------------------
# stage2 inputs: generated by the merger in a full run, or reused from a
# previous run in --recompile mode.
# ---------------------------------------------------------------------------
if (( RECOMPILE )); then
    echo "Recompiling existing stage2 tests in $STAGE2 (no generation/Spike)..." >&2
fi
mapfile -t stage2_files < <(ls "$STAGE2"/*.S 2>/dev/null || true)
if (( ${#stage2_files[@]} == 0 )); then
    echo "No stage2 tests in '$STAGE2'. Run without --recompile to generate them first." >&2
    exit 0
fi
echo "Using ${#stage2_files[@]} stage2 tests from $STAGE2." >&2

# ---------------------------------------------------------------------------
# 5) Compile stage2 for ETISS (ETISS env + runtime + semihosting exit stub)
# ---------------------------------------------------------------------------
if [[ ! -d "$ETISS_ENV" || ! -f "$ETISS_RUNTIME/etiss.ld" || ! -f "$ETISS_RUNTIME/sh_exit.c" ]]; then
    echo "Error: ETISS programs runtime/env not found (expected under '$PROGRAMS_DIR')." >&2
    exit 1
fi

RISCV_GCC="${PREFIX}gcc"
command -v "$RISCV_GCC" >/dev/null 2>&1 || { echo "Error: cross compiler '$RISCV_GCC' not found." >&2; exit 1; }

S2_FLAGS=(-march="$MARCH" -mabi="$MABI" -static -mcmodel=medany -fvisibility=hidden
          -nostdlib -nostartfiles)
S2_INC=(-I "$ETISS_ENV" -I "$RVVT_ROOT/env/riscv-test-env" -I "$MACROS")
LINKER="$ETISS_RUNTIME/etiss.ld"

"$RISCV_GCC" "${S2_FLAGS[@]}" -c "$ETISS_RUNTIME/sh_exit.c" -o "$SH_EXIT_OBJ"

export S2_FLAGS_str="${S2_FLAGS[*]}" S2_INC_str="${S2_INC[*]}"
export LINKER SH_EXIT_OBJ STAGE2 ELF_DIR RISCV_GCC
run_s2() {
    local s="$1" b
    b="$(basename "$s" .S)"
    local -a flags incs
    read -r -a flags <<< "$S2_FLAGS_str"
    read -r -a incs <<< "$S2_INC_str"
    "$RISCV_GCC" "${flags[@]}" "${incs[@]}" -T "$LINKER" "$s" "$SH_EXIT_OBJ" \
        -o "$ELF_DIR/$b.elf" 2>"$ELF_DIR/$b.log"
    [[ $? -eq 0 ]] || echo "stage2-compile FAIL $b" >&2
}
export -f run_s2
echo "Compiling ${#stage2_files[@]} ETISS programs..." >&2
printf '%s\n' "${stage2_files[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_s2 "$@"' _ {}

# ---------------------------------------------------------------------------
# 5b) Disassemble each ELF into <dump>/ (auto; skip with --no-dump)
# ---------------------------------------------------------------------------
if (( DUMP )); then
    if [[ -z "$OBJDUMP" ]]; then
        OBJDUMP="$(command -v "${PREFIX}objdump" || true)"
    fi
    if [[ -z "$OBJDUMP" || ! -x "$OBJDUMP" ]]; then
        echo "Warning: objdump not found (looked for '${PREFIX}objdump'); skipping disassembly. Pass --objdump <path>." >&2
    else
        mkdir -p "$DUMP_DIR"
        export OBJDUMP DUMP_DIR ELF_DIR
        : > "$DUMP_DIR/.err.log"
        run_dump() {
            local b="$1"
            "$OBJDUMP" -d "$ELF_DIR/$b.elf" >"$DUMP_DIR/$b.dump" 2>>"$DUMP_DIR/.err.log"
            [[ $? -eq 0 ]] || echo "dump FAIL $b" >&2
        }
        export -f run_dump
        mapfile -t elf_bases < <(ls "$ELF_DIR"/*.elf | sed -E 's#.*/([^/]+)\.elf#\1#')
        echo "Disassembling ${#elf_bases[@]} ELFs -> $DUMP_DIR ..." >&2
        printf '%s\n' "${elf_bases[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_dump "$@"' _ {}
    fi
fi

if (( ! RUN )); then
    echo "Done. Self-verifying ETISS ELFs in $ELF_DIR" >&2
    echo "  run:  $0 --run --spike-prefix $SPIKE_PREFIX -o $OUT_DIR" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# 6) (Optional) Run each ELF under ETISS and record pass/fail codes
# ---------------------------------------------------------------------------
if [[ -z "$ETISS" ]]; then
    ETISS="$(command -v bare_etiss_processor || true)"
    if [[ -z "$ETISS" ]]; then
        ETISS="$PROJECT_ROOT/etiss/build/installed/bin/bare_etiss_processor"
    fi
fi
[[ -x "$ETISS" ]] || { echo "Error: bare_etiss_processor not found; pass --etiss <path>." >&2; exit 1; }

INI="$ETISS_RUNTIME/ini/etiss.ini"
ARCH_CPU="${ETISS_ARCH_CPU:-RV32IMACFDV_zvl128b}"
RESULTS="$OUT_DIR/results.txt"
: > "$RESULTS"

export ETISS INI ARCH_CPU ELF_DIR RESULTS
run_etiss() {
    local b="$1"
    timeout 60 "$ETISS" -i "$INI" --arch.cpu "$ARCH_CPU" \
        --vp.elf_file "$ELF_DIR/$b.elf" --vp.quiet true >/dev/null 2>/dev/null
    echo "$b $?" >> "$RESULTS"
}
export -f run_etiss

mapfile -t elf_bases < <(ls "$ELF_DIR"/*.elf | sed -E 's#.*/([^/]+)\.elf#\1#')
echo "Running ${#elf_bases[@]} ELFs under ETISS..." >&2
printf '%s\n' "${elf_bases[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_etiss "$@"' _ {}

echo "Results written to '$RESULTS':" >&2
awk '{ if($2==0) p++; else if($2==124) t++; else f++ } END{
    printf "  PASS    : %d\n  FAIL    : %d\n  TIMEOUT : %d\n  TOTAL   : %d\n", p, f, t, p+f+t }' "$RESULTS"
echo "  (exit 0 => pass; exit N>0 => first failing test case number N.)" >&2
