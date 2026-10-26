# SPDX-License-Identifier: BSD-3-Clause
#
# programs/CMakeLists.txt - Top-level project for building ETISS-runnable test
# and benchmark suites.
#
# This project does not run CMake's normal compiler pipeline for the built
# programs: the programs are bare-metal RISC-V binaries produced with a RISC-V
# cross compiler (riscv32-unknown-elf-gcc) via custom commands, so the host
# compiler is left untouched.
#
# Suites live in suites/ and reuse the helpers in cmake/ETISSProgram.cmake.
# To build/run a suite:
#   cmake -S programs -B programs/build
#   cmake --build programs/build
#   ctest --test-dir programs/build

cmake_minimum_required(VERSION 3.13)

project(etiss_programs C ASM)

# ---------------------------------------------------------------------------
# RISC-V cross toolchain
# ---------------------------------------------------------------------------
set(RISCV_TOOLCHAIN_PREFIX "riscv32-unknown-elf-" CACHE STRING "RISC-V bare-metal toolchain prefix")
set(RVVT_MARCH "rv32im_zve32x_zvl128b" CACHE STRING "RISC-V target ISA (march) for the programs")
set(RVVT_MABI "ilp32" CACHE STRING "RISC-V target ABI (mabi) for the programs")

find_program(RISCV_GCC "${RISCV_TOOLCHAIN_PREFIX}gcc")
if(NOT RISCV_GCC)
    message(FATAL_ERROR "RISC-V cross compiler not found: '${RISCV_TOOLCHAIN_PREFIX}gcc'. "
                        "Install it or set -DRISCV_TOOLCHAIN_PREFIX=<prefix>.")
endif()

# Flags used for every program/tool object we build with the cross compiler.
set(ETISS_RISCV_FLAGS
    -march=${RVVT_MARCH}
    -mabi=${RVVT_MABI}
    -static
    -mcmodel=medany
    -fvisibility=hidden
    -nostdlib
    -nostartfiles
)

# ---------------------------------------------------------------------------
# ETISS (the simulator we run the programs under)
# ---------------------------------------------------------------------------
set(ETISS_INSTALL_PREFIX "" CACHE PATH "Installed ETISS prefix (contains bin/bare_etiss_processor)")

# Auto-detect the install prefix built by scripts/build_etiss.sh.
if(NOT ETISS_INSTALL_PREFIX)
    set(_etiss_candidate "${CMAKE_CURRENT_SOURCE_DIR}/../etiss/build/installed")
    if(EXISTS "${_etiss_candidate}/bin/bare_etiss_processor")
        set(ETISS_INSTALL_PREFIX "${_etiss_candidate}")
    endif()
endif()

find_program(ETISS_BARE_PROCESSOR bare_etiss_processor
    PATHS "${ETISS_INSTALL_PREFIX}/bin"
    NO_DEFAULT_PATH)
if(NOT ETISS_BARE_PROCESSOR)
    message(FATAL_ERROR "bare_etiss_processor not found. Build and install ETISS first "
                        "(see scripts/build_etiss.sh) or set -DETISS_INSTALL_PREFIX=<prefix>.")
endif()

# Common ETISS configuration for running programs.
set(ETISS_RUNTIME_DIR "${CMAKE_CURRENT_SOURCE_DIR}/runtime")
set(ETISS_LINKER "${ETISS_RUNTIME_DIR}/etiss.ld")
set(ETISS_INI "${ETISS_RUNTIME_DIR}/ini/etiss.ini")
set(ETISS_ARCH_CPU "RV32IMACFDV_zvl128b" CACHE STRING "ETISS arch.cpu used to run the programs")

# ---------------------------------------------------------------------------
# CTest + reusable helpers
# ---------------------------------------------------------------------------
include(CTest)
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/ETISSProgram.cmake)

# ---------------------------------------------------------------------------
# Test / benchmark suites.
#
# Add a new suite by creating suites/<name>/CMakeLists.txt (it may call
# etiss_add_riscv_program() / etiss_add_riscv_test()) and adding an
# add_subdirectory() line below, guarded by an option.
# ---------------------------------------------------------------------------
option(ETISS_BUILD_RISCV_VECTOR_TESTS "Build the riscv-vector-tests suite" ON)
if(ETISS_BUILD_RISCV_VECTOR_TESTS)
    add_subdirectory(suites/riscv-vector-tests)
endif()
