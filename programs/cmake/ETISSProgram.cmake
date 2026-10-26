# SPDX-License-Identifier: BSD-3-Clause
#
# ETISSProgram.cmake - Reusable helpers for building ETISS-runnable bare-metal
# programs and registering them with CTest.
#
# This module is meant to be included from the top-level programs/CMakeLists.txt.
# It defines the following functions that can be used by any suite:
#
#   etiss_add_riscv_program(<name>
#       ELF_OUT <path>
#       SOURCES <file>...               # .S/.c sources that define _start (or a main if crt0 is linked)
#       INCLUDE_DIRS <dir>...           # extra -I include dirs for the cross-compile
#       DEPENDS <dep>...)               # extra ordering dependencies (files or targets)
#     Builds a bare-metal ELF for ETISS using the RISC-V cross toolchain.
#
#   etiss_add_riscv_test(<name> <elf>)
#     Registers <name> as a CTest test that runs <elf> under bare_etiss_processor.
#
# The following cache/normal variables must be defined before including this file
# (they are set up by programs/CMakeLists.txt):
#   RISCV_GCC         - path to the RISC-V cross compiler
#   ETISS_RISCV_FLAGS - common compile/link flags (march, mabi, -nostdlib ...)
#   ETISS_LINKER      - linker script (etiss.ld)
#   ETISS_INI         - default ETISS configuration .ini file
#   ETISS_ARCH_CPU    - ETISS arch.cpu to simulate (e.g. RV32IMACFDV_zvl128b)
#   ETISS_BARE_PROCESSOR - path to bare_etiss_processor

include_guard(GLOBAL)

# Build a bare-metal ELF for ETISS.
function(etiss_add_riscv_program NAME)
    set(options "")
    set(oneValueArgs ELF_OUT)
    set(multiValueArgs SOURCES INCLUDE_DIRS DEPENDS)
    cmake_parse_arguments(P "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

    if(NOT P_ELF_OUT)
        message(FATAL_ERROR "etiss_add_riscv_program(${NAME}): ELF_OUT is required")
    endif()
    if(NOT P_SOURCES)
        message(FATAL_ERROR "etiss_add_riscv_program(${NAME}): at least one SOURCE is required")
    endif()

    # -I paths must be passed as separate arguments, so build a list.
    set(_inc_list "")
    foreach(_d IN LISTS P_INCLUDE_DIRS)
        list(APPEND _inc_list "-I${_d}")
    endforeach()

    add_custom_command(
        OUTPUT "${P_ELF_OUT}"
        COMMAND "${RISCV_GCC}"
                ${ETISS_RISCV_FLAGS}
                ${_inc_list}
                -T "${ETISS_LINKER}"
                ${P_SOURCES}
                -o "${P_ELF_OUT}"
        DEPENDS ${P_SOURCES} "${ETISS_LINKER}" ${P_DEPENDS}
        COMMENT "Building ETISS program ${NAME}"
        VERBATIM
    )

    add_custom_target(${NAME} ALL DEPENDS "${P_ELF_OUT}")
    set(${NAME}_ELF "${P_ELF_OUT}" PARENT_SCOPE)
endfunction()

# Register a built ELF as a CTest test run under bare_etiss_processor.
function(etiss_add_riscv_test NAME ELF)
    add_test(
        NAME ${NAME}
        COMMAND "${ETISS_BARE_PROCESSOR}"
                -i "${ETISS_INI}"
                --arch.cpu "${ETISS_ARCH_CPU}"
                --vp.elf_file "${ELF}"
                --vp.quiet true
    )
    set_tests_properties(${NAME} PROPERTIES TIMEOUT 300)
endfunction()
