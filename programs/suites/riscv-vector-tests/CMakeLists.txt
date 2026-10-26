# SPDX-License-Identifier: BSD-3-Clause
#
# riscv-vector-tests suite.
#
# Builds SELF-VERIFYING riscv-vector-tests as ETISS-runnable ELFs and registers
# each as a CTest test.
#
# Unlike the co-sim "single" generator, this suite runs the official
# riscv-vector-tests reference pipeline (generator -> pspike/Spike -> merger) to
# embed Spike-derived reference values, so every test compares the DUT (ETISS)
# result against the ground truth. Each ELF exits 0 on success, or with the
# number of the first failing test case (via the ETISS semihosting _exit stub).
#
# Selection:
#   - Only the integer vector subset (Zve32x) is generated (floating-point
#     configs are skipped; ELEN is derived from XLEN so SEW=64 cases vanish).
#   - Fixed to XLEN=32 and VLEN=128 (adjust via RVVT_XLEN / RVVT_VLEN).
#
# Controls:
#   -DRVVT_PATTERN='^vadd'   Restrict to a subset of configs (regex on basename).
#   -DRVVT_SPIKE_INSTALL=... Installed Spike prefix (bin/spike, lib/libriscv.so).

set(RVVT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../src/riscv-vector-tests/riscv-vector-tests")
set(RVVT_SCRIPTS "${CMAKE_CURRENT_SOURCE_DIR}/../../../scripts")

set(RVVT_VLEN 128 CACHE STRING "riscv-vector-tests VLEN")
set(RVVT_XLEN 32 CACHE STRING "riscv-vector-tests XLEN (ELEN is derived from XLEN)")
set(RVVT_PATTERN ".*" CACHE STRING "Regex filter on config basename (e.g. '^vadd')")
# Per-test timeout. This is a CTest TIMEOUT *property*, which overrides any
# `ctest --timeout` on the command line, so the run script keeps it in sync
# by passing -DRVVT_TEST_TIMEOUT=<seconds> at configure time.
set(RVVT_TEST_TIMEOUT 600 CACHE STRING "Per-test CTest timeout in seconds")

# Installed Spike, used by pspike to derive the reference values.
set(RVVT_SPIKE_INSTALL "" CACHE PATH "Installed Spike prefix (contains bin/spike and lib/libriscv.so)")
if(NOT RVVT_SPIKE_INSTALL)
    set(_spike_candidate "${CMAKE_CURRENT_SOURCE_DIR}/../../../../riscv-isa-sim/install")
    if(EXISTS "${_spike_candidate}/bin/spike")
        set(RVVT_SPIKE_INSTALL "${_spike_candidate}")
    endif()
endif()
if(NOT RVVT_SPIKE_INSTALL)
    message(FATAL_ERROR
        "riscv-vector-tests self-verifying tests require Spike to derive the "
        "reference values. Pass -DRVVT_SPIKE_INSTALL=<prefix> (bin/spike + "
        "lib/libriscv.so + include/riscv).")
endif()

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
set(GO_EXECUTABLE go)
find_program(GO_EXECUTABLE go)
if(NOT GO_EXECUTABLE)
    message(FATAL_ERROR "Go is required to build the riscv-vector-tests generator")
endif()

if(NOT EXISTS "${RVVT_ROOT}/env/riscv-test-env/encoding.h")
    message(STATUS "Initializing riscv-vector-tests env/riscv-test-env submodule...")
    execute_process(
        COMMAND git -C "${RVVT_ROOT}" submodule update --init env/riscv-test-env
        WORKING_DIRECTORY "${RVVT_ROOT}"
        RESULT_VARIABLE _rvvt_init_rc
    )
    if(NOT _rvvt_init_rc EQUAL 0)
        message(FATAL_ERROR "Could not initialize the riscv-vector-tests 'env/riscv-test-env' submodule")
    endif()
endif()

# ---------------------------------------------------------------------------
# Generate + compile the self-verifying tests via the reusable script
# ---------------------------------------------------------------------------
set(RVVT_OUT "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(GEN_SCRIPT "${RVVT_SCRIPTS}/gen_vector_tests.sh")

set(RVVT_GEN_CMD
    "${GEN_SCRIPT}"
    -o "${RVVT_OUT}"
    --vlen "${RVVT_VLEN}"
    --xlen "${RVVT_XLEN}"
    --pattern "${RVVT_PATTERN}"
    --spike-prefix "${RVVT_SPIKE_INSTALL}"
)

# The script sets its own ETHISS runtime dir from PROJECT_ROOT (it stays in
# sync with this repo). Ensure it is executable.
file(MAKE_DIRECTORY "${RVVT_OUT}")
if(NOT EXISTS "${GEN_SCRIPT}")
    message(FATAL_ERROR "riscv-vector-tests generator script not found: ${GEN_SCRIPT}")
endif()

message(STATUS "Generating self-verifying riscv-vector-tests (VLEN=${RVVT_VLEN} XLEN=${RVVT_XLEN})...")
execute_process(
    COMMAND ${RVVT_GEN_CMD}
    RESULT_VARIABLE _rvvt_gen_rc
    OUTPUT_VARIABLE _rvvt_gen_out
    ERROR_VARIABLE _rvvt_gen_err
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../../.."
    TIMEOUT 3600
)
if(NOT _rvvt_gen_rc EQUAL 0)
    message(FATAL_ERROR "riscv-vector-tests generation failed:\n${_rvvt_gen_err}")
endif()
string(STRIP "${_rvvt_gen_out}" _rvvt_gen_out_trim)
message(STATUS "riscv-vector-tests generation output:\n${_rvvt_gen_out_trim}")

# ---------------------------------------------------------------------------
# Register the generated ELFs as CTest tests (run under bare_etiss_processor)
# ---------------------------------------------------------------------------
set(ETISS_INI "${ETISS_RUNTIME_DIR}/ini/etiss.ini")
file(GLOB_RECURSE RVVT_ELFS "${RVVT_OUT}/bin/*.elf")
list(SORT RVVT_ELFS)
list(LENGTH RVVT_ELFS RVVT_NTESTS)

if(NOT RVVT_ELFS)
    message(WARNING "riscv-vector-tests: no ELFs were produced (empty build?)")
else()
    message(STATUS "riscv-vector-tests: registering ${RVVT_NTESTS} self-verifying tests")
endif()

foreach(_elf IN LISTS RVVT_ELFS)
    get_filename_component(_name "${_elf}" NAME_WE)
    set(_test "rvvt_${_name}")
    add_test(
        NAME ${_test}
        COMMAND "${ETISS_BARE_PROCESSOR}"
                -i "${ETISS_INI}"
                --arch.cpu "${ETISS_ARCH_CPU}"
                --vp.elf_file "${_elf}"
                --vp.quiet true
    )
    # Exit 0 => test passed; exit != 0 => first failing test case number.
    # The timeout is configurable (RVVT_TEST_TIMEOUT); note a per-test TIMEOUT
    # property overrides `ctest --timeout`, so the run script keeps them in sync.
    set_tests_properties(${_test} PROPERTIES TIMEOUT "${RVVT_TEST_TIMEOUT}")
endforeach()
