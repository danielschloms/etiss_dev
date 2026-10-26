/**
 * @file
 * @author Daniel Schloms
 * @brief This file implements _exit for semihosting to include
 * SYS_EXIT_EXTENDED.
 */

#include <stdint.h>

#define ADP_Stopped_ApplicationExit 0x20026
#define SYS_EXIT 0x18
#define SYS_EXIT_EXTENDED 0x20

#if __riscv_xlen == 32
#define SH_EXIT SYS_EXIT_EXTENDED;
#define REG uint32_t
#define SREG int32_t
#else
#define SH_EXIT SYS_EXIT;
#define REG uint64_t
#define SREG int64_t
#endif

// If problems with _exit arise, it's also possible to link with
// -Wl,--wrap=_exit and define void __wrap__exit(int status) {...}

void _exit(int status) {
  SREG fields[] = {ADP_Stopped_ApplicationExit, status};
  register SREG a1 asm("a1") = (SREG)fields;
  register SREG a0 asm("a0") = SH_EXIT;

  // Semihosting call sequence
  asm volatile(".balign 16             \n"
               ".option push           \n"
               ".option norvc          \n"
               "slli zero, zero, 0x1f  \n"
               "ebreak                 \n"
               "srai zero, zero, 0x7   \n"
               ".option pop            \n"
               : "+r"(a0)
               : "r"(a1)
               : "memory");

  while (1) {
  }
}